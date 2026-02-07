# Tests for Kind cluster configuration
import .kind

# Test default cluster
test_default_cluster = lambda {
    cluster = kind.Cluster {}
    assert cluster.name == "kind", "Default name should be 'kind'"
    assert cluster.apiVersion == "kind.x-k8s.io/v1alpha4"
    assert len(cluster.nodes) == 1, "Default should have 1 control-plane node"
    assert cluster.nodes[0].role == "control-plane"
}

# Test cluster with workers
test_cluster_with_workers = lambda {
    # Note: Workers are controlled via CLI options, this tests the schema
    cluster = kind.Cluster {
        _workers: 2
    }
    assert len(cluster.nodes) == 3, "Should have 1 control-plane + 2 workers"
    assert cluster.nodes[1].role == "worker"
    assert cluster.nodes[2].role == "worker"
}

# Test ingress configuration
test_ingress_config = lambda {
    cluster = kind.Cluster {
        _ingress: True
    }
    cp_node = cluster.nodes[0]
    assert cp_node.extraPortMappings != None, "Should have port mappings"
    assert len(cp_node.extraPortMappings) == 2, "Should have 2 port mappings (80, 443)"
    assert cp_node.extraPortMappings[0].hostPort == 80
    assert cp_node.extraPortMappings[1].hostPort == 443
}

# Run tests
test_default_cluster()
test_cluster_with_workers()
test_ingress_config()
