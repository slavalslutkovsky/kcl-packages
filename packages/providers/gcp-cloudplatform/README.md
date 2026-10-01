# gcp-cloudplatform

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-cloudplatform`.

Source: ghcr.io/crossplane-contrib/provider-gcp-cloudplatform:v2.6.0 (scope=namespaced; service=cloudplatform)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-cloudplatform = { path = "<relative path>/packages/providers/gcp-cloudplatform" }
```

Then import a model:

```python
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Folder | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder` |
| FolderIAMMember | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder_i_a_m_member` |
| OrganizationIAMAuditConfig | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_audit_config` |
| OrganizationIAMCustomRole | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_custom_role` |
| OrganizationIAMMember | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_member` |
| Project | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project` |
| ProjectDefaultServiceAccounts | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_default_service_accounts` |
| ProjectIAMAuditConfig | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_audit_config` |
| ProjectIAMCustomRole | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_custom_role` |
| ProjectIAMMember | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_member` |
| ProjectService | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_service` |
| ProjectUsageExportBucket | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_usage_export_bucket` |
| ServiceAccount | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account` |
| ServiceAccountIAMMember | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account_i_a_m_member` |
| ServiceAccountKey | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account_key` |
| ServiceNetworkingPeeredDNSDomain | `gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_networking_peered_dns_domain` |
