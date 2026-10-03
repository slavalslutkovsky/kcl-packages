# inbox

The only backend for the `Inbox` XR (`platform.example.org/v1alpha1`,
Composition `inbox`): a drop zone with a work queue behind it. A composite of
composites — it emits two child XRs in `cloud.example.org/v1alpha1`, a
`Bucket` where payloads land and a `Queue` carrying one work item per payload,
both on the same backend and region. The children are typed against the
[bucket-xrd](../../../cloud/bucket/xrd/) and
[queue-xrd](../../../cloud/queue/xrd/) schema packages, so a field or value
the child XRD does not accept is a render error here, and each child carries
its XRD defaults explicitly. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/inbox`.

## Composed resources

| resource (API group) | composition-resource-name | name | notes |
| --- | --- | --- | --- |
| `Bucket` (`cloud.example.org`) | `bucket` | `<name>-bucket` | always; versioning off and `forceDestroy` off unless set |
| `Queue` (`cloud.example.org`) | `queue` | `<name>-queue` | always; dead-lettering on (`maxReceives` 5) unless set |

Both children get `region`, `deletionPolicy` (default `Delete`),
`encryptionKmsKeyId` and `tags` from the Inbox, and
`crossplane.compositionSelector.matchLabels.provider: <spec.provider>`. No
cross-child wiring: no storage-event notification is modelled, so the
producer that uploads a payload also enqueues its key.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `provider` | `aws` or `gcp`; both children's composition selector |
| `region`, `deletionPolicy`, `encryptionKmsKeyId`, `tags` | copied onto both children |
| `bucket.storageClass` | Bucket `storageClass`, default `standard` |
| `bucket.versioning` | Bucket `versioning`, default `false` (the Bucket's own default is on) |
| `bucket.forceDestroy` | Bucket `forceDestroy`, default `false` |
| `bucket.expirationDays` | Bucket `lifecycleRules` `[{id: expire-payloads, prefix: "", expirationDays}]` |
| `queue.fifo` | Queue `fifo`, default `false` |
| `queue.visibilityTimeoutSeconds` | Queue `visibilityTimeoutSeconds`, default 30 |
| `queue.retentionDays` | Queue `retentionDays`, default 4 |
| `queue.deadLetter.{enabled,maxReceives}` | Queue `deadLetter`, defaults `true`, 5 (the bare Queue's default is off) |

Status written back: `provider`, `ready` (both children ready),
`components.{bucket,queue}`, and, once published, `bucketName`, `bucketUrl`,
`queueName`, `queueUrl`, `topic`, `deadLetterUrl` — copied from the children.

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` (aws, `us-east-1`):

```bash
kcl run packages/platform/inbox/composite
```

Pass a real XR the way function-kcl does:

```bash
kcl run packages/platform/inbox/composite \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/inbox/xrd/examples/inbox-gcp.yaml)}"
```

`pnpm exec nx run inbox:render` (or `just render inbox`) renders
`composition.yaml` through function-kcl against the first `inbox-*.yaml`
example; `--example inbox-gcp` picks the other. Needs docker.

In a cluster (needs docker/kind): `just e2e inbox` publishes the package,
installs the XRD and Composition and applies the examples;
`just install-module inbox` applies only the XRD and the Composition,
repointed at the local registry. The module ships no providers: the children
only resolve once the `bucket` and `queue` modules are installed.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `inbox.k` | `render` (typed Bucket + Queue) and `status` |
| `inbox_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run inbox:test     # kcl test
pnpm exec nx run inbox:lint     # kcl lint
pnpm exec nx run inbox:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
