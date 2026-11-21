# Backup

Two layers, one destination:

- **`BackupPlan`** — the portable capability. One XR carries a cron, a
  retention and a filter, and four backends turn it into a working plan:
  `velero` (an in-cluster operator writing to a bucket — any cluster,
  including self-hosted ones) and the cloud-managed services `aws` (AWS
  Backup for EKS), `gcp` (Backup for GKE) and `azure` (Azure Backup for AKS).
  This is the layer that backs up *workloads*: namespaces, their objects, and
  the volumes their pods mount — including the disks behind a
  `VirtualMachine`.
- **`PostgresInstance.spec.backup`** — native backup for the one workload that
  must not be snapshotted from the outside. CloudNativePG runs base backups and
  WAL archiving itself (`barmanObjectStore`), so an in-cluster database gets
  point-in-time recovery instead of a crash-consistent volume copy. The managed
  backends ignore the block: RDS, Cloud SQL and Flexible Server already back
  themselves up.

Neither layer creates a bucket. Both point at one, and in the usual flow that
bucket is a `Bucket` XR — one object per concern, so deleting a plan can never
take the backups with it. (The `aws` and `gcp` backends need no bucket at all:
AWS Backup writes to the vault the plan composes, Backup for GKE to
Google-managed storage.)

```
kubectl -n velero  apply -f packages/cloud/backup/xrd/examples/backup-velero.yaml
kubectl -n default apply -f packages/cloud/backup/xrd/examples/backup-aws.yaml    # or -gcp / -azure
kubectl -n default apply -f packages/cloud/postgres/xrd/examples/postgres-cnpg.yaml
```

## What renders to what

`packages/providers/crds.yaml` has the full used/unused list. The `velero`
backend renders three of Velero's eleven kinds, from one XR:

