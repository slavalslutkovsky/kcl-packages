# queue-xrd

The `Queue` XRD — `queues.cloud.example.org`, group `cloud.example.org`,
version `v1alpha1`, `Namespaced` — a portable point-to-point work queue
(producers enqueue, one consumer receives each message, unacknowledged
deliveries are retried), plus the KCL schemas generated from it under
`models/`. Composites of composites import those schemas by path to build
typed child XRs; [../../../platform/inbox/composite](../../../platform/inbox/composite)
does:

```kcl
import queue_xrd.models.v1alpha1.cloud_example_org_v1alpha1_queue as queue
```

`models/` comes from `just xrd-schema queue` (`kcl import -m crd` over
`xrd.yaml`, with `spec.crossplane` composition selection added). It is not
hand-edited; regenerate after every change to `xrd.yaml`.

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `region` | string | ✓ | | SQS region / implicit Pub/Sub storage; ignored in-cluster |
| `fifo` | boolean | | `false` | strict ordering: SQS FIFO queue, Pub/Sub message ordering; ignored in-cluster |
| `visibilityTimeoutSeconds` | integer 0–43200 | | `30` | how long a delivered message stays invisible before retry |
| `retentionDays` | integer 1–14 | | `4` | how long an unconsumed message survives |
| `deadLetter` | object | | | `enabled` (default `false`) and `maxReceives` (1–100, default `5`): move repeatedly failed messages aside |
| `encryptionKmsKeyId` | string | | | CMEK for at-rest encryption; ignored in-cluster |
| `persistence` | boolean | | `true` | in-cluster only: JetStream file vs memory storage |
| `persistenceSizeGb` | integer ≥ 1 | | `1` | in-cluster only: stream `maxBytes` |
| `replicas` | integer `1`/`3`/`5` | | `1` | in-cluster only: stream replica count |
| `deletionPolicy` | `Delete` / `Orphan` | | `Delete` | maps to Crossplane `managementPolicies`; `Orphan` keeps the backing resources |
| `tags` | map of string | | | AWS tags / GCP labels; ignored in-cluster |

Status: `ready`, `provider`, `url`, `queueName`, `topic`, `deadLetterUrl`,
`arn`, `id`, `cloud-url`. Printer columns: `READY`, `PROVIDER`, `QUEUE`.

## Backends

| dir | Composition | selector label |
| --- | --- | --- |
| [../aws/](../aws/) | `queue-aws` | `provider: aws` |

The XRD description and the examples also cover a GCP (Pub/Sub) and an
in-cluster NATS JetStream backend, but this module ships no Composition for
either, so `queue-gcp.yaml` and `queue-nats.yaml` select nothing.

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | the `CompositeResourceDefinition` |
| `providers.yaml` | `provider-aws-sqs`, `provider-gcp-pubsub`, and `provider-helm` with its ServiceAccount, `cluster-admin` binding and `DeploymentRuntimeConfig` |
| `providerconfigs.yaml` | helm `ClusterProviderConfig/default` (`InjectedIdentity`) and the pinned `nats` and `nack` Helm Releases into `nats-system`; apply after the providers are Healthy. No AWS/GCP ProviderConfig: add one with real credentials |
| `functions.yaml` | `function-kcl` and `function-auto-ready`, pinned from ghcr.io |
| `examples/queue-aws.yaml` | `orders`: dead letter on, 60 s visibility, 7-day retention, `provider: aws` |
| `examples/queue-gcp.yaml` | `orders` in `europe-west1`, dead letter on, `provider: gcp` |
| `examples/queue-nats.yaml` | `orders` with `region: in-cluster`, file storage, 2 GB cap, `provider: nats` |

## Usage

```bash
just e2e queue                    # Kind + Crossplane + local registry, publish, install, providers, examples
just install-module queue         # XRD + Compositions only, repointed at the local registry
kubectl apply -f packages/cloud/queue/xrd/examples/queue-aws.yaml
```

## Layout

| file | content |
| --- | --- |
| `main.k` | package entrypoint; points at `models/` |
| `models/` | generated schemas: `v1alpha1/cloud_example_org_v1alpha1_queue.k` and the `k8s` ObjectMeta it uses |
| `xrd_test.k` | `kcl test` cases: the shipped examples validate against the generated schema, schema defaults match the XRD |

## Development

```bash
pnpm exec nx run queue-xrd:test     # kcl test
pnpm exec nx run queue-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
