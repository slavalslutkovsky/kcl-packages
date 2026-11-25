# gcp-servicenetworking

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-servicenetworking`.

Source: ghcr.io/crossplane-contrib/provider-gcp-servicenetworking:v2.6.0 (scope=namespaced; service=servicenetworking)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-servicenetworking = { path = "<relative path>/packages/providers/gcp-servicenetworking" }
```

Then import a model:

```python
import gcp_servicenetworking.models.unknown as m

_t = m.Connection
```

## Kinds

### unknown

Import the directory as one package — `import gcp_servicenetworking.models.unknown as m` — and use `m.<kind>`.

- Connection
