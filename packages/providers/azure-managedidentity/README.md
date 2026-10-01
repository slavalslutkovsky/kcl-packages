# azure-managedidentity

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-managedidentity`.

Source: ghcr.io/crossplane-contrib/provider-azure-managedidentity:v2.6.0 (scope=namespaced; service=managedidentity)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-managedidentity = { path = "<relative path>/packages/providers/azure-managedidentity" }
```

Then import a model:

```python
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_federated_identity_credential as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| FederatedIdentityCredential | `azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_federated_identity_credential` |
| UserAssignedIdentity | `azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_user_assigned_identity` |
