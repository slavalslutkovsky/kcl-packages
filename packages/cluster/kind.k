# Kind Cluster Configuration Schema
# Generates valid Kind cluster YAML configurations
schema PortMapping:
    """Port mapping for Kind node"""
    containerPort: int
    hostPort: int
    $protocol?: "TCP" | "UDP" = "TCP"

schema Node:
    """Kind cluster node configuration"""
    role: "control-plane" | "worker"
    kubeadmConfigPatches?: [str]
    extraPortMappings?: [PortMapping]

# Kubeadm patch for ingress-ready nodes
_ingress_init_patch = '''
kind: InitConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "ingress-ready=true"
'''

# Kubeadm patch for database-dedicated nodes
_db_join_patch = '''
kind: JoinConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "dedicated=database"
  taints:
    - key: "dedicated"
      value: "database"
      effect: "NoSchedule"
'''

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
        ingress: Enable ingress ports 80/443 on control-plane (default: false)
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
    _workers: int = option("workers", default=0)
    _db_workers: int = option("db_workers", default=0)
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
    } for _ in range(_workers)] + [Node {
        role: "worker"
        kubeadmConfigPatches: [_db_join_patch]
    } for _ in range(_db_workers)]

    check:
        # A half-set pair would silently produce a bogus issuer URL, and every
        # in-cluster token would carry it — fail the render instead.
        (_oidc_bucket == "") == (_oidc_id == ""), "oidc_bucket and oidc_id must be set together"
