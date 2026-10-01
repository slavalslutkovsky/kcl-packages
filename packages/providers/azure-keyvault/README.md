# azure-keyvault

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-keyvault`.

Source: ghcr.io/crossplane-contrib/provider-azure-keyvault:v2.6.0 (scope=namespaced; service=keyvault)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-keyvault = { path = "<relative path>/packages/providers/azure-keyvault" }
```

Then import a model:

```python
import azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_access_policy as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AccessPolicy | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_access_policy` |
| Certificate | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_certificate` |
| CertificateContacts | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_certificate_contacts` |
| CertificateIssuer | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_certificate_issuer` |
| Key | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_key` |
| ManagedHardwareSecurityModule | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_managed_hardware_security_module` |
| ManagedStorageAccount | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_managed_storage_account` |
| ManagedStorageAccountSASTokenDefinition | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_managed_storage_account_s_a_s_token_definition` |
| Secret | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_secret` |
| Vault | `azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_vault` |
