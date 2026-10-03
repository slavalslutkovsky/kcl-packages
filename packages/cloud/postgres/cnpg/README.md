# postgres-cnpg

In-cluster backend for the `PostgresInstance` XR (`cloud.example.org/v1alpha1`):
no cloud account, no VPC. Typed against the `cnpg` schema package
([`../../../providers/cnpg`](../../../providers/cnpg)), it renders one
CloudNativePG `Cluster` directly, with no provider MR wrapper, no
`providerConfigRef` and no `managementPolicies`. The Composition
(`postgres-cnpg`, label `provider: cnpg`) runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/postgres-cnpg`, followed by `function-auto-ready`.
The CloudNativePG operator is a cluster prerequisite, installed as a Helm
`Release` by [`../xrd/providerconfigs.yaml`](../xrd/providerconfigs.yaml).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Cluster` (`postgresql.cnpg.io/v1`) | always | composition-resource-name `managed`; named after the XR, placed in the XR's namespace, so the `<xr>-rw` / `<xr>-ro` Services are deterministic |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `engineVersion` (`16`) | `imageName: ghcr.io/cloudnative-pg/postgresql:<engineVersion>`; a major tag tracks the latest published minor |
| `replicas` (`0`) | `instances = replicas + 1` |
| `highAvailability` | at least one standby (`instances >= 2`) even at `replicas: 0` |
| `memoryGb` (`2`) | memory request and limit, `<n>Gi` |
| `storageGb` (`20`) | `storage.size`, `<n>Gi` |
| `database` / `username` (`app`) | `bootstrap.initdb.database` / `owner` |
| `passwordSecret.name` | `bootstrap.initdb.secret.name`; the whole `kubernetes.io/basic-auth` Secret is used, so `passwordSecret.key` is ignored |
| `parameters` | `postgresql.parameters`, verbatim |
| `tags` | `inheritedMetadata.labels` |
| `backup` | `backup.barmanObjectStore`; absent means no object store and no WAL archive |
| `snapshotRetentionDays` (`7`) | `backup.retentionPolicy: <n>d`, only with `backup`; `0` emits no rule (keep forever) |

`backup` in detail:

| field | effect |
| --- | --- |
| `provider` (`s3`) | `s3` → `s3://<bucket>` + `s3Credentials`; `gcs` → `gs://<bucket>` + `googleCredentials`; `azure` → `<endpoint>/<bucket>` + `azureCredentials` |
| `bucket` | first path component of `destinationPath`; the bucket must already exist |
| `path` | appended to `destinationPath` |
| `endpoint` | s3: `endpointURL` (e.g. an in-cluster RustFS/MinIO). azure: **required**, it is the start of the destination (the render asserts). gcs: unused |
| `credentialsSecret` | Secret keys `accessKeyIdKey` (`ACCESS_KEY_ID`), `secretAccessKeyKey` (`ACCESS_SECRET_KEY`), `applicationCredentialsKey` (`gcsCredentials`, gcs only), `regionKey` (s3 only, opt-in). Unset: ambient identity (`inheritFromIAMRole`, `gkeEnvironment`, `inheritFromAzureAD`) |

Ignored: `region`, `instanceClass`, `publicAccess`, `maintenanceWindow`,
`network`, `resourceGroup`, `encryptionKmsKeyId`, `workloadIdentity` (no cloud
IAM in-cluster) and `deletionPolicy` (the Cluster's lifetime follows the XR).

Status written back to the XR. Endpoints are derived from the Cluster name and
reported as soon as it exists: `host` `<xr>-rw.<ns>.svc.cluster.local`,
`port` 5432, `endpoint`, `readEndpoint` (`<xr>-ro…` when there is at least one
standby, else the primary), `url`, `database`, `username`, `authSecret`
(`passwordSecret.name`, else the operator-generated `<xr>-app`) with
`authSecretKey: password`, `cloud-url` (`kubernetes://<ns>/cluster.postgresql.cnpg.io/<xr>`)
and `provider: cnpg`. From the observed Cluster status: `ready`
(`readyInstances >= 1`), `version` (the image tag) and `id` (`systemID`).

## Usage

```bash
# built-in example XR (`_example` in main.k: example in namespace default)
kcl run packages/cloud/postgres/cnpg

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/postgres/cnpg \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/postgres/xrd/examples/postgres-cnpg.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/postgres-cnpg.yaml`](../xrd/examples/postgres-cnpg.yaml)):

```bash
pnpm exec nx run postgres-cnpg:render     # or: just render postgres-cnpg
```

On a cluster: `just e2e postgres` (Kind cluster, publish, install, every
example), `just install-module postgres` (XRD and Compositions only), or
`just workload postgres cnpg` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `postgres.k` | `render`, `status`, Service-name and barman object-store helpers |
| `postgres_test.k` | `kcl test` cases |
| `composition.yaml` | the `postgres-cnpg` Composition |

## Development

```bash
pnpm exec nx run postgres-cnpg:test     # kcl test
pnpm exec nx run postgres-cnpg:lint     # kcl lint
pnpm exec nx run postgres-cnpg:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
