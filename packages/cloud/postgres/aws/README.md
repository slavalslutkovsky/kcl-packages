# postgres-aws

AWS backend for the `PostgresInstance` XR (`cloud.example.org/v1alpha1`).
Typed against the `aws-rds` schema package
([`../../../providers/aws-rds`](../../../providers/aws-rds)), it maps the
portable spec onto one RDS `Instance`, plus a `ParameterGroup` when Postgres
config overrides are given. The Composition (`postgres-aws`, label
`provider: aws`) runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/postgres-aws`, followed by `function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Instance` (`rds.aws.m.upbound.io`) | always | composition-resource-name `managed`; engine `postgres`, port 5432, `storageEncrypted: true`, `skipFinalSnapshot: true` |
| `ParameterGroup` (`rds.aws.m.upbound.io`) | `spec.parameters` non-empty | named `<xr>-params` through the `crossplane.io/external-name` annotation (RDS parameter groups have no `forProvider.name`); family `postgres<major>`; parameters in sorted key order |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on every composed resource.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | `forProvider.region` |
| `engineVersion` (`16`) | `engineVersion`; a major resolves to the latest minor via RDS auto minor upgrade. Also picks the parameter group family |
| `memoryGb` (`2`) | smallest Graviton class that fits: `db.t4g.micro` (1 GiB) … `db.m7g.8xlarge` (128 GiB); larger requests get the top rung |
| `instanceClass` | `instanceClass` verbatim, overriding `memoryGb` |
| `storageGb` (`20`) | `allocatedStorage` |
| `encryptionKmsKeyId` | `kmsKeyId` (encryption is on regardless) |
| `database` / `username` (`app`) | `dbName` / `username` |
| `passwordSecret` | `passwordSecretRef` read by the provider (key defaults to `password`); unset: `autoGeneratePassword` writes the password to `<xr>-postgres-auth`, key `password` |
| `workloadIdentity` | present and not `enabled: false` → `iamDatabaseAuthenticationEnabled: true`; `principal` is ignored (the `GRANT rds_iam` and `rds-db:connect` policy live outside this XR) |
| `highAvailability` | `multiAz` |
| `publicAccess` | `publiclyAccessible` |
| `snapshotRetentionDays` (`7`) | `backupRetentionPeriod`; `0` disables backups |
| `maintenanceWindow` | two-hour `ddd:hh:00-ddd:hh:00` window starting at `hour` UTC, wrapping to the next day past midnight |
| `network.subnetGroupName` | `dbSubnetGroupName` |
| `network.securityGroupIds` | `vpcSecurityGroupIds` |
| `parameters` | companion `ParameterGroup`, bound by `parameterGroupName` |
| `tags` | `tags` on the instance and the parameter group |
| `deletionPolicy` | `managementPolicies` (see above) |

Ignored: `replicas`, `backup`, `resourceGroup`, `network.id`,
`network.delegatedSubnetId`, `network.privateDnsZoneId`.

Status written back to the XR, from the observed `managed` instance
(`status.atProvider`): `provider: aws`, `ready` (true once `address` is
reported), `host`, `port`, `endpoint`, `readEndpoint` (same as `endpoint`;
single instance), `url` (`postgresql://host:port/database`), `database`,
`username`, `authSecret` / `authSecretKey`, `version`
(`engineVersionActual`, else `engineVersion`), `arn`, `id`, and `cloud-url`
(RDS console link).

## Usage

```bash
# built-in example XR (`_example` in main.k: region us-east-1)
kcl run packages/cloud/postgres/aws

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/postgres/aws \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/postgres/xrd/examples/postgres-aws.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status.atProvider` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/postgres-aws.yaml`](../xrd/examples/postgres-aws.yaml)):

```bash
pnpm exec nx run postgres-aws:render     # or: just render postgres-aws
```

On a cluster: `just e2e postgres` (Kind cluster, publish, install, every
example), `just install-module postgres` (XRD and Compositions only), or
`just workload postgres aws` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `postgres.k` | `render` (Instance, ParameterGroup), `status`, instance-class ladder, window and family helpers |
| `postgres_test.k` | `kcl test` cases |
| `composition.yaml` | the `postgres-aws` Composition |

## Development

```bash
pnpm exec nx run postgres-aws:test     # kcl test
pnpm exec nx run postgres-aws:lint     # kcl lint
pnpm exec nx run postgres-aws:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
