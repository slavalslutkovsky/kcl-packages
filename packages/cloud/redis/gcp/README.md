# redis-gcp

GCP backend for the `RedisInstance` XR (`cloud.example.org/v1alpha1`). Typed
against the `gcp-redis` schema package
([`../../../providers/gcp-redis`](../../../providers/gcp-redis)). Memorystore
expresses sizing, replication, auth, encryption, persistence, config overrides
and maintenance inline, so the portable spec maps onto a single `Instance`.
The Composition (`redis-gcp`, label `provider: gcp`) runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/redis-gcp`, followed by
`function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Instance` (`redis.gcp.m.upbound.io`) | always | composition-resource-name `managed`; with `authEnabled`, `writeConnectionSecretToRef: <xr>-redis-auth` publishes the AUTH string |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | `forProvider.region` |
| `engineVersion` (`7.0`) | `redisVersion: REDIS_<v>` (dots become underscores) |
| `memoryGb` (`1`) | `memorySizeGb` verbatim |
| `highAvailability` / `replicas` (`0`) | `tier: STANDARD_HA` when either is set, else `BASIC`. `replicas > 0` sets `replicaCount` and `readReplicasMode: READ_REPLICAS_ENABLED`; otherwise `READ_REPLICAS_DISABLED` |
| `authEnabled` (`true`) | `authEnabled` |
| `transitEncryption` (`true`) | `transitEncryptionMode: SERVER_AUTHENTICATION`, else `DISABLED` |
| `encryptionKmsKeyId` | `customerManagedKey` (Memorystore always encrypts at rest) |
| `persistence` (`true`) | `persistenceConfig.persistenceMode: RDB`, else `DISABLED` |
| `snapshotRetentionDays` (`0`) | with persistence, `rdbSnapshotPeriod`: 0 → `ONE_HOUR`, 1 → `SIX_HOURS`, 2–3 → `TWELVE_HOURS`, more → `TWENTY_FOUR_HOURS` |
| `maintenanceWindow` | `maintenancePolicy.weeklyMaintenanceWindow`: day name and start `hour` |
| `parameters` | `redisConfigs` |
| `tags` | `labels` |
| `network.id` | `authorizedNetwork` |
| `network.reservedIpRange` | `reservedIpRange` |
| `deletionPolicy` | `managementPolicies` (see above) |

Ignored: `nodeType`, `atRestEncryption`, `persistenceSizeGb`,
`network.subnetGroupName`, `network.securityGroupIds`.

Status written back to the XR, from the observed `managed` instance
(`status.atProvider`): `provider: gcp`, `ready` (true once `host` is
reported), `host`, `port`, `endpoint`, `readEndpoint` (`readEndpoint` /
`readEndpointPort`, else the primary), `url` (`rediss://` with transit
encryption, else `redis://`), `version` (`redisVersion`), `id`, `cloud-url`
(Memorystore console link). With `authEnabled`: `authSecret: <xr>-redis-auth`,
`authSecretKey: attribute.auth_string`.

## Usage

```bash
# built-in example XR (`_example` in main.k: region us-central1)
kcl run packages/cloud/redis/gcp

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/redis/gcp \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/redis/xrd/examples/redis-gcp.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status.atProvider` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/redis-gcp.yaml`](../xrd/examples/redis-gcp.yaml)):

```bash
pnpm exec nx run redis-gcp:render     # or: just render redis-gcp
```

On a cluster: `just e2e redis` (Kind cluster, publish, install, every
example), `just install-module redis` (XRD and Compositions only), or
`just workload redis gcp` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `redis.k` | `render`, `status`, version and snapshot-period helpers |
| `redis_test.k` | `kcl test` cases |
| `composition.yaml` | the `redis-gcp` Composition |

## Development

```bash
pnpm exec nx run redis-gcp:test     # kcl test
pnpm exec nx run redis-gcp:lint     # kcl lint
pnpm exec nx run redis-gcp:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
