# oci-family

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed oci-family`.

Source: ghcr.io/oracle/provider-family-oci:v2.0.0 (scope=namespaced; service=*)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
oci-family = { path = "<relative path>/packages/providers/oci-family" }
```

Then import a model:

```python
import oci_family.models.unknown as m

_t = m.ClusterProviderConfig
```

## Kinds

### unknown

Import the directory as one package — `import oci_family.models.unknown as m` — and use `m.<kind>`.

- ClusterProviderConfig
- ProviderConfig
- ProviderConfigUsage
