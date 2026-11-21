# gcp-secretmanager

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-secretmanager`.

Source: ghcr.io/crossplane-contrib/provider-gcp-secretmanager:v2.6.0 (scope=namespaced; service=secretmanager)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-secretmanager = { path = "<relative path>/packages/providers/gcp-secretmanager" }
```

Then import a model:

```python
import gcp_secretmanager.models.unknown as m

_t = m.Secret
```

## Kinds

### unknown

Import the directory as one package — `import gcp_secretmanager.models.unknown as m` — and use `m.<kind>`.

- Secret
- SecretIAMMember
- SecretVersion
