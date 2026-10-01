# gcp-redis

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-redis`.

Source: ghcr.io/crossplane-contrib/provider-gcp-redis:v2.6.0 (scope=namespaced; service=redis)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-redis = { path = "<relative path>/packages/providers/gcp-redis" }
```

Then import a model:

```python
import gcp_redis.models.v1beta1.redis_gcpm_upbound_io_v1beta1_cluster as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Cluster | `gcp_redis.models.v1beta1.redis_gcpm_upbound_io_v1beta1_cluster` |
| ClusterUserCreatedConnections | `gcp_redis.models.v1beta1.redis_gcpm_upbound_io_v1beta1_cluster_user_created_connections` |
| Instance | `gcp_redis.models.v1beta1.redis_gcpm_upbound_io_v1beta1_instance` |
