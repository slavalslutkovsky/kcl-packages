# aws-eks

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-eks`.

Source: ghcr.io/crossplane-contrib/provider-aws-eks:v2.6.0 (scope=namespaced; service=eks)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-eks = { path = "<relative path>/packages/providers/aws-eks" }
```

Then import a model:

```python
import aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_access_entry as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AccessEntry | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_access_entry` |
| AccessPolicyAssociation | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_access_policy_association` |
| Addon | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_addon` |
| Capability | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_capability` |
| Cluster | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_cluster` |
| ClusterAuth | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_cluster_auth` |
| FargateProfile | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_fargate_profile` |
| IdentityProviderConfig | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_identity_provider_config` |
| NodeGroup | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_node_group` |
| PodIdentityAssociation | `aws_eks.models.v1beta1.eks_awsm_upbound_io_v1beta1_pod_identity_association` |
