# tekton

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed tekton`.

Source: tektoncd/pipeline@v1.16.0 (config/300-crds); service=300-pipeline,300-pipelinerun,300-task,300-taskrun; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
tekton = { path = "<relative path>/packages/providers/tekton" }
```

Then import a model:

```python
import tekton.models.v1.pipeline_v1 as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Pipeline | `tekton.models.v1.pipeline_v1` |
| PipelineRun | `tekton.models.v1.pipeline_run_v1` |
| Task | `tekton.models.v1.task_v1` |
| TaskRun | `tekton.models.v1.task_run_v1` |

### v1beta1

| kind | import |
| --- | --- |
| Pipeline | `tekton.models.v1beta1.pipeline_v1beta1` |
| PipelineRun | `tekton.models.v1beta1.pipeline_run_v1beta1` |
| Task | `tekton.models.v1beta1.task_v1beta1` |
| TaskRun | `tekton.models.v1beta1.task_run_v1beta1` |
