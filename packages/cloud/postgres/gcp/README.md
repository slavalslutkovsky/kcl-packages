# postgres-gcp

GCP backend for the `PostgresInstance` XR (`cloud.example.org/v1alpha1`).
Typed against the `gcp-sql` schema package
([`../../../providers/gcp-sql`](../../../providers/gcp-sql)), it splits the
portable spec across Cloud SQL resources: a `DatabaseInstance` for sizing, HA,
backups, networking and flags, a companion `Database`, an owner `User` when a
password Secret is given, and an IAM `User` for workload identity. The
Composition (`postgres-gcp`, label `provider: gcp`) runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/postgres-gcp`, followed by
`function-auto-ready`.

## Composed resources

All in `sql.gcp.m.upbound.io`.

| resource | when | notes |
| --- | --- | --- |
| `DatabaseInstance` | always | composition-resource-name `managed`; `deletionProtection: false`, so `deletionPolicy` is the only lifecycle knob |
| `Database` | always | `database`; external name is the database name |
| `User` | `spec.passwordSecret` set | `user`; external name is `username`; password from the Secret. Cloud SQL cannot generate one, so without a Secret no owner user is created |
| `User` | `workloadIdentity` present, not `enabled: false`, with `principal` | `iam-user`; a service-account email becomes `CLOUD_IAM_SERVICE_ACCOUNT` named without `.gserviceaccount.com`, anything else `CLOUD_IAM_USER` |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on every composed resource.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | `forProvider.region` |
| `engineVersion` (`16`) | `databaseVersion: POSTGRES_<v>` (dots become underscores) |
| `memoryGb` (`2`) | `settings.tier`: smallest N1-shaped `db-custom` tier that fits, `db-custom-1-3840` (3.75 GiB) … `db-custom-16-61440` (60 GiB) |
| `instanceClass` | `settings.tier` verbatim, overriding `memoryGb` |
| `storageGb` (`20`) | `settings.diskSize` |
| `encryptionKmsKeyId` | `encryptionKeyName` |
| `database` / `username` (`app`) | the `Database` and owner `User` external names |
| `passwordSecret` | owner `User.passwordSecretRef` (key defaults to `password`) |
| `workloadIdentity` | database flag `cloudsql.iam_authentication: on` plus the IAM `User`; an explicit `parameters` entry for that flag wins |
| `highAvailability` | `availabilityType: REGIONAL`, else `ZONAL` |
| `publicAccess` / `network.id` | `ipv4Enabled` is `publicAccess` or no `network.id` (Cloud SQL needs one interface); `network.id` → `privateNetwork` |
| `snapshotRetentionDays` (`7`) | `backupConfiguration.enabled` when > 0, with `retainedBackups` (unit `COUNT`); `0` disables backups |
| `maintenanceWindow` | `day` (mon = 1 .. sun = 7), `hour` |
| `parameters` | `databaseFlags`, sorted by name |
| `tags` | `settings.userLabels` |
| `deletionPolicy` | `managementPolicies` (see above) |

Ignored: `replicas`, `backup`, `resourceGroup`, `network.subnetGroupName`,
`network.securityGroupIds`, `network.delegatedSubnetId`,
`network.privateDnsZoneId`, and the Azure-only `workloadIdentity` fields.

Status written back to the XR, from the observed `managed` instance
(`status.atProvider`): `provider: gcp`, `ready` (true once an address is
reported), `host` (`privateIpAddress`, else `publicIpAddress`, else
`firstIpAddress`), `port` (5432), `endpoint`, `readEndpoint` (same as
`endpoint`), `url`, `database`, `username`, `version` (`databaseVersion`),
`id`, `cloud-url` (Cloud SQL console link). `authSecret` / `authSecretKey`
are set only when `passwordSecret` is.

## Usage

```bash
# built-in example XR (`_example` in main.k: region us-central1)
kcl run packages/cloud/postgres/gcp

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/postgres/gcp \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/postgres/xrd/examples/postgres-gcp.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status.atProvider` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/postgres-gcp.yaml`](../xrd/examples/postgres-gcp.yaml)):

```bash
pnpm exec nx run postgres-gcp:render     # or: just render postgres-gcp
```

On a cluster: `just e2e postgres` (Kind cluster, publish, install, every
example), `just install-module postgres` (XRD and Compositions only), or
`just workload postgres gcp` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `postgres.k` | `render`, `status`, tier ladder, version, IAM-user and flag-merge helpers |
| `postgres_test.k` | `kcl test` cases |
| `composition.yaml` | the `postgres-gcp` Composition |

## Development

```bash
pnpm exec nx run postgres-gcp:test     # kcl test
pnpm exec nx run postgres-gcp:lint     # kcl lint
pnpm exec nx run postgres-gcp:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
