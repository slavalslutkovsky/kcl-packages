# helm

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed helm`.

Source: ghcr.io/crossplane-contrib/provider-helm:v1.3.0 (scope=namespaced; service=helm)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
helm = { path = "<relative path>/packages/providers/helm" }
```

Then import a model:

```python
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_cluster_provider_config as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ClusterProviderConfig | `helm.models.v1beta1.helmm_crossplane_io_v1beta1_cluster_provider_config` |
| ProviderConfig | `helm.models.v1beta1.helmm_crossplane_io_v1beta1_provider_config` |
| ProviderConfigUsage | `helm.models.v1beta1.helmm_crossplane_io_v1beta1_provider_config_usage` |
| Release | `helm.models.v1beta1.helmm_crossplane_io_v1beta1_release` |
