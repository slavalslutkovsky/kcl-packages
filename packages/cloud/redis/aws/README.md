# redis-aws

AWS backend for the `RedisInstance` XR (`cloud.example.org/v1alpha1`). Typed
against the `aws-elasticache` schema package
([`../../../providers/aws-elasticache`](../../../providers/aws-elasticache)),
it maps the portable spec onto one cluster-mode-disabled ElastiCache
`ReplicationGroup`, plus a `ParameterGroup` when Redis config overrides are
given. The Composition (`redis-aws`, label `provider: aws`) runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/redis-aws`, followed by
`function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `ReplicationGroup` (`elasticache.aws.m.upbound.io`) | always | composition-resource-name `managed`; engine `redis`, port 6379 |
| `ParameterGroup` (`elasticache.aws.m.upbound.io`) | `spec.parameters` non-empty | `parameters`; `forProvider.name: <xr>-params`, bound by name; family `redis6.x` for 6, `redis<major>` otherwise |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on every composed resource.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | `forProvider.region` |
| `engineVersion` (`7.0`) | `engineVersion`; also picks the parameter group family |
| `memoryGb` (`1`) | smallest Graviton node that fits: `cache.t4g.micro` (0.5 GiB) … `cache.m7g.8xlarge` (103.68 GiB); larger requests get the top rung |
| `nodeType` | `nodeType` verbatim, overriding `memoryGb` |
| `replicas` (`0`) | `numCacheClusters = replicas + 1` |
| `highAvailability` | `automaticFailoverEnabled` and `multiAzEnabled`; forces `numCacheClusters >= 2` |
| `authEnabled` (`true`) | with `transitEncryption`: `autoGenerateAuthToken`, written to Secret `<xr>-redis-auth`, key `password`. Without transit encryption no token is rendered |
| `transitEncryption` (`true`) | `transitEncryptionEnabled` |
| `atRestEncryption` (`true`) | `atRestEncryptionEnabled` (`"true"` / `"false"` string); forced on by `encryptionKmsKeyId` |
| `encryptionKmsKeyId` | `kmsKeyId` |
| `persistence` (`true`) | keeps `snapshotRetentionLimit >= 1` |
| `snapshotRetentionDays` (`0`) | `snapshotRetentionLimit` |
| `maintenanceWindow` | two-hour `ddd:hh:00-ddd:hh:00` window starting at `hour` UTC, wrapping to the next day past midnight |
| `network.subnetGroupName` | `subnetGroupName` |
| `network.securityGroupIds` | `securityGroupIds` |
| `parameters` | companion `ParameterGroup`, bound by `parameterGroupName` |
| `tags` | `tags` on both resources |
| `deletionPolicy` | `managementPolicies` (see above) |

Ignored: `persistenceSizeGb`, `network.id`, `network.reservedIpRange`.

Status written back to the XR, from the observed `managed` group
(`status.atProvider`): `provider: aws`, `ready` (true once an endpoint is
reported), `host` (`primaryEndpointAddress`, else
`configurationEndpointAddress`), `port`, `endpoint`, `readEndpoint`
(`readerEndpointAddress`, else the primary), `url` (`rediss://` with transit
encryption, else `redis://`), `version` (`engineVersionActual`, else
`engineVersion`), `arn`, `id`, `cloud-url` (ElastiCache console link).
`authSecret` / `authSecretKey` are set only when both `authEnabled` and
`transitEncryption` are.

## Usage

```bash
# built-in example XR (`_example` in main.k: region us-east-1)
kcl run packages/cloud/redis/aws

# a real XR, wrapped the way function-kcl passes it (`oxr`; `ocds` optional)
kcl run packages/cloud/redis/aws \
    -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/redis/xrd/examples/redis-aws.yaml)}"
```

`ocds` takes observed composed resources keyed by composition-resource-name;
`ocds.managed.Resource.status.atProvider` is what the status block reads.

Against the Crossplane function, from the working tree (needs docker and the
`crossplane` CLI; renders
[`../xrd/examples/redis-aws.yaml`](../xrd/examples/redis-aws.yaml)):

```bash
pnpm exec nx run redis-aws:render     # or: just render redis-aws
```

On a cluster: `just e2e redis` (Kind cluster, publish, install, every
example), `just install-module redis` (XRD and Compositions only), or
`just workload redis aws` on a running platform.

## Layout

| file | content |
| --- | --- |
| `main.k` | entry point: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `redis.k` | `render` (ReplicationGroup, ParameterGroup), `status`, node-type ladder, window and family helpers |
| `redis_test.k` | `kcl test` cases |
| `composition.yaml` | the `redis-aws` Composition |

## Development

```bash
pnpm exec nx run redis-aws:test     # kcl test
pnpm exec nx run redis-aws:lint     # kcl lint
pnpm exec nx run redis-aws:render   # crossplane render (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
