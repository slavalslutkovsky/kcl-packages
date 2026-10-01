# velero

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed velero`.

Source: vmware-tanzu/velero@v1.18.2 (config/crd/v1/bases); service=velero; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
velero = { path = "<relative path>/packages/providers/velero" }
```

Then import a model:

```python
import velero.models.v1.velero_io_v1_backup as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Backup | `velero.models.v1.velero_io_v1_backup` |
| BackupRepository | `velero.models.v1.velero_io_v1_backup_repository` |
| BackupStorageLocation | `velero.models.v1.velero_io_v1_backup_storage_location` |
| DeleteBackupRequest | `velero.models.v1.velero_io_v1_delete_backup_request` |
| DownloadRequest | `velero.models.v1.velero_io_v1_download_request` |
| PodVolumeBackup | `velero.models.v1.velero_io_v1_pod_volume_backup` |
| PodVolumeRestore | `velero.models.v1.velero_io_v1_pod_volume_restore` |
| Restore | `velero.models.v1.velero_io_v1_restore` |
| Schedule | `velero.models.v1.velero_io_v1_schedule` |
| ServerStatusRequest | `velero.models.v1.velero_io_v1_server_status_request` |
| VolumeSnapshotLocation | `velero.models.v1.velero_io_v1_volume_snapshot_location` |
