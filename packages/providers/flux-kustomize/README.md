# flux-kustomize

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed flux-kustomize`.

Source: fluxcd/kustomize-controller@v1.9.2 (config/crd/bases); service=kustomize; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
flux-kustomize = { path = "<relative path>/packages/providers/flux-kustomize" }
```

Then import a model:

```python
import flux_kustomize.models.v1.kustomize_toolkit_fluxcd_io_v1_kustomization as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Kustomization | `flux_kustomize.models.v1.kustomize_toolkit_fluxcd_io_v1_kustomization` |
