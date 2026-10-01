# aws-ecr

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-ecr`.

Source: ghcr.io/crossplane-contrib/provider-aws-ecr:v2.6.0 (scope=namespaced; service=ecr)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-ecr = { path = "<relative path>/packages/providers/aws-ecr" }
```

Then import a model:

```python
import aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_lifecycle_policy as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| LifecyclePolicy | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_lifecycle_policy` |
| PullThroughCacheRule | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_pull_through_cache_rule` |
| RegistryPolicy | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_registry_policy` |
| RegistryScanningConfiguration | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_registry_scanning_configuration` |
| ReplicationConfiguration | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_replication_configuration` |
| Repository | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_repository` |
| RepositoryCreationTemplate | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_repository_creation_template` |
| RepositoryPolicy | `aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_repository_policy` |
