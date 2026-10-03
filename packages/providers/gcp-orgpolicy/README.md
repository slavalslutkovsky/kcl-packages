# gcp-orgpolicy

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-orgpolicy`.

Source: ghcr.io/crossplane-contrib/provider-gcp-orgpolicy:v2.6.0 (scope=namespaced; service=orgpolicy)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-orgpolicy = { path = "<relative path>/packages/providers/gcp-orgpolicy" }
```

Then import a model:

```python
import gcp_orgpolicy.models.v1beta1.orgpolicy_gcpm_upbound_io_v1beta1_policy as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Policy | `gcp_orgpolicy.models.v1beta1.orgpolicy_gcpm_upbound_io_v1beta1_policy` |
