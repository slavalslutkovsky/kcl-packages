# Tests for k3s (k3d) cluster configuration
import .k3s

test_k3s_default_cluster = lambda {
    cluster = k3s.K3sCluster {}
    assert cluster.apiVersion == "k3d.io/v1alpha5"
    assert cluster.kind == "Simple"
    assert cluster.metadata.name == "k3s"
    assert cluster.servers == 1 and cluster.agents == 0
    assert not cluster?.ports, "No host ports without ingress"
    assert not cluster?.options, "Plain cluster keeps traefik and needs no k3s args"
    assert not cluster?.image, "Empty k3s_image defers to k3d's default"
}

test_k3s_multi_node = lambda {
    cluster = k3s.K3sCluster {
        _control_planes: 3
        _workers: 2
    }
    assert cluster.servers == 3
    assert cluster.agents == 2
}

test_k3s_ingress_ports_on_loadbalancer = lambda {
    cluster = k3s.K3sCluster {
        _ingress: True
        _workers: 2
    }
    assert [p.port for p in cluster.ports] == ["80:80", "443:443"]
    assert all p in cluster.ports {p.nodeFilters == ["loadbalancer"]}, "serverlb proxies host ports to every node"
    assert not cluster?.options, "ingress alone keeps the bundled traefik"
}

test_k3s_traefik_disabled = lambda {
    cluster = k3s.K3sCluster {
        _ingress: True
        _traefik: False
    }
    args = cluster.options.k3s.extraArgs
    assert len(args) == 1
    assert args[0].arg == "--disable=traefik"
    assert args[0].nodeFilters == ["server:*"], "traefik is a server-side manifest"
}

test_k3s_db_agents_follow_plain_agents = lambda {
    cluster = k3s.K3sCluster {
        _workers: 2
        _db_workers: 2
    }
    assert cluster.agents == 4
    taint = cluster.options.k3s.extraArgs[0]
    assert taint.arg == "--node-taint=dedicated=database:NoSchedule"
    assert taint.nodeFilters == ["agent:2", "agent:3"], "agents 0-1 stay general purpose"
    label = cluster.options.k3s.nodeLabels[0]
    assert label.label == "dedicated=database"
    assert label.nodeFilters == taint.nodeFilters, "label and taint land on the same agents"
}

test_k3s_db_agents_only = lambda {
    cluster = k3s.K3sCluster {
        _db_workers: 1
    }
    assert cluster.options.k3s.nodeLabels[0].nodeFilters == ["agent:0"]
}

test_k3s_oidc_issuer = lambda {
    cluster = k3s.K3sCluster {
        _oidc_bucket: "paidevo-local-oidc"
        _oidc_id: "yurik"
    }
    args = cluster.options.k3s.extraArgs
    assert len(args) == 1
    assert args[0].arg == "--kube-apiserver-arg=service-account-issuer=https://storage.googleapis.com/paidevo-local-oidc/yurik"
    assert args[0].nodeFilters == ["server:*"], "every server runs an API server"
    assert not cluster.options.k3s?.nodeLabels
}

test_k3s_image = lambda {
    cluster = k3s.K3sCluster {
        _k3s_image: "rancher/k3s:v1.33.13-k3s1"
    }
    assert cluster.image == "rancher/k3s:v1.33.13-k3s1"
}

test_k3s_default_cluster()
test_k3s_multi_node()
test_k3s_ingress_ports_on_loadbalancer()
test_k3s_traefik_disabled()
test_k3s_db_agents_follow_plain_agents()
test_k3s_db_agents_only()
test_k3s_oidc_issuer()
test_k3s_image()
