# gcp-gke

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-gke`.

Source: ghcr.io/crossplane-contrib/provider-gcp-gke:v2.6.0 (scope=namespaced; service=gke)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-gke = { path = "<relative path>/packages/providers/gcp-gke" }
```

Then import a model:

```python
import gcp_gke.models.v1beta1.gke_gcpm_upbound_io_v1beta1_backup_backup_plan as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| BackupBackupPlan | `gcp_gke.models.v1beta1.gke_gcpm_upbound_io_v1beta1_backup_backup_plan` |
