# aws-family

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-family`.

Source: ghcr.io/crossplane-contrib/provider-family-aws:v2.6.0 (scope=namespaced; service=*)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-family = { path = "<relative path>/packages/providers/aws-family" }
```

Then import a model:

```python
import aws_family.models.unknown as m

_t = m.ClusterProviderConfig
```

## Kinds

### unknown

Import the directory as one package — `import aws_family.models.unknown as m` — and use `m.<kind>`.

- ClusterProviderConfig
- ProviderConfig
- ProviderConfigUsage
