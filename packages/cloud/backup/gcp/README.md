# backup-gcp

Backup for GKE backend for the `BackupPlan` XR (`cloud.example.org/v1alpha1`,
Composition `backup-gcp`, label `provider: gcp`). Typed against the schema
package [`packages/providers/gcp-gke`](../../../providers/gcp-gke). Backup for
GKE is a managed service: the whole plan is one `BackupBackupPlan` bound to a
GKE cluster, Google runs the schedule, and backups land in Google-managed
storage — there is no bucket, vault or in-cluster operator to compose.
`function-kcl` runs it from `oci://docker.io/yurikrupnik/backup-gcp`;
`function-auto-ready` follows.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `BackupBackupPlan` (`managed`, `gke.gcp.m.upbound.io/v1beta1`) | always | `crossplane.io/external-name` pinned to the XR name — the schema has no name field, upjet takes the plan's name from the external name |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation. The MR is namespaced, so the XR may live in any namespace.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `cluster.id` | **required**, `projects/<project>/locations/<location>/clusters/<name>`; `forProvider.cluster` verbatim, `forProvider.project` = `<project>`, `forProvider.location` = the cluster's region (a zonal cluster's `us-central1-a` becomes `us-central1`: Backup for GKE plans live in regions) |
| `schedule` | `backupSchedule.cronSchedule`, interpreted in UTC. `@hourly`, `@daily`/`@midnight`, `@weekly`, `@monthly`, `@yearly`/`@annually` are spelled out as five-field cron, since the API documents only standard cron; anything that is not five fields fails the render |
| `retentionDays` | `retentionPolicy.backupRetainDays` (default 30). Fails the render above 365, or above 360 × the schedule interval for the regular shapes (every N minutes, every N hours, once a day — so `@hourly` allows at most 15 days and the default 30 fails); other shapes are left to the API |
| `includedNamespaces` | `backupConfig.selectedNamespaces.namespaces`; empty means `backupConfig.allNamespaces: true` |
| `excludedResources` | only `secrets` is honoured, as `backupConfig.includeSecrets: false`; otherwise `includeSecrets: true` |
| `snapshotVolumes` | `backupConfig.includeVolumeData` (default true) |
| `encryptionKmsKeyId` | `backupConfig.encryptionKey.gcpKmsEncryptionKey` (encrypts the Kubernetes-object part of each backup) |
| `paused` | `backupSchedule.paused` |
| `tags` | `labels` on the BackupPlan (GCP label rules apply) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |

Ignored, because Backup for GKE cannot express them and backs up a superset:
`includedResources`, `labelSelector`, `excludedResources` other than
`secrets`, `defaultVolumesToFsBackup` (volume data is always snapshotted
through the storage layer), `destination` (backups go to Google-managed
storage) and `cluster.region` / `cluster.snapshotResourceGroup` (Azure only).

Deleting the XR with `deletionPolicy: Delete` does not take the backups with
it: GCP refuses to delete a plan that still holds backups, so the MR stays
stuck until they expire or are deleted.

Status written back to the XR:

| field | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | the plan's `Ready` condition is `True` **and** its reported `state` is `READY`. upjet marks the MR Ready as soon as the plan exists, but a plan on a cluster without the backup agent sits in `CLUSTER_PENDING` taking no backups |
| `storageLocation` | the plan's full name `projects/<p>/locations/<region>/backupPlans/<name>` — derived from the XR before creation, the observed `atProvider.id` after |
| `phase` | `atProvider.state` (`CLUSTER_PENDING`, `PROVISIONING`, `READY`, `FAILED`, `DEACTIVATED`, `DELETING`), once reported |
| `message` | when not ready: `BackupBackupPlan managed: ` + the Ready condition's message, or the state plus `atProvider.stateReason` |

## Prerequisites

Outside the XR, on the GCP side and in the control plane:

- The Backup for GKE API, `gkebackup.googleapis.com`, enabled in the cluster's project.
- The cluster's Backup for GKE agent add-on enabled
  (`addonsConfig.gkeBackupAgentConfig.enabled: true`; `gcloud container
  clusters update <name> --update-addons=BackupRestore=ENABLED`).
  [`packages/cloud/cluster/gcp`](../../cluster/gcp) does **not** set it, so a
  cluster created by a `KubernetesCluster` XR needs it turned on separately;
  until then the plan reports `CLUSTER_PENDING` and the XR is not ready.
- `provider-gcp-gke` ([`../xrd/providers.yaml`](../xrd/providers.yaml)) installed, and the `gcp.m.upbound.io`
  `ClusterProviderConfig` named `default` (the MR leaves `providerConfigRef`
  at its default) carrying an identity that can manage Backup for GKE plans
  (`roles/gkebackup.admin` or equivalent) in the cluster's project.
- With `encryptionKmsKeyId`: the key in the plan's region, and the Backup for
  GKE service agent (`service-<project-number>@gcp-sa-gkebackup.iam.gserviceaccount.com`)
  granted `roles/cloudkms.cryptoKeyEncrypterDecrypter` on it.

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (namespace `default`, nightly at
02:00 UTC, cluster `projects/example-project/locations/us-central1/clusters/example`).
Pass a real XR as `params.oxr`:

```bash
# built-in example: the BackupBackupPlan + status
kcl run packages/cloud/backup/gcp

# the shipped example (selected namespaces, no Secrets, CMEK, Orphan)
kcl run packages/cloud/backup/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/backup/xrd/examples/backup-gcp.yaml)}"
```

Restores are not part of the plan: run `gcloud beta container backup-restore
restores create` against a specific backup.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` + `status` |
| `backup.k` | `render(oxr)`, `status(oxr, ocds)`, `cron_for`, `parse_cluster_id`, `region_for`, `interval_minutes`, `max_retain_days` |
| `backup_test.k` | `kcl test` cases: shape, cluster id parsing (zonal → regional), required cluster, cron shorthands, pause, retention caps, namespaces, Secrets exclusion, volumes, CMEK, labels, Orphan, ignored fields, status |
| `composition.yaml` | Composition `backup-gcp` (function-kcl → function-auto-ready) |

## Development

```bash
pnpm exec nx run backup-gcp:test     # kcl test
pnpm exec nx run backup-gcp:lint     # kcl lint
pnpm exec nx run backup-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
