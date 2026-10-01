# cnpg

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed cnpg`.

Source: cloudnative-pg/cloudnative-pg@v1.27.1 (config/crd/bases); service=postgresql; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
cnpg = { path = "<relative path>/packages/providers/cnpg" }
```

Then import a model:

```python
import cnpg.models.v1.postgresql_cnpg_io_v1_backup as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Backup | `cnpg.models.v1.postgresql_cnpg_io_v1_backup` |
| Cluster | `cnpg.models.v1.postgresql_cnpg_io_v1_cluster` |
| ClusterImageCatalog | `cnpg.models.v1.postgresql_cnpg_io_v1_cluster_image_catalog` |
| Database | `cnpg.models.v1.postgresql_cnpg_io_v1_database` |
| FailoverQuorum | `cnpg.models.v1.postgresql_cnpg_io_v1_failover_quorum` |
| ImageCatalog | `cnpg.models.v1.postgresql_cnpg_io_v1_image_catalog` |
| Pooler | `cnpg.models.v1.postgresql_cnpg_io_v1_pooler` |
| Publication | `cnpg.models.v1.postgresql_cnpg_io_v1_publication` |
| ScheduledBackup | `cnpg.models.v1.postgresql_cnpg_io_v1_scheduled_backup` |
| Subscription | `cnpg.models.v1.postgresql_cnpg_io_v1_subscription` |
