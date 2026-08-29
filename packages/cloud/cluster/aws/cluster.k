# cluster (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-eks and aws-iam schema packages. The portable
# KubernetesCluster maps onto an EKS Cluster + managed NodeGroup, plus the two
# IAM roles EKS cannot exist without (control plane and node role, each with
# its AWS-managed policies) and a ClusterAuth that publishes the kubeconfig as
# a connection secret. The roles are disambiguated for the ARN selectors with
# a `role` label, since both are owned by the same composite.
import json
import aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_cluster as ekscluster
import aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_node_group as nodegroup
import aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_cluster_auth as clusterauth
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as role
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment as attachment

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract node shape -> EC2 instance type.
_machine = {"small" = "t3.medium", "medium" = "m5.large", "large" = "m5.xlarge", "xlarge" = "m5.2xlarge"}

machine_for = lambda spec: any -> str {
    spec?.machineType or _machine[spec?.nodeSize or "small"]
}

# Service trust policy for the control-plane / node roles.
service_trust = lambda service: str -> str {
    json.encode({
        Version = "2012-10-17"
        Statement = [{Effect = "Allow", Principal = {Service = service}, Action = "sts:AssumeRole"}]
    })
}

# AWS-managed policies each role needs.
_cluster_policies = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
_node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
]

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _subnets = _spec?.network?.subnets or []
    assert len(_subnets) > 0, "cluster-aws: spec.network.subnets is required — an EKS cluster cannot exist without subnets"

    _count = _spec?.nodeCount or 2
    _as = _spec?.autoscaling

    # One IAM role + its policy attachments; `which` disambiguates the two
    # composed roles for the ARN selectors.
    _role_set = lambda which: str -> [any] {
        _svc = "eks.amazonaws.com" if which == "cluster" else "ec2.amazonaws.com"
        _policies = _cluster_policies if which == "cluster" else _node_policies
        _rs: [any] = [role.Role {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "${which}-role"
                "crossplane.io/external-name" = "${_name}-${which}"
            }
            metadata.labels = {"role" = which}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.assumeRolePolicy = service_trust(_svc)
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]
        _rs += [attachment.RolePolicyAttachment {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "${which}-policy-${_i}"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.policyArn = _p
            spec.forProvider.roleSelector = {matchControllerRef = True, matchLabels = {"role" = which}}
        } for _i, _p in _policies]
        _rs
    }

    _items: [any] = _role_set("cluster") + _role_set("node")

    # The control plane.
    _items += [ekscluster.Cluster {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        if _spec?.version:
            spec.forProvider.version = _spec.version
        spec.forProvider.roleArnSelector = {matchControllerRef = True, matchLabels = {"role" = "cluster"}}
        spec.forProvider.vpcConfig.subnetIds = _subnets
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # The workers.
    _items += [nodegroup.NodeGroup {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "nodes"
            "crossplane.io/external-name" = "${_name}-nodes"
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.clusterNameSelector.matchControllerRef = True
        spec.forProvider.nodeRoleArnSelector = {matchControllerRef = True, matchLabels = {"role" = "node"}}
        spec.forProvider.subnetIds = _subnets
        spec.forProvider.instanceTypes = [machine_for(_spec)]
        spec.forProvider.scalingConfig = {
            desiredSize = _count
            minSize = (_as?.min) if _as else _count
            maxSize = (_as?.max) if _as else _count
        }
        if _spec?.spot:
            spec.forProvider.capacityType = "SPOT"
        if _spec?.version:
            spec.forProvider.version = _spec.version
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # Kubeconfig, refreshed and published as a namespace-local connection secret.
    _items += [clusterauth.ClusterAuth {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "auth"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.clusterNameSelector.matchControllerRef = True
        spec.writeConnectionSecretToRef.name = "${_name}-kubeconfig"
    }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _region = (_at?.region) or oxr.spec.region
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "KubernetesCluster"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = (_at?.endpoint or "") != ""
            name = (_at?.id) or _name
            kubeconfigSecret = "${_name}-kubeconfig"
            "cloud-url" = "https://${_region}.console.aws.amazon.com/eks/home?region=${_region}#/clusters/${(_at?.id) or _name}"
            if _at:
                if _at?.endpoint:
                    endpoint = _at.endpoint
                if _at?.version:
                    version = _at.version
                if _at?.arn:
                    id = _at.arn
        }
    }
}
