# argocd

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed argocd`.

Source: argoproj/argo-cd@v3.5.3 (manifests/crds); service=*; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
argocd = { path = "<relative path>/packages/providers/argocd" }
```

Then import a model:

```python
import argocd.models.v1alpha1.argoproj_io_v1alpha1_application as model
```

## Kinds

### v1alpha1

| kind | import |
| --- | --- |
| Application | `argocd.models.v1alpha1.argoproj_io_v1alpha1_application` |
| ApplicationSet | `argocd.models.v1alpha1.argoproj_io_v1alpha1_application_set` |
| AppProject | `argocd.models.v1alpha1.argoproj_io_v1alpha1_app_project` |
