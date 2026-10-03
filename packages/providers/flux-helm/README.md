# flux-helm

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed flux-helm`.

Source: fluxcd/helm-controller@v1.6.2 (config/crd/bases); service=helm; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
flux-helm = { path = "<relative path>/packages/providers/flux-helm" }
```

Then import a model:

```python
import flux_helm.models.v2.helm_toolkit_fluxcd_io_v2_helm_release as model
```

## Kinds

### v2

| kind | import |
| --- | --- |
| HelmRelease | `flux_helm.models.v2.helm_toolkit_fluxcd_io_v2_helm_release` |
