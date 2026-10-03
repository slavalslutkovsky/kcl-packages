# backup-velero

Velero backend for the `BackupPlan` XR (`cloud.example.org/v1alpha1`,
Composition `backup-velero`, label `provider: velero`). Typed against the
schema package [`packages/providers/velero`](../../../providers/velero).
Velero is an operator, not a Crossplane provider, so this renders `velero.io/v1`
objects directly — no managed-resource wrapper, no `providerConfigRef`, no
`managementPolicies`. Velero splits a plan across three objects (when/what,
where metadata goes, where snapshots go); the XR keeps them from drifting
apart. `function-kcl` runs it from `oci://docker.io/yurikrupnik/backup-velero`;
`function-auto-ready` follows.

## Composed resources

All are `velero.io/v1`, named after the XR, in the XR's namespace.

| resource | when | notes |
| --- | --- | --- |
| `BackupStorageLocation` (`storage-location`) | always | `default: false`, so a plan never takes the cluster-wide default slot |
| `VolumeSnapshotLocation` (`snapshot-location`) | `snapshotVolumes` true and `defaultVolumesToFsBackup` false | same plugin and credential as the storage location |
| `Schedule` (`managed`) | always | `template.storageLocation` (and `volumeSnapshotLocations` when snapshotting) reference the locations above by name |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation.

The XR must live in Velero's own namespace (`velero` in the example): Velero
reads Schedules and locations only there, and a namespaced XR composes only
into its own namespace. What gets backed up is `includedNamespaces`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `schedule` | `Schedule.spec.schedule` |
| `retentionDays` | `template.ttl` in hours (`30` → `720h`; default 30) |
| `includedNamespaces` | `template.includedNamespaces`; empty is omitted, meaning every namespace |
| `includedResources`, `excludedResources` | `template.includedResources`, `template.excludedResources` |
| `labelSelector` | `template.labelSelector.matchLabels` |
| `snapshotVolumes` | `template.snapshotVolumes` (default true) |
| `defaultVolumesToFsBackup` | `template.defaultVolumesToFsBackup` (default false); true suppresses the `VolumeSnapshotLocation` |
| `paused` | `Schedule.spec.paused` |
| `tags` | `template.metadata.labels` — labels on each Backup, not on what is inside it |
| `destination.provider` | `spec.provider` of both locations, unchanged (`aws` \| `gcp` \| `azure`) |
| `destination.bucket`, `destination.prefix` | `objectStorage.bucket`, `objectStorage.prefix` |
| `destination.region` | `config.region` on both locations |
| `destination.s3Url` | `config.s3Url` plus `config.s3ForcePathStyle: "true"`, storage location only |
| `destination.credentialsSecret` | `spec.credential` on both locations; `key` defaults to `cloud` |

`deletionPolicy` is ignored: there are no managed resources to set
`managementPolicies` on. The Schedule and locations go with the XR; the
backups already in the bucket outlive it either way. The bucket itself is not
created here — compose a `Bucket` XR for it.

Status written back to the XR:

| field | value |
| --- | --- |
| `provider` | `velero` |
| `ready` | Schedule phase `Enabled` **and** storage location phase `Available` |
| `storageLocation` | the XR name (known before anything reconciles) |
| `phase` | Schedule phase, once reported |
| `storageLocationPhase` | storage location phase, once reported |
| `lastBackup` | Schedule `lastBackup`, once one has run |
| `message` | the storage location's message, else the Schedule's validation errors joined |

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (namespace `velero`, nightly at
02:00, `aws` destination `example-backups`). Pass a real XR as `params.oxr`:

```bash
# built-in example: storage location, snapshot location, Schedule + status
kcl run packages/cloud/backup/velero

# the shipped example (fs backup on RustFS: no VolumeSnapshotLocation)
kcl run packages/cloud/backup/velero \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/backup/xrd/examples/backup-velero.yaml)}"
```

Through Crossplane:

```bash
pnpm exec nx run backup-velero:render   # crossplane render of ../xrd/examples/backup-velero.yaml; needs docker
just install-module backup              # XRD + the velero Composition, on the current cluster
just workload backup velero             # + provider-helm and the Velero Release, then apply backup-velero.yaml
just e2e backup                         # kind cluster, local registry, publish, install, apply every example
```

The module ships no cloud provider: [`../xrd/providers.yaml`](../xrd/providers.yaml)
installs provider-helm, and [`../xrd/providerconfigs.yaml`](../xrd/providerconfigs.yaml)
installs the Velero operator (with the aws, gcp and azure plugins and the
node-agent) as a Helm `Release` into `velero`.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` + `status` |
| `backup.k` | `render(oxr)`, `status(oxr, ocds)`, `ttl_hours(days)` |
| `backup_test.k` | `kcl test` cases: locations, credentials, snapshot rule, schedule template, ignored `deletionPolicy`, status |
| `composition.yaml` | Composition `backup-velero` (function-kcl → function-auto-ready) |

## Development

```bash
pnpm exec nx run backup-velero:test     # kcl test
pnpm exec nx run backup-velero:lint     # kcl lint
pnpm exec nx run backup-velero:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
