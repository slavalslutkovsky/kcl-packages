# gcp-artifact

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-artifact`.

Source: ghcr.io/crossplane-contrib/provider-gcp-artifact:v2.6.0 (scope=namespaced; service=artifact)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-artifact = { path = "<relative path>/packages/providers/gcp-artifact" }
```

Then import a model:

```python
import gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| RegistryRepository | `gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository` |
| RegistryRepositoryIAMMember | `gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository_i_a_m_member` |
