# queue-aws

AWS backend for the `Queue` XR (`cloud.example.org/v1alpha1`): an SQS queue,
plus a companion dead-letter queue wired through the inline
`forProvider.redrivePolicy` when `deadLetter.enabled` is set. Typed against the
vendored `aws-sqs` schema package
([../../../providers/aws-sqs](../../../providers/aws-sqs)). The `queue-aws`
Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/queue-aws`, followed by `function-auto-ready`.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `Queue` (`sqs.aws.m.upbound.io`) | always | composition-resource-name `managed`; `forProvider.name` = XR name, `<xr>.fifo` when `fifo` |
| `Queue` (`sqs.aws.m.upbound.io`) | `deadLetter.enabled` | composition-resource-name `dlq`; name `<xr>-dlq` (`<xr>-dlq.fifo` when `fifo`); retention fixed at the SQS maximum of 14 days |

The redrive policy embeds the DLQ's ARN, which exists only after AWS creates
the DLQ. So `render` also reads observed state: the first reconcile renders
both queues without a policy; once the `dlq` resource reports
`atProvider.arn`, the main queue gets
`{"deadLetterTargetArn":"<arn>","maxReceiveCount":<n>}`.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on both queues |
| `fifo` | `fifoQueue: true`, `contentBasedDeduplication: true` and the `.fifo` suffix on both queues; omitted when `false` |
| `visibilityTimeoutSeconds` | main queue `visibilityTimeoutSeconds`, default `30` (an explicit `0` is kept) |
| `retentionDays` | main queue `messageRetentionSeconds` = days × 86400, default 4 days |
| `deadLetter.enabled` | adds the DLQ and the redrive policy |
| `deadLetter.maxReceives` | `maxReceiveCount`, default `5`, clamped to 1–100 |
| `encryptionKmsKeyId` | `kmsMasterKeyId` on both queues |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on both queues; otherwise the schema default `['*']` |
| `tags` | `forProvider.tags` on both queues |
| `persistence`, `persistenceSizeGb`, `replicas` | ignored (in-cluster only) |

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once the main queue reports a URL |
| `queueName` / `topic` | the queue name (with `.fifo`); SQS has no separate topic, so both are the same, known before creation |
| `url`, `id` | observed `atProvider.url`, else `atProvider.id` |
| `cloud-url` | SQS console link, once the URL is known |
| `arn` | observed main queue ARN |
| `deadLetterUrl` | observed DLQ URL |

## Usage

Without `option("params")`, `main.k` renders a built-in example XR (`us-east-1`,
defaults only):

```bash
kcl run packages/cloud/queue/aws
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`):

```bash
kcl run packages/cloud/queue/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/queue/xrd/examples/queue-aws.yaml)"
```

Adding an observed DLQ to `ocds` shows the second reconcile, with the redrive
policy on the main queue and `status.deadLetterUrl` set:

```bash
kcl run packages/cloud/queue/aws \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"dlq": {"Resource": {"status": {"atProvider": {"arn": "arn:aws:sqs:us-east-1:123456789012:orders-dlq", "url": "https://sqs.us-east-1.amazonaws.com/123456789012/orders-dlq"}}}}}}' packages/cloud/queue/xrd/examples/queue-aws.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/queue-aws.yaml](../xrd/examples/queue-aws.yaml)):

```bash
pnpm exec nx run queue-aws:render
```

On a cluster: `just e2e queue`, or `just install-module queue` for the XRD and
Composition alone. The SQS MRs need a real AWS ProviderConfig of your own (see
[../xrd/providerconfigs.yaml](../xrd/providerconfigs.yaml)).

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render(oxr, ocds)` + `status` |
| `queue.k` | `receives_for` clamp, `render`, `status` |
| `queue_test.k` | `kcl test` cases: shape, FIFO naming, defaults/overrides, KMS, dead letter and redrive handshake, deletion policy, tags, status |
| `composition.yaml` | `queue-aws` Composition (`provider: aws` label) |

## Development

```bash
pnpm exec nx run queue-aws:test     # kcl test
pnpm exec nx run queue-aws:lint     # kcl lint
pnpm exec nx run queue-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
