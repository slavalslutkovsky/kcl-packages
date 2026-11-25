# aws-backup

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-backup`.

Source: ghcr.io/crossplane-contrib/provider-aws-backup:v2.6.0 (scope=namespaced; service=backup)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-backup = { path = "<relative path>/packages/providers/aws-backup" }
```

Then import a model:

```python
import aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_framework as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Framework | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_framework` |
| GlobalSettings | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_global_settings` |
| Plan | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_plan` |
| RegionSettings | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_region_settings` |
| ReportPlan | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_report_plan` |
| Selection | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_selection` |
| Vault | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_vault` |
| VaultLockConfiguration | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_vault_lock_configuration` |
| VaultNotifications | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_vault_notifications` |
| VaultPolicy | `aws_backup.models.v1beta1.backup_awsm_upbound_io_v1beta1_vault_policy` |
