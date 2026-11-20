# azure-dataprotection

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-dataprotection`.

Source: ghcr.io/crossplane-contrib/provider-azure-dataprotection:v2.6.0 (scope=namespaced; service=dataprotection)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-dataprotection = { path = "<relative path>/packages/providers/azure-dataprotection" }
```

Then import a model:

```python
import azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_blob_storage as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| BackupInstanceBlobStorage | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_blob_storage` |
| BackupInstanceDisk | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_disk` |
| BackupInstanceKubernetesCluster | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_kubernetes_cluster` |
| BackupInstancePostgreSQL | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_postgre_sql` |
| BackupInstancePostgreSQLFlexibleServer | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_instance_postgre_sql_flexible_server` |
| BackupPolicyBlobStorage | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_blob_storage` |
| BackupPolicyDisk | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_disk` |
| BackupPolicyKubernetesCluster | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_kubernetes_cluster` |
| BackupPolicyPostgreSQL | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_postgre_sql` |
| BackupPolicyPostgreSQLFlexibleServer | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_policy_postgre_sql_flexible_server` |
| BackupVault | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_backup_vault` |
| ResourceGuard | `azure_dataprotection.models.v1beta1.dataprotection_azurem_upbound_io_v1beta1_resource_guard` |
