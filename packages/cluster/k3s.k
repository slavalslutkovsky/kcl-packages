# k3s Cluster Configuration Schema
# Generates a k3d Simple config (k3d.io/v1alpha5): k3s servers and agents as
# docker containers, consumed by `k3d cluster create --config <file>`.
schema K3dPortMapping:
    """Host port published by k3d; `port` is "<host>:<container>"."""
    port: str
    nodeFilters: [str]

schema K3sArg:
    """Extra k3s CLI flag, applied to the nodes matching nodeFilters."""
    arg: str
    nodeFilters: [str]

schema K3sNodeLabel:
    """Kubernetes node label, applied to the nodes matching nodeFilters."""
    label: str
    nodeFilters: [str]

schema K3sOptions:
    extraArgs?: [K3sArg]
    nodeLabels?: [K3sNodeLabel]

schema K3dOptions:
    k3s: K3sOptions

schema K3dMetadata:
    name: str

schema K3sCluster:
    """
    k3s cluster configuration, rendered for k3d

    Args:
        name: Cluster name; the kube context is k3d-<name> (default: "k3s")
        control_planes: Number of k3s servers (default: 1). More than one runs
            embedded etcd; k3d adds --cluster-init to the first server.
        workers: Number of k3s agents (default: 0)
        db_workers: Number of database-dedicated agents, labelled and tainted
            dedicated=database:NoSchedule (default: 0)
        ingress: Publish host ports 80/443 on the k3d load balancer (default: false)
        traefik: Keep k3s' bundled traefik ingress controller (default: true).
            Set false when another controller (e.g. ingress-nginx) owns 80/443.
        k3s_image: rancher/k3s image; empty keeps k3d's default
        oidc_bucket: GCS bucket serving this cluster's OIDC discovery documents
        oidc_id: Path prefix inside oidc_bucket, one per cluster

    With ingress on, k3d's serverlb container proxies host 80/443 to every
    node, where k3s' servicelb exposes LoadBalancer Services — traefik's by
    default. Servers stay schedulable, so a single-server cluster runs
    workloads without agents.
    """
    _name: str = option("name", default="k3s")
    _control_planes: int = option("control_planes", default=1)
    _workers: int = option("workers", default=0)
    _db_workers: int = option("db_workers", default=0)
    _ingress: bool = option("ingress", default=False)
    _traefik: bool = option("traefik", default=True)
    _k3s_image: str = option("k3s_image", default="")
    _oidc_bucket: str = option("oidc_bucket", default="")
    _oidc_id: str = option("oidc_id", default="")

    _issuer: str = "https://storage.googleapis.com/${_oidc_bucket}/${_oidc_id}" if _oidc_bucket != "" else ""

    # k3d numbers agents from 0; db agents come after the plain ones.
    _db_agents: [str] = ["agent:${i}" for i in range(_workers, _workers + _db_workers)]

    _extra_args: [K3sArg] = ([K3sArg {
        arg: "--disable=traefik"
        nodeFilters: ["server:*"]
    }] if not _traefik else []) + ([K3sArg {
        arg: "--kube-apiserver-arg=service-account-issuer=${_issuer}"
        nodeFilters: ["server:*"]
    }] if _issuer != "" else []) + ([K3sArg {
        arg: "--node-taint=dedicated=database:NoSchedule"
        nodeFilters: _db_agents
    }] if _db_workers > 0 else [])

    apiVersion: "k3d.io/v1alpha5" = "k3d.io/v1alpha5"
    kind: "Simple" = "Simple"
    metadata: K3dMetadata = K3dMetadata {name: _name}
    servers: int = _control_planes
    agents: int = _workers + _db_workers
    image?: str
    ports?: [K3dPortMapping]
    options?: K3dOptions
    if _k3s_image != "":
        image = _k3s_image

    if _ingress:
        ports = [
            K3dPortMapping {
                port: "80:80"
                nodeFilters: ["loadbalancer"]
            }
            K3dPortMapping {
                port: "443:443"
                nodeFilters: ["loadbalancer"]
            }
        ]

    if len(_extra_args) > 0 or _db_workers > 0:
        options = K3dOptions {
            k3s: K3sOptions {
                if len(_extra_args) > 0:
                    extraArgs: _extra_args
                if _db_workers > 0:
                    nodeLabels: [K3sNodeLabel {
                        label: "dedicated=database"
                        nodeFilters: _db_agents
                    }]
            }
        }


    check:
        _control_planes >= 1, "control_planes must be at least 1"
        _workers >= 0 and _db_workers >= 0, "workers and db_workers must not be negative"
        (_oidc_bucket == "") == (_oidc_id == ""), "oidc_bucket and oidc_id must be set together"
