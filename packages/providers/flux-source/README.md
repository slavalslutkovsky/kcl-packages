# flux-source

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed flux-source`.

Source: fluxcd/source-controller@v1.9.2 (config/crd/bases); service=source; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
flux-source = { path = "<relative path>/packages/providers/flux-source" }
```

Then import a model:

```python
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_bucket as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Bucket | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_bucket` |
| ExternalArtifact | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_external_artifact` |
| GitRepository | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_git_repository` |
| HelmChart | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_helm_chart` |
| HelmRepository | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_helm_repository` |
| OCIRepository | `flux_source.models.v1.source_toolkit_fluxcd_io_v1_o_c_i_repository` |
