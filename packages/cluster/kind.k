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

schema Cluster:
    """
    Kind cluster configuration

    Args:
        name: Cluster name (default: "kind")
        workers: Number of worker nodes (default: 0)
        db_workers: Number of database-dedicated worker nodes with taints (default: 0)
        ingress: Enable ingress ports 80/443 on control-plane (default: false)
    """
    # Configuration options from CLI
    _name: str = option("name", default="kind")
    _ingress: bool = option("ingress", default=False)
    _workers: int = option("workers", default=0)
    _db_workers: int = option("db_workers", default=0)

    # Kind cluster schema
    kind?: "Cluster" = "Cluster"
    apiVersion?: "kind.x-k8s.io/v1alpha4" = "kind.x-k8s.io/v1alpha4"
    name: str = _name

    # Node configuration
    nodes: [Node] = [
        Node {
            role: "control-plane"
            if _ingress:
                kubeadmConfigPatches: [_ingress_init_patch]
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

