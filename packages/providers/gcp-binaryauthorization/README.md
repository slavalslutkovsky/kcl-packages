# gcp-binaryauthorization

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-binaryauthorization`.

Source: ghcr.io/crossplane-contrib/provider-gcp-binaryauthorization:v2.6.0 (scope=namespaced; service=binaryauthorization)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-binaryauthorization = { path = "<relative path>/packages/providers/gcp-binaryauthorization" }
```

Then import a model:

```python
import gcp_binaryauthorization.models.unknown as m

_t = m.Attestor
```

## Kinds

### unknown

Import the directory as one package — `import gcp_binaryauthorization.models.unknown as m` — and use `m.<kind>`.

- Attestor
- Policy