| `BackupPlan` field | lands on | notes |
|---|---|---|
| `destination.provider` | `BackupStorageLocation.spec.provider` **and** `VolumeSnapshotLocation.spec.provider` | The XRD enum (`aws`/`gcp`/`azure`) is already Velero's plugin naming, so it passes through untranslated. |
| `destination.bucket`, `destination.prefix` | `objectStorage.{bucket,prefix}` | The bucket must already exist. No prefix means the bucket root. |
| `destination.region` | `config.region` | Read by the aws plugin (and by azure for its snapshots); gcp discovers the location itself. |
| `destination.s3Url` | `config.s3Url` **+** `config.s3ForcePathStyle: "true"` | The two always travel together: an S3-compatible server has no per-bucket DNS. |
| `destination.credentialsSecret` | `spec.credential` (`{name, key}`, key defaults to `cloud`) | Resolved in the location's own namespace. Unset means the server's ambient identity. |
| — | `spec.default: false` | Never set. The cluster default is a single slot, and two plans would fight over it. |
| `schedule` | `Schedule.spec.schedule` | Verbatim; Velero also accepts `@every 12h`. |
| `paused` | `Schedule.spec.paused` | Stops new backups; existing ones still expire on their own TTL. |
| `retentionDays` | `template.ttl` | Multiplied out to hours (`30` → `720h`): Go's duration parser has no day. |
| `includedNamespaces` | `template.includedNamespaces` | Empty means *every* namespace, which Velero spells as the field being absent — so an empty list is not emitted. |
| `includedResources`, `excludedResources` | same names on `template` | Verbatim. Excluding `events`/`events.events.k8s.io` is the usual first entry. |
| `labelSelector` | `template.labelSelector.matchLabels` | Volumes come in through the pods that mount them, so a selector that misses a pod misses its PVC. |
| `snapshotVolumes` | `template.snapshotVolumes` + a `VolumeSnapshotLocation` | The location is only rendered when snapshots are actually taken (see below). |
| `defaultVolumesToFsBackup` | `template.defaultVolumesToFsBackup` | Suppresses the snapshot location. |
| — | `template.storageLocation`, `template.volumeSnapshotLocations` | Always by name, pointing at this plan's own composed locations. |
| `tags` | `template.metadata.labels` | Labels on each `Backup` object, so `velero backup get -l team=platform` works. Not on what is inside the backup. |
| `deletionPolicy` | nothing | Ignored — see [Deleting a plan](#deleting-a-plan). |

The three objects land in the XR's own namespace, which is why a `BackupPlan`
belongs in Velero's: the server reconciles Schedules and locations only in the
namespace it runs in, and a namespaced XR may only compose into its own. What
gets backed up is `includedNamespaces`, never where the plan lives.

`status` is the AND of two objects, because half a plan is no plan:

| field | from |
|---|---|
| `ready` | `Schedule.status.phase == Enabled` **and** `BackupStorageLocation.status.phase == Available` |
| `phase`, `lastBackup` | `Schedule.status` |
| `storageLocationPhase` | the location's `status.phase` |
| `storageLocation` | derived from the XR name, so it is reported before anything reconciles |
| `message` | the location's `status.message`, else the Schedule's `validationErrors` joined |

An enabled schedule writing to a bucket Velero cannot reach reports
`Unavailable` and never lands anything, which is precisely the failure mode a
single `ready` boolean has to catch.

There is deliberately **no** `lastBackupPhase` and **no** `backupCount`: a
Velero `Schedule` reports when it last fired, not how that backup ended, and
counting backups means listing `Backup` objects the Composition does not
observe. `velero backup get` answers both.

## Snapshots, or file-level backup

This is the one knob that decides whether a self-hosted cluster has backups at
all.

| | `snapshotVolumes: true` (default) | `defaultVolumesToFsBackup: true` |
|---|---|---|
| what is copied | the storage layer's own snapshot of the volume | the files, read through the pod by Velero's Kopia uploader |
| needs | a CSI driver with a `VolumeSnapshotClass`, or a cloud volume plugin | the `node-agent` DaemonSet on every node |
| renders | a `VolumeSnapshotLocation` | no snapshot location — there is nothing to put in it |
| speed | fast, storage-side | slow, reads every byte through the network |
| works on | EBS, PD, Azure Disk, Ceph, Longhorn, … | anything, including `local-path`, hostPath and NFS |

A default Kind or bare-metal cluster runs `local-path`, which has no CSI
snapshot support whatsoever. A snapshot-based plan there succeeds and captures
nothing but metadata — the worst possible outcome, because it looks like a
backup. `defaultVolumesToFsBackup: true` is what makes that cluster
recoverable, and it is why `providerconfigs.yaml` turns on `deployNodeAgent`
(the chart leaves it off).

## Where the backups go

`destination` is an object store that already exists. Three ways to name one:

1. **A cloud bucket.** `provider: aws|gcp|azure` + `bucket` + `region`. In the
   usual flow the bucket is a `Bucket` XR in this repo and `bucket` here is
   that XR's name — the same string as its `status.bucketName` unless the
   backend renamed it. The `BackupPlan` deliberately does not create it: a
   bucket outliving its plan is the point.
2. **An in-cluster S3-compatible server** — RustFS (the `rustfs` `Bucket`
   backend), MinIO, Ceph RGW. `provider: aws` plus `s3Url` pointed at the
   Service that fronts it; `s3ForcePathStyle` follows automatically. A
   self-hosted cluster that backs up to its own storage has survived a pod, not
   a cluster, so treat this as the staging rung and mirror the bucket off-box.
3. **A cloud bucket from a self-hosted cluster** — the combination the whole
   capability exists for. `provider: aws`, a real bucket, and a
   `credentialsSecret`, because there is no IRSA or Workload Identity outside a
   managed control plane. With `defaultVolumesToFsBackup: true` this is a
   bare-metal cluster on local disks writing recoverable backups to S3.

Known wrinkle with (2): plugin v1.11+ uses `aws-sdk-go-v2`, and some
S3-compatible servers reject its trailing checksums with
`XAmzContentSHA256Mismatch` (Ceph S3 and Backblaze B2 are the documented ones).
The fix upstream is `checksumAlgorithm: ""` in the location's `config`, which
this XR does not expose — patch the composed `BackupStorageLocation` if you hit
it.

## Deleting a plan

`deletionPolicy` is on the XRD for API symmetry with every other capability,
and the velero backend ignores it. Velero CRs are plain custom resources, not
Crossplane managed resources, so there are no `managementPolicies` to set:
the Schedule and the locations are owned by the XR and go when it goes.

What *neither* value touches is the data. Backups are `Backup` objects with
their own TTL and they outlive the plan either way — which is the honest
behaviour for a backup system, and also means deleting a `BackupPlan` does not
reclaim a byte of storage. To actually delete backups, delete the `Backup`
objects (`velero backup delete`) and let Velero empty the bucket, or empty it
yourself.

## Cloud-managed backends

`aws`, `gcp` and `azure` hand the same `BackupPlan` to the cloud's own backup
service instead of an in-cluster operator. They back up the managed cluster
named by `spec.cluster.id` — the provider's own id, which a `KubernetesCluster`
XR publishes as `status.id` — and the backends parse region, project,
subscription and resource group out of it.

| | `aws` — AWS Backup for EKS | `gcp` — Backup for GKE | `azure` — Azure Backup for AKS |
|---|---|---|---|
| composes | `Vault`, `Plan`, `Selection` of the cluster ARN, service `Role` + 2 `RolePolicyAttachment`s | one `BackupBackupPlan` | `BackupVault`, `BackupPolicyKubernetesCluster`, `BackupInstanceKubernetesCluster`, the AKS backup `KubernetesClusterExtension`, a `TrustedAccessRoleBinding`, 7 `RoleAssignment`s, and the cluster itself Observe-only (for its identity) |
| backups land in | the composed vault | Google-managed storage | the vault's operational store, staged through `destination`'s blob container |
| `destination` | ignored | ignored | required (container + `storageAccount`) |
| `schedule` | rewritten to `cron(m h dom mon dow *)`, UTC; at most hourly | cron, UTC; shorthands expanded | only daily or every 4/6/8/12 h; anything else fails |
| `retentionDays` | `lifecycle.deleteAfter` | `backupRetainDays`, ≤ 365 and ≤ 360 × interval | `P<n>D`, ≤ 360 |
| namespace / resource / label filters | ignored — whole cluster (a superset) | namespaces; `secrets` exclusion only | all of them |
| `paused` | the Selection is withdrawn | `backupSchedule.paused` | fails the render |
| `encryptionKmsKeyId` | vault `kmsKeyArn` | `encryptionKey` | ignored |
| `ready` | every MR Ready | MR Ready **and** state `READY` | every MR Ready |

Fields a backend ignores only ever make the backup capture *more* than asked.
Anything that would make it capture less, or that the service cannot express
(an untranslatable cron, a pause on Azure), fails the render with a
`backup-<backend>:` message instead of composing something that looks right.

Each needs things the XR does not own; the backend READMEs list them in full:

- **aws** — EKS authentication mode `API` or `API_AND_CONFIG_MAP` (AWS Backup
  reaches the cluster through an access entry; `cluster/aws` leaves the
  `CONFIG_MAP` default), EKS opted in to AWS Backup in the region (account-wide
  `RegionSettings`, so not composed per plan), CSI-provisioned volumes. The
  role is a custom one because the service-linked role cannot create access
  entries.
- **gcp** — `gkebackup.googleapis.com` enabled and the cluster's
  `gkeBackupAgentConfig` add-on on (`cluster/gcp` does not set it; until it is,
  the plan sits in `CLUSTER_PENDING` and the XR stays not-ready).
- **azure** — a system-assigned cluster identity, the CSI disk driver and
  snapshot controller, `Microsoft.KubernetesConfiguration` and
  `Microsoft.DataProtection` registered, and a ProviderConfig identity that may
  create role assignments. The backend renders progressively: cluster, vault
  and policy first; the extension, trusted access and role assignments as the
  identities they need appear in observed status; the backup instance last,
  only once everything it depends on is Ready (Azure checks permissions when
  the instance is created). Changing filters, schedule or retention later
  forces a replacement upstream that upjet refuses to perform, and replacing a
  backup instance deletes its backups — treat those fields as create-time.

Deleting is where the services differ most — see `deletionPolicy` in the XRD.
An AWS vault or a Backup for GKE plan cannot be deleted while it holds
backups, so `Delete` leaves the resource stuck until they expire; deleting an
Azure backup instance stops protection *and deletes its data*. The azure
example therefore ships with `deletionPolicy: Orphan`.

Restores stay human here too: `aws backup start-restore-job`, `gcloud beta
container backup-restore restores create`, or the Azure portal/CLI.

## The database is not a workload

A PostgreSQL volume snapshot taken while the server is running is
crash-consistent at best: it recovers to whatever was on disk at that instant,
with no WAL beyond it and no way to roll forward. That is why
`PostgresInstance` has its own backup, and why `spec.backup` is in-cluster only.

| `spec.backup` field | lands on `Cluster.spec.backup.barmanObjectStore` |
|---|---|
| `provider` | picks the scheme and the credential block: `s3://` + `s3Credentials`, `gs://` + `googleCredentials`, the Azure blob URL + `azureCredentials` |
| `bucket`, `path` | `destinationPath` (`s3://pg-backups/prod/my-pg`) |
| `endpoint` | `endpointURL` for `s3`; for `azure` it is *part of* `destinationPath`, because CNPG carries the storage account name in the host; ignored for `gcs` |
| `credentialsSecret.{name,accessKeyIdKey,secretAccessKeyKey}` | `s3Credentials.{accessKeyId,secretAccessKey}`, or `azureCredentials.{storageAccount,storageKey}` |
| `credentialsSecret.applicationCredentialsKey` | `googleCredentials.applicationCredentials` (the service-account JSON) |
| `credentialsSecret.regionKey` | `s3Credentials.region` — a Secret **key reference**, because CNPG accepts the region no other way. There is no literal `region` field for exactly that reason. |
| *(`credentialsSecret` omitted)* | `inheritFromIAMRole` / `gkeEnvironment` / `inheritFromAzureAD` — the pods' own cloud identity, the only shape with no long-lived key in the cluster |
| `snapshotRetentionDays` | `backup.retentionPolicy`, in barman's `<n>[dwm]` spelling (`14` → `"14d"`) |

`snapshotRetentionDays` is the *existing* field — one retention knob for every
backend rather than a second in-cluster one. Its description used to say
backups were ignored in-cluster; that is now true only while `spec.backup` is
unset, and without an object store the Cluster renders exactly as it did
before. One asymmetry worth knowing: `0` disables automatic backups on the
managed backends, but in-cluster it means *keep forever* — barman's
`retentionPolicy` is an expiry rule with no way to spell "never", and the
presence of `spec.backup` is the on/off switch.

A `BackupPlan` and a CNPG cluster are not in conflict. Let CNPG own the
database (base backups + WAL, point-in-time recovery) and let the plan own the
namespace around it (Secrets, ConfigMaps, the `Cluster` object itself, which is
what CNPG needs to bootstrap a recovery in a new cluster).

## What is deliberately absent

| | why |
|---|---|
| **No `Restore` XR** | A restore is a decision about one specific backup at one specific moment — which backup, into which namespace, mapped how. Declaring it in git means a controller that re-runs it, and a restore that reconciles is a restore that overwrites a recovered cluster on the next sync. `velero restore create --from-backup <name>` stays a human command; `Backup` and `Restore` are listed as unused in `packages/providers/crds.yaml` so the decision is on record. |
| **Not one format across clouds** | The cloud backends are the clouds' own services, so their backups are restorable only by that service and only into that cloud's managed clusters. When portability matters — moving between clouds, or between a cloud and a self-hosted cluster — use `velero`, which writes the same format from any cluster to any bucket. |
| **No VM-level snapshots beyond CSI** | A `VirtualMachine`'s disks are PVCs, so CSI snapshots (or file-level backup) already cover them. Hypervisor-level snapshots — KubeVirt `VirtualMachineSnapshot`, EBS snapshots taken outside Velero — are a second, uncoordinated copy of the same bytes with no Backup object to expire them. Add `kubevirt.io` kinds to `includedResources`, not a second snapshot mechanism. |
| **No backup hooks** | Velero's `template.hooks` run `exec` in a container before and after a backup, which is how you quiesce a filesystem. Real, and out of scope for a portable field set: the command is per-application, not per-plan. Patch the composed `Schedule` or open the field when a second consumer needs it. |
| **No Velero dashboard, no `Backup` authoring** | `Backup` objects are what Velero's controller creates from a Schedule; authoring them here would fight the controller. `velero backup get` / `kubectl -n velero get backups` is the read path. |

## Installing it

`providers.yaml` installs the cloud providers (`provider-aws-backup` +
`provider-aws-iam`, `provider-gcp-gke`, `provider-azure-dataprotection` +
`provider-azure-containerservice` + `provider-azure-authorization`) and
provider-helm; install only the ones whose backends you use. The cloud
backends need a `default` ClusterProviderConfig per family with real
credentials, which the module does not ship.

`providerconfigs.yaml` installs the Velero operator as a pinned Helm `Release`
through provider-helm, the same way the CloudNativePG one does:

- **Chart 12.2.0 installs Velero 1.18.2** — the version the schema package
  (`packages/providers/velero`) was generated from, and the `ref` of the
  `velero` row in `packages/providers/registry.yaml`. All three must agree;
  `just seed-backup-providers` regenerates the schemas (the cloud ones too).
- **Plugins v1.14.2** (aws, gcp, azure) as init containers — that is the plugin
  line that pairs with Velero v1.18.x. Without one, a location parses and then
  reaches no bucket. Drop the ones you do not use.
- **`deployNodeAgent: true`** — see [Snapshots, or file-level
  backup](#snapshots-or-file-level-backup).
- **`configuration.backupStorageLocation: []`** — locations are composed per
  plan, so the chart must not own one; two owners of the same name fight.
- **`credentials.useSecret: false`** — credentials are per location, from
  `spec.destination.credentialsSecret`.

## Files

| file | role |
|---|---|
| `packages/cloud/backup/xrd/xrd.yaml` | the `BackupPlan` API: schedule, retention, filters, cluster, destination, and what each backend does with each |
| `packages/cloud/backup/xrd/providers.yaml` | the cloud providers per backend, and the provider-helm that carries the Velero install |
| `packages/cloud/backup/xrd/providerconfigs.yaml` | the pinned Velero chart: plugins, node-agent, no chart-owned locations |
| `packages/cloud/backup/xrd/functions.yaml` | function-kcl + function-auto-ready, pinned |
| `packages/cloud/backup/xrd/examples/backup-velero.yaml` | the worked self-hosted case: local storage, file-level backup, in-cluster RustFS |
| `packages/cloud/backup/xrd/examples/backup-{aws,gcp,azure}.yaml` | one plan per cloud-managed backend |
| `packages/cloud/backup/velero/backup.k` | `render` (three objects) and `status` (the AND of two) |
| `packages/cloud/backup/velero/backup_test.k` | BSL config for a plain bucket, an s3Url endpoint and azure, the required destination, the snapshot-location rule, ttl, pause, template selectors, both-halves readiness |
| `packages/cloud/backup/velero/composition.yaml` | the Composition, selected by `provider: velero` |
| `packages/cloud/backup/{aws,gcp,azure}/` | the cloud backends: `backup.k`, `backup_test.k`, `composition.yaml` (selected by `provider: aws\|gcp\|azure`) and a README with the full field mapping and prerequisites |
| `packages/cloud/postgres/xrd/xrd.yaml` | `spec.backup`, and `snapshotRetentionDays` as CNPG's `retentionPolicy` |
| `packages/cloud/postgres/cnpg/postgres.k` | `destination_path` / `barman_object_store` — the scheme and credential block per provider |
| `packages/cloud/postgres/cnpg/postgres_test.k` | `test_backup_*` — unset renders as before, s3/gcs/azure destinations, ambient identity, retention |
| `packages/providers/velero/`, `aws-backup/`, `gcp-gke/`, `azure-dataprotection/` | generated KCL schemas (`just seed-backup-providers`) |
| `packages/providers/registry.yaml` | the `velero` row (source ref `v1.18.2`, `install: none`) and the cloud provider rows, all with `modules: [backup]` |
| `packages/providers/crds.yaml` | which kinds each backend renders and which are deliberately not |
