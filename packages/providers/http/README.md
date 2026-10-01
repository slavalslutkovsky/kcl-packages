# http

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed http`.

Source: xpkg.crossplane.io/crossplane-contrib/provider-http:v1.0.15 (scope=namespaced; service=http)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
http = { path = "<relative path>/packages/providers/http" }
```

Then import a model:

```python
import http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_cluster_provider_config as model
```

## Kinds

### v1alpha2

| kind | import |
| --- | --- |
| ClusterProviderConfig | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_cluster_provider_config` |
| ClusterProviderConfigUsage | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_cluster_provider_config_usage` |
| DisposableRequest | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_disposable_request` |
| ProviderConfig | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_provider_config` |
| ProviderConfigUsage | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_provider_config_usage` |
| Request | `http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_request` |
