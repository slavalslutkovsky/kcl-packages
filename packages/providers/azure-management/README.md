# azure-management

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-management`.

Source: ghcr.io/crossplane-contrib/provider-azure-management:v2.6.0 (scope=namespaced; service=management)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-management = { path = "<relative path>/packages/providers/azure-management" }
```

Then import a model:

```python
import azure_management.models.v1beta1.management_azurem_upbound_io_v1beta1_management_group as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ManagementGroup | `azure_management.models.v1beta1.management_azurem_upbound_io_v1beta1_management_group` |
| ManagementGroupSubscriptionAssociation | `azure_management.models.v1beta1.management_azurem_upbound_io_v1beta1_management_group_subscription_association` |
