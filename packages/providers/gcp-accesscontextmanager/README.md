# gcp-accesscontextmanager

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-accesscontextmanager`.

Source: ghcr.io/crossplane-contrib/provider-gcp-accesscontextmanager:v2.6.0 (scope=namespaced; service=accesscontextmanager)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-accesscontextmanager = { path = "<relative path>/packages/providers/gcp-accesscontextmanager" }
```

Then import a model:

```python
import gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_access_level as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AccessLevel | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_access_level` |
| AccessLevelCondition | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_access_level_condition` |
| AccessPolicy | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_access_policy` |
| AccessPolicyIAMMember | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_access_policy_i_a_m_member` |
| ServicePerimeter | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_service_perimeter` |
| ServicePerimeterResource | `gcp_accesscontextmanager.models.v1beta1.accesscontextmanager_gcpm_upbound_io_v1beta1_service_perimeter_resource` |
