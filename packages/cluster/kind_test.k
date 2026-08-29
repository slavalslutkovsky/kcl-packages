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

# Test database-dedicated workers
test_db_workers = lambda {
    cluster = kind.Cluster {
        _workers: 1
        _db_workers: 2
    }
    assert len(cluster.nodes) == 4, "Should have 1 control-plane + 1 worker + 2 db workers"
    assert cluster.nodes[1].role == "worker"
    # DB workers have taint patches
    assert cluster.nodes[2].role == "worker"
    assert len(cluster.nodes[2].kubeadmConfigPatches) == 1, "DB worker should have 1 patch"
    assert len(cluster.nodes[3].kubeadmConfigPatches) == 1, "DB worker should have 1 patch"
}

# Test db_workers only (no regular workers)
test_db_workers_only = lambda {
    cluster = kind.Cluster {
        _db_workers: 1
    }
    assert len(cluster.nodes) == 2, "Should have 1 control-plane + 1 db worker"
    assert len(cluster.nodes[1].kubeadmConfigPatches) == 1
}

# Test that no issuer patch is emitted by default
test_no_issuer_by_default = lambda {
    cluster = kind.Cluster {}
    assert len(cluster.nodes[0].kubeadmConfigPatches or []) == 0, "Plain cluster should carry no kubeadm patches"
}

# Test the service-account issuer patch
test_oidc_issuer = lambda {
    cluster = kind.Cluster {
        _oidc_bucket: "paidevo-local-oidc"
        _oidc_id: "yurik"
    }
    patches = cluster.nodes[0].kubeadmConfigPatches
    assert len(patches) == 1, "Should have only the issuer patch"
    assert "kind: ClusterConfiguration" in patches[0]
    assert "value: https://storage.googleapis.com/paidevo-local-oidc/yurik" in patches[0]
    assert "- name: service-account-issuer" in patches[0], "extraArgs uses the native kubeadm v1beta4 list shape"
}

# Test issuer + ingress coexisting on the control-plane node
test_oidc_issuer_with_ingress = lambda {
    cluster = kind.Cluster {
        _ingress: True
        _oidc_bucket: "bucket"
        _oidc_id: "id"
    }
    cp_node = cluster.nodes[0]
    assert len(cp_node.kubeadmConfigPatches) == 2, "ingress patch + issuer patch"
    assert "ingress-ready=true" in cp_node.kubeadmConfigPatches[0]
    assert "service-account-issuer" in cp_node.kubeadmConfigPatches[1]
    assert len(cp_node.extraPortMappings) == 2, "ingress ports survive the extra patch"
}

# Test that db workers keep only their taint patch
test_oidc_issuer_leaves_workers_alone = lambda {
    cluster = kind.Cluster {
        _db_workers: 1
        _oidc_bucket: "bucket"
        _oidc_id: "id"
    }
    assert len(cluster.nodes[1].kubeadmConfigPatches) == 1, "Issuer patch is control-plane only"
    assert "JoinConfiguration" in cluster.nodes[1].kubeadmConfigPatches[0]
}

# Run tests
test_default_cluster()
test_cluster_with_workers()
test_ingress_config()
test_db_workers()
test_db_workers_only()
test_no_issuer_by_default()
test_oidc_issuer()
test_oidc_issuer_with_ingress()
test_oidc_issuer_leaves_workers_alone()
