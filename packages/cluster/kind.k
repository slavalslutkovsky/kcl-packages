# Kind Cluster Configuration Schema
# Generates valid Kind cluster YAML configurations
schema PortMapping:
    """Port mapping for Kind node"""
    containerPort: int
    hostPort: int
    $protocol?: "TCP" | "UDP" = "TCP"

schema Mount:
    """Host path bind-mounted into a Kind node container"""
    hostPath: str
    containerPath: str

schema Node:
    """Kind cluster node configuration"""
    role: "control-plane" | "worker"
    kubeadmConfigPatches?: [str]
    extraPortMappings?: [PortMapping]
    extraMounts?: [Mount]

# The host's /proc at /procHost. A node is itself a container, so its own /proc
# shows only the node's processes; agents that watch every process on the host
# (Tetragon: helm `--set tetragon.hostProcPath=/procHost`) need the real one.
# On Docker Desktop "the host" is the Linux VM, which is what such agents want.
_host_proc_mounts: [Mount] = [Mount {
    hostPath: "/proc"
    containerPath: "/procHost"
}]

# Kubeadm patch for ingress-ready nodes
_ingress_init_patch = '''
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "ingress-ready=true"
'''

# Kubeadm patch for a dedicated worker pool: label and NoSchedule taint
# `dedicated=<pool>`, so only pods that tolerate the taint and select the label
# (a database operator's instances, a Kafka operator's brokers) land there.
_dedicated_join_patch = lambda pool: str -> str {
    '''
kind: JoinConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "dedicated=${pool}"
  taints:
    - key: "dedicated"
      value: "${pool}"
      effect: "NoSchedule"
'''
}

# Kubeadm patch pinning the API server's service-account token issuer to a
# publicly reachable OIDC discovery URL. An external STS (GCP Workload Identity
# Federation) fetches that URL's JWKS to verify projected tokens, which removes
# the need for a static service-account key file in the cluster.
#
# extraArgs is written as a list because that is the native kubeadm v1beta4
# shape (k8s >= 1.31). kind also accepts the legacy v1beta3 map and converts it,
# but emitting the native shape keeps the patch a plain merge.
_sa_issuer_patch = lambda issuer: str -> str {
    """kind: ClusterConfiguration
apiServer:
  extraArgs:
  - name: service-account-issuer
    value: ${issuer}
"""
}

schema Cluster:
    """
    Kind cluster configuration

    Args:
        name: Cluster name (default: "kind")
        workers: Number of worker nodes (default: 0)
        db_workers: Number of database-dedicated worker nodes with taints (default: 0)
        kafka_workers: Number of Kafka-dedicated worker nodes, labelled and tainted
            dedicated=kafka:NoSchedule, for a Kafka operator (Strimzi, Redpanda, ...)
            and its brokers/controllers (default: 0)
        ingress: Enable ingress ports 80/443 on control-plane (default: false)
        host_proc: Mount the host's /proc at /procHost on every node, for
            host-wide eBPF agents such as Tetragon (default: false)
        oidc_bucket: GCS bucket serving this cluster's OIDC discovery documents
        oidc_id: Path prefix inside oidc_bucket, one per cluster (e.g. a developer name)

    Supplying oidc_bucket and oidc_id pins the API server's service-account
    issuer to https://storage.googleapis.com/<oidc_bucket>/<oidc_id>, so
    projected tokens can be exchanged for cloud credentials via Workload
    Identity Federation. Omit both to keep kubeadm's in-cluster issuer.
    """
    # Configuration options from CLI
    _name: str = option("name", default="kind")
    _ingress: bool = option("ingress", default=False)
    _host_proc: bool = option("host_proc", default=False)
    _workers: int = option("workers", default=0)
    _db_workers: int = option("db_workers", default=0)
    _kafka_workers: int = option("kafka_workers", default=0)
    _oidc_bucket: str = option("oidc_bucket", default="")
    _oidc_id: str = option("oidc_id", default="")

    _issuer: str = "https://storage.googleapis.com/${_oidc_bucket}/${_oidc_id}" if _oidc_bucket != "" else ""

    # Both patches target the control-plane node, so they share one list.
    _control_plane_patches: [str] = ([_ingress_init_patch] if _ingress else []) + ([_sa_issuer_patch(_issuer)] if _issuer != "" else [])

    # Kind cluster schema
    kind?: "Cluster" = "Cluster"
    apiVersion?: "kind.x-k8s.io/v1alpha4" = "kind.x-k8s.io/v1alpha4"
    name: str = _name

    # Node configuration
    nodes: [Node] = [
        Node {
            role: "control-plane"
            if len(_control_plane_patches) > 0:
                kubeadmConfigPatches: _control_plane_patches
            if _host_proc:
                extraMounts: _host_proc_mounts
            if _ingress:
                extraPortMappings: [
                    PortMapping {
                        containerPort: 80
                        hostPort: 80
                        $protocol: "TCP"
                    }
                    PortMapping {
                        containerPort: 443
                        hostPort: 443
                        $protocol: "TCP"
                    }
                ]
        }
    ] + [Node {
        role: "worker"
        if _host_proc:
            extraMounts: _host_proc_mounts
    } for _ in range(_workers)] + [Node {
        role: "worker"
        kubeadmConfigPatches: [_dedicated_join_patch("database")]
        if _host_proc:
            extraMounts: _host_proc_mounts
    } for _ in range(_db_workers)] + [Node {
        role: "worker"
        kubeadmConfigPatches: [_dedicated_join_patch("kafka")]
        if _host_proc:
            extraMounts: _host_proc_mounts
    } for _ in range(_kafka_workers)]

    check:
        # A half-set pair would silently produce a bogus issuer URL, and every
        # in-cluster token would carry it — fail the render instead.
        (_oidc_bucket == "") == (_oidc_id == ""), "oidc_bucket and oidc_id must be set together"
