# postgres-azure

Azure backend for the `PostgresInstance` XR (`cloud.example.org/v1alpha1`).
Typed against the `azure-dbforpostgresql` schema package
([`../../../providers/azure-dbforpostgresql`](../../../providers/azure-dbforpostgresql)),
it maps the portable spec onto a Flexible Server, a companion database, one
configuration resource per Postgres parameter override, and, with workload
identity, an Entra ID administrator. The Composition (`postgres-azure`, label
`provider: azure`) runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/postgres-azure`, followed by `function-auto-ready`.

## Composed resources

All in `dbforpostgresql.azure.m.upbound.io`.

| resource | when | notes |
| --- | --- | --- |
| `FlexibleServer` | always | composition-resource-name `managed` |
| `FlexibleServerDatabase` | always | `database`; external name is the database name; bound to the server by controller reference |
| `FlexibleServerActiveDirectoryAdministrator` | `workloadIdentity` present and not `enabled: false` | `entra-admin`; admits the workload principal as the server's Entra administrator (full admin; Azure has no lesser declarative IAM principal) |
| `FlexibleServerConfiguration` | one per `spec.parameters` entry | `param-<key>`, in sorted key order |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on every composed resource.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `resourceGroup` | `resourceGroupName`. **Required**: the render fails with `the azure backend requires spec.resourceGroup` without it |
| `region` | `location` |
| `engineVersion` (`16`) | `version` (majors only) |
| `memoryGb` (`2`) | smallest SKU that fits: `B_Standard_B1ms` (2 GiB) … `GP_Standard_D16s_v3` (64 GiB). With `highAvailability`, a Burstable pick is bumped to `GP_Standard_D2s_v3` (zone-redundant HA is unsupported on `B_`) |
| `instanceClass` | `skuName` verbatim, overriding `memoryGb` |
| `storageGb` (`20`) | `storageMb`, rounded up to Azure's steps (32, 64, … 16384, 32767 GiB) |
| `database` (`app`) | the `FlexibleServerDatabase` |
| `username` (`app`) | `administratorLogin` |
| `passwordSecret` | `administratorPasswordSecretRef` (key defaults to `password`); unset: `autoGeneratePassword` writes it to `<xr>-postgres-auth`, key `password` |
| `workloadIdentity` | `authentication` with `activeDirectoryAuthEnabled` and `passwordAuthEnabled` both on, plus the Entra administrator. `principal`, `principalId` and `tenantId` are all required (the render asserts); `principalType` defaults to `ServicePrincipal` |
| `highAvailability` | `highAvailability.mode: ZoneRedundant` |
| `publicAccess` | `publicNetworkAccessEnabled` |
| `network.delegatedSubnetId` / `network.privateDnsZoneId` | `delegatedSubnetId` / `privateDnsZoneId` |
| `snapshotRetentionDays` (`7`) | `backupRetentionDays`, clamped to 7..35 (Azure cannot disable backups) |
| `maintenanceWindow` | `dayOfWeek` (sun = 0 .. sat = 6), `startHour`, `startMinute: 0` |
| `parameters` | one `FlexibleServerConfiguration` per entry |
| `tags` | server `tags` |
| `deletionPolicy` | `managementPolicies` (see above) |

Ignored: `encryptionKmsKeyId` (a customer-managed key needs a user-assigned
identity with key vault access), `replicas`, `backup`, `network.id`,
`network.subnetGroupName`, `network.securityGroupIds`.

Status written back to the XR, from the observed `managed` server
(`status.atProvider`): `provider: azure`, `ready` (true once `fqdn` is
reported), `host`, `port` (5432), `endpoint`, `readEndpoint` (same as
`endpoint`), `url`, `database`, `username`, `authSecret` / `authSecretKey`,
`version`, `id`, and `cloud-url` (Azure portal link built from the ARM id).

## Usage

```bash
# built-in example XR (`_example` in main.k: westeurope, resource group example-rg)
kcl run packages/cloud/postgres/azure

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/postgres/azure \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/postgres/xrd/examples/postgres-azure.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status.atProvider` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/postgres-azure.yaml`](../xrd/examples/postgres-azure.yaml)):

```bash
pnpm exec nx run postgres-azure:render     # or: just render postgres-azure
```

On a cluster: `just e2e postgres` (Kind cluster, publish, install, every
example), `just install-module postgres` (XRD and Compositions only), or
`just workload postgres azure` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `postgres.k` | `render`, `status`, SKU ladder and storage-step helpers |
| `postgres_test.k` | `kcl test` cases |
| `composition.yaml` | the `postgres-azure` Composition |

## Development

```bash
pnpm exec nx run postgres-azure:test     # kcl test
pnpm exec nx run postgres-azure:lint     # kcl lint
pnpm exec nx run postgres-azure:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
