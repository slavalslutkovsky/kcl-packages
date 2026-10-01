# gcp-cloudbuild

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-cloudbuild`.

Source: ghcr.io/crossplane-contrib/provider-gcp-cloudbuild:v2.6.0 (scope=namespaced; service=cloudbuild)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-cloudbuild = { path = "<relative path>/packages/providers/gcp-cloudbuild" }
```

Then import a model:

```python
import gcp_cloudbuild.models.v1beta1.cloudbuild_gcpm_upbound_io_v1beta1_trigger as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Trigger | `gcp_cloudbuild.models.v1beta1.cloudbuild_gcpm_upbound_io_v1beta1_trigger` |
| WorkerPool | `gcp_cloudbuild.models.v1beta1.cloudbuild_gcpm_upbound_io_v1beta1_worker_pool` |
