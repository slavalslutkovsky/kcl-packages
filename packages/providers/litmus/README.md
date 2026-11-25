# litmus

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed litmus`.

Source: litmuschaos/litmus-helm@litmus-core-3.31.1 (charts/litmus-core/crds); service=*; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
litmus = { path = "<relative path>/packages/providers/litmus" }
```

Then import a model:

```python
import litmus.models.unknown as m

_t = m.ChaosEngine
```

## Kinds

### unknown

Import the directory as one package — `import litmus.models.unknown as m` — and use `m.<kind>`.

- ChaosEngine
- ChaosExperiment
- ChaosResult
