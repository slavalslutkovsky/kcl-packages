# gcp-networkconnectivity

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-networkconnectivity`.

Source: ghcr.io/crossplane-contrib/provider-gcp-networkconnectivity:v2.6.0 (scope=namespaced; service=networkconnectivity)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-networkconnectivity = { path = "<relative path>/packages/providers/gcp-networkconnectivity" }
```

Then import a model:

```python
import gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_group as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Group | `gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_group` |
| Hub | `gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_hub` |
| InternalRange | `gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_internal_range` |
| ServiceConnectionPolicy | `gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_service_connection_policy` |
| Spoke | `gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_spoke` |
