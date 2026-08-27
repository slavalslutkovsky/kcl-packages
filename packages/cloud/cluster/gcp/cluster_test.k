import .cluster

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "KubernetesCluster"
        metadata.name = "demo"
        spec = {region = "us-central1"} | _spec
    }
}

_render = lambda _spec {
    cluster.render(_build(_spec), {})
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = _render({})
    assert len(items) == 2, "GKE Cluster + NodePool"
    assert items[0].kind == "Cluster" and items[0].apiVersion == "container.gcp.m.upbound.io/v1beta1", "wrong cluster GVK"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "cluster is the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "cluster name pinned to the XR name"
    assert items[1].kind == "NodePool", "node pool present"
}

# ---- render: cluster --------------------------------------------------------
test_cluster = lambda {
    fp = _render({version = "1.32", tags = {team = "platform"}})[0].spec.forProvider
    assert fp.location == "us-central1", "region -> location"
    assert fp.removeDefaultNodePool == True, "default pool removed in favour of the managed NodePool"
    assert fp.initialNodeCount == 1, "GKE needs a node count at creation"
    assert fp.deletionProtection == False, "lifecycle is governed by deletionPolicy, not the GKE lock"
    assert fp.minMasterVersion == "1.32", "version -> minMasterVersion"
    assert fp.resourceLabels == {team = "platform"}, "tags -> resourceLabels"
}

test_network = lambda {
    fp = _render({
        network = {id = "projects/p/global/networks/n", subnets = ["projects/p/regions/us-central1/subnetworks/s"]}
    })[0].spec.forProvider
    assert fp.network == "projects/p/global/networks/n", "network.id carried"
    assert fp.subnetwork == "projects/p/regions/us-central1/subnetworks/s", "first subnet -> subnetwork"
    bare = _render({})[0].spec.forProvider
    assert not bare?.network and not bare?.subnetwork, "default network unless asked for"
}

test_kubeconfig_secret = lambda {
    items = _render({})
    assert items[0].spec.writeConnectionSecretToRef.name == "demo-kubeconfig", "kubeconfig published as a connection secret"
}

# ---- render: node pool ------------------------------------------------------
test_node_pool_fixed = lambda {
    fp = _render({nodeCount = 3})[1].spec.forProvider
    assert fp.clusterSelector.matchControllerRef == True, "pool binds to the composed cluster"
    assert fp.location == "us-central1", "pool location carried"
    assert fp.nodeCount == 3, "fixed size from nodeCount"
    assert not fp?.autoscaling, "no autoscaling unless asked for"
    assert fp.nodeConfig.machineType == "e2-medium", "nodeSize defaults to small"
}

test_node_pool_autoscaling = lambda {
    fp = _render({nodeCount = 3, autoscaling = {min = 2, max = 10}})[1].spec.forProvider
    assert fp.autoscaling.minNodeCount == 2 and fp.autoscaling.maxNodeCount == 10, "autoscaling bounds carried"
    assert fp.initialNodeCount == 3, "autoscaled pool seeded from nodeCount"
    assert not fp?.nodeCount, "nodeCount conflicts with autoscaling upstream"
}

test_machine_for = lambda {
    assert cluster.machine_for({nodeSize = "large"}) == "e2-standard-4", "size ladder"
    assert cluster.machine_for({machineType = "n2-standard-4"}) == "n2-standard-4", "explicit machineType wins"
}

test_spot_and_labels = lambda {
    nc = _render({spot = True, tags = {team = "platform"}})[1].spec.forProvider.nodeConfig
    assert nc.spot == True, "spot carried to the node config"
    assert nc.labels == {team = "platform"}, "tags -> node labels"
    off = _render({})[1].spec.forProvider.nodeConfig
    assert not off?.spot, "on-demand unless spot"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = _render({deletionPolicy = "Orphan"})
    assert all _i in _orphaned {
        _i.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every MR"
    _deleted = _render({})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = cluster.status(_build({}), {})
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.kubeconfigSecret == "demo-kubeconfig", "secret name known ahead of creation"
    assert dxr.status?.endpoint == Undefined, "no endpoint before the cluster exists"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "projects/my-project/locations/us-central1/clusters/demo"
                        endpoint = "34.1.2.3"
                        masterVersion = "1.32.4-gke.1"
                        location = "us-central1"
                    }
                }
            }
        }
    }
    dxr = cluster.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed endpoint must mark the cluster ready"
    assert dxr.status.endpoint == "34.1.2.3", "endpoint surfaced"
    assert dxr.status.version == "1.32.4-gke.1", "version surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/kubernetes/clusters/details/us-central1/demo?project=my-project", "cloud-url derives the project from the observed id"
}
