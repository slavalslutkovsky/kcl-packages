# gcp-storage

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-storage`.

Source: ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0 (scope=namespaced; service=storage)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-storage = { path = "<relative path>/packages/providers/gcp-storage" }
```

Then import a model:

```python
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Bucket | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket` |
| BucketAccessControl | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_access_control` |
| BucketACL | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_acl` |
| BucketIAMMember | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_i_a_m_member` |
| BucketIAMPolicy | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_i_a_m_policy` |
| BucketObject | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_object` |
| DefaultObjectAccessControl | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_default_object_access_control` |
| DefaultObjectACL | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_default_object_acl` |
| HMACKey | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_h_m_a_c_key` |
| ManagedFolder | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_managed_folder` |
| ManagedFolderIAMMember | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_managed_folder_i_a_m_member` |
| Notification | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_notification` |
| ObjectAccessControl | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_object_access_control` |
| ObjectACL | `gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_object_acl` |

### unknown

Import the directory as one package — `import gcp_storage.models.unknown as m` — and use `m.<kind>`.

- Bucket
- BucketAccessControl
- BucketACL
- BucketIAMMember
- BucketIAMPolicy
- BucketObject
- DefaultObjectAccessControl
- DefaultObjectACL
- HMACKey
- ManagedFolder
- ManagedFolderIAMMember
- Notification
- ObjectAccessControl
- ObjectACL
