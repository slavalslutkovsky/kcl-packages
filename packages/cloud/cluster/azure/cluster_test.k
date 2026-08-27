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
        spec = {region = "westeurope", resourceGroup = "demo-rg"} | _spec
    }
}

_fp = lambda _spec {
    cluster.render(_build(_spec), {})[0].spec.forProvider
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = cluster.render(_build({}), {})
    assert len(items) == 1, "AKS expresses everything in one KubernetesCluster"
    assert items[0].apiVersion == "containerservice.azure.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "KubernetesCluster", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "cluster name pinned to the XR name"
    assert items[0].spec.writeConnectionSecretToRef.name == "demo-kubeconfig", "kubeconfig published as a connection secret"
}

# ---- render: cluster --------------------------------------------------------
test_cluster = lambda {
    fp = _fp({version = "1.32", tags = {team = "platform"}})
    assert fp.location == "westeurope", "region -> location"
    assert fp.resourceGroupName == "demo-rg", "resourceGroup carried"
    assert fp.dnsPrefix == "demo", "dnsPrefix defaults to the XR name"
    assert fp.kubernetesVersion == "1.32", "version carried"
    assert fp.identity.$type == "SystemAssigned", "system-assigned identity"
    assert fp.tags == {team = "platform"}, "tags carried"
    assert not _fp({})?.kubernetesVersion, "no version unless asked for"
}

# ---- render: default node pool ----------------------------------------------
test_node_pool_fixed = lambda {
    np = _fp({nodeCount = 3}).defaultNodePool
    assert np.name == "default", "system pool name"
    assert np.nodeCount == 3, "fixed size from nodeCount"
    assert np.vmSize == "Standard_B2s", "nodeSize defaults to small"
    assert not np?.autoScalingEnabled, "no autoscaling unless asked for"
    assert not np?.vnetSubnetId, "AKS-managed network unless a subnet is given"
}

test_node_pool_autoscaling = lambda {
    np = _fp({nodeCount = 3, autoscaling = {min = 2, max = 10}}).defaultNodePool
    assert np.autoScalingEnabled == True, "autoscaling enabled"
    assert np.minCount == 2 and np.maxCount == 10, "autoscaling bounds carried"
    assert np.nodeCount == 3, "autoscaled pool seeded from nodeCount"
}

test_machine_for = lambda {
    assert cluster.machine_for({nodeSize = "large"}) == "Standard_D4s_v5", "size ladder"
    assert cluster.machine_for({machineType = "Standard_D16s_v5"}) == "Standard_D16s_v5", "explicit machineType wins"
    assert _fp({nodeSize = "xlarge"}).defaultNodePool.vmSize == "Standard_D8s_v5", "ladder reaches the pool"
}

test_subnet = lambda {
    _sub = "/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/aks"
    assert _fp({network.subnets = [_sub]}).defaultNodePool.vnetSubnetId == _sub, "first subnet -> vnetSubnetId"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = cluster.render(_build({deletionPolicy = "Orphan"}), {})[0].spec.managementPolicies
    assert _orphaned == _orphan, "Orphan must set the non-delete policies"
    _deleted = cluster.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = cluster.status(_build({}), {})
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.kubeconfigSecret == "demo-kubeconfig", "secret name known ahead of creation"
    assert dxr.status?.endpoint == Undefined, "no endpoint before the cluster exists"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.ContainerService/managedClusters/demo"
                        fqdn = "demo-abc123.hcp.westeurope.azmk8s.io"
                        currentKubernetesVersion = "1.32.4"
                    }
                }
            }
        }
    }
    dxr = cluster.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed fqdn must mark the cluster ready"
    assert dxr.status.endpoint == "demo-abc123.hcp.westeurope.azmk8s.io", "fqdn surfaced as endpoint"
    assert dxr.status.version == "1.32.4", "running version surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.ContainerService/managedClusters/demo", "cloud-url points at the cluster"
}
