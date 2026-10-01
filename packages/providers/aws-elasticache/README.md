# aws-elasticache

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-elasticache`.

Source: ghcr.io/crossplane-contrib/provider-aws-elasticache:v2.6.0 (scope=namespaced; service=elasticache)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-elasticache = { path = "<relative path>/packages/providers/aws-elasticache" }
```

Then import a model:

```python
import aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_cluster as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Cluster | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_cluster` |
| GlobalReplicationGroup | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_global_replication_group` |
| ParameterGroup | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_parameter_group` |
| ReplicationGroup | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_replication_group` |
| ServerlessCache | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_serverless_cache` |
| SubnetGroup | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_subnet_group` |
| User | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_user` |
| UserGroup | `aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_user_group` |
