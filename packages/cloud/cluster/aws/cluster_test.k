import json
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
        spec = {region = "us-east-1", network.subnets = ["subnet-a", "subnet-b"]} | _spec
    }
}

_render = lambda _spec {
    cluster.render(_build(_spec), {})
}

# Composed order: cluster-role, cluster-policy-0, node-role, node-policy-0..2,
# managed (6), nodes (7), auth (8).
_rn = lambda _item {
    _item.metadata.annotations["krm.kcl.dev/composition-resource-name"]
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = _render({})
    assert len(items) == 9, "2 roles + 4 attachments + Cluster + NodeGroup + ClusterAuth"
    assert _rn(items[0]) == "cluster-role", "control-plane role first"
    assert _rn(items[2]) == "node-role", "node role after its policies"
    assert _rn(items[6]) == "managed", "the EKS cluster is the managed resource"
    assert items[6].kind == "Cluster" and items[6].apiVersion == "eks.aws.m.upbound.io/v1beta1", "wrong cluster GVK"
    assert _rn(items[7]) == "nodes" and items[7].kind == "NodeGroup", "node group present"
    assert _rn(items[8]) == "auth" and items[8].kind == "ClusterAuth", "cluster auth present"
}

# ---- render: IAM roles ------------------------------------------------------
test_roles = lambda {
    items = _render({})
    _cr = items[0]
    assert _cr.metadata.labels["role"] == "cluster", "cluster role labelled for the ARN selector"
    assert _cr.metadata.annotations["crossplane.io/external-name"] == "demo-cluster", "cluster role name pinned"
    assert json.decode(_cr.spec.forProvider.assumeRolePolicy).Statement[0].Principal.Service == "eks.amazonaws.com", "control plane trusts EKS"
    _nr = items[2]
    assert _nr.metadata.labels["role"] == "node", "node role labelled for the ARN selector"
    assert json.decode(_nr.spec.forProvider.assumeRolePolicy).Statement[0].Principal.Service == "ec2.amazonaws.com", "nodes trust EC2"
    assert items[1].spec.forProvider.policyArn == "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy", "cluster policy attached"
    assert items[1].spec.forProvider.roleSelector.matchControllerRef == True, "attachment binds by controller ref"
    assert items[1].spec.forProvider.roleSelector.matchLabels == {"role" = "cluster"}, "attachment selects the labelled cluster role"
    assert [items[_i].spec.forProvider.policyArn for _i in [3, 4, 5]] == [
        "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ], "node policies attached"
    assert items[3].spec.forProvider.roleSelector.matchLabels == {"role" = "node"}, "attachment selects the labelled node role"
}

# ---- render: cluster --------------------------------------------------------
test_cluster = lambda {
    fp = _render({version = "1.32"})[6].spec.forProvider
    assert fp.region == "us-east-1", "region carried"
    assert fp.version == "1.32", "version carried"
    assert fp.roleArnSelector.matchControllerRef == True, "cluster binds the role by controller ref"
    assert fp.roleArnSelector.matchLabels == {"role" = "cluster"}, "cluster selects the cluster role"
    assert fp.vpcConfig.subnetIds == ["subnet-a", "subnet-b"], "subnets carried"
    off = _render({})[6].spec.forProvider
    assert not off?.version, "no version unless asked for"
}

# ---- render: node group -----------------------------------------------------
test_node_group = lambda {
    fp = _render({})[7].spec.forProvider
    assert fp.clusterNameSelector.matchControllerRef == True, "node group binds to the composed cluster"
    assert fp.nodeRoleArnSelector.matchLabels == {"role" = "node"}, "node group selects the node role"
    assert fp.subnetIds == ["subnet-a", "subnet-b"], "subnets carried"
    assert fp.instanceTypes == ["t3.medium"], "nodeSize defaults to small"
    assert fp.scalingConfig.desiredSize == 2 and fp.scalingConfig.minSize == 2 and fp.scalingConfig.maxSize == 2, "no autoscaling -> fixed size from nodeCount default"
    assert not fp?.capacityType, "on-demand unless spot"
}

test_machine_for = lambda {
    assert cluster.machine_for({nodeSize = "large"}) == "m5.xlarge", "size ladder"
    assert cluster.machine_for({machineType = "m6i.large"}) == "m6i.large", "explicit machineType wins"
    assert _render({nodeSize = "xlarge"})[7].spec.forProvider.instanceTypes == ["m5.2xlarge"], "ladder reaches the node group"
}

test_autoscaling_and_spot = lambda {
    fp = _render({nodeCount = 3, autoscaling = {min = 2, max = 10}, spot = True})[7].spec.forProvider
    assert fp.scalingConfig.desiredSize == 3 and fp.scalingConfig.minSize == 2 and fp.scalingConfig.maxSize == 10, "autoscaling bounds carried"
    assert fp.capacityType == "SPOT", "spot -> SPOT capacity"
}

# ---- render: kubeconfig -----------------------------------------------------
test_cluster_auth = lambda {
    auth = _render({})[8]
    assert auth.spec.forProvider.region == "us-east-1", "auth region carried"
    assert auth.spec.forProvider.clusterNameSelector.matchControllerRef == True, "auth binds to the composed cluster"
    assert auth.spec.writeConnectionSecretToRef.name == "demo-kubeconfig", "kubeconfig published as a connection secret"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = _render({deletionPolicy = "Orphan"})
    assert all _i in _orphaned {
        _i.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every MR"
    _deleted = _render({})[6].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = cluster.status(_build({}), {})
    assert dxr.kind == "KubernetesCluster", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.kubeconfigSecret == "demo-kubeconfig", "secret name known ahead of creation"
    assert dxr.status?.endpoint == Undefined, "no endpoint before the cluster exists"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "demo"
                        arn = "arn:aws:eks:us-east-1:111122223333:cluster/demo"
                        endpoint = "https://ABC.gr7.us-east-1.eks.amazonaws.com"
                        version = "1.32"
                        region = "us-east-1"
                    }
                }
            }
        }
    }
    dxr = cluster.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed endpoint must mark the cluster ready"
    assert dxr.status.endpoint == "https://ABC.gr7.us-east-1.eks.amazonaws.com", "endpoint surfaced"
    assert dxr.status.version == "1.32", "version surfaced"
    assert dxr.status.id == "arn:aws:eks:us-east-1:111122223333:cluster/demo", "arn surfaced as id"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/eks/home?region=us-east-1#/clusters/demo", "cloud-url points at the cluster"
}
