# gcp-workflows

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-workflows`.

Source: ghcr.io/crossplane-contrib/provider-gcp-workflows:v2.6.0 (scope=namespaced; service=workflows)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-workflows = { path = "<relative path>/packages/providers/gcp-workflows" }
```

Then import a model:

```python
import gcp_workflows.models.v1beta1.workflows_gcpm_upbound_io_v1beta1_workflow as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Workflow | `gcp_workflows.models.v1beta1.workflows_gcpm_upbound_io_v1beta1_workflow` |
