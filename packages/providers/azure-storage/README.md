# azure-storage

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-storage`.

Source: ghcr.io/crossplane-contrib/provider-azure-storage:v2.6.0 (scope=namespaced; service=storage)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-storage = { path = "<relative path>/packages/providers/azure-storage" }
```

Then import a model:

```python
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Account | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account` |
| AccountLocalUser | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account_local_user` |
| AccountNetworkRules | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account_network_rules` |
| Blob | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_blob` |
| BlobInventoryPolicy | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_blob_inventory_policy` |
| Container | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_container` |
| ContainerImmutabilityPolicy | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_container_immutability_policy` |
| DataLakeGen2FileSystem | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_data_lake_gen2_file_system` |
| DataLakeGen2Path | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_data_lake_gen2_path` |
| EncryptionScope | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_encryption_scope` |
| ManagementPolicy | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_management_policy` |
| ObjectReplication | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_object_replication` |
| Queue | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_queue` |
| Share | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_share` |
| ShareDirectory | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_share_directory` |
| Table | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_table` |
| TableEntity | `azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_table_entity` |

### unknown

Import the directory as one package — `import azure_storage.models.unknown as m` — and use `m.<kind>`.

- Account
- AccountLocalUser
- AccountNetworkRules
- Blob
- BlobInventoryPolicy
- Container
- ContainerImmutabilityPolicy
- DataLakeGen2FileSystem
- DataLakeGen2Path
- EncryptionScope
- ManagementPolicy
- ObjectReplication
- Queue
- Share
- ShareDirectory
- Table
- TableEntity
