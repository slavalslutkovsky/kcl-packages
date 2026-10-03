# bucket-xrd

The `Bucket` XRD — `buckets.cloud.example.org`, group `cloud.example.org`,
version `v1alpha1`, `Namespaced` — a portable object-storage bucket whose
fields each backend maps onto its cloud's native resources. The package also
carries the KCL schemas generated from [`xrd.yaml`](xrd.yaml) under
`models/` (`just xrd-schema bucket`, i.e. `kcl import -m crd`); `models/` is
not hand-edited — regenerate after every change to `xrd.yaml`. Consumers
import the composite type as:

```
import bucket_xrd.models.v1alpha1.cloud_example_org_v1alpha1_bucket as bucket
```

[`../import`](../import) does, so the XRs it writes are validated against
this schema before they reach the API server.

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `region` | string | ✓ | | GCS location / S3 region |
| `storageClass` | `standard` \| `nearline` \| `cold` \| `archive` | | `standard` | Abstract tier, mapped per cloud |
| `versioning` | bool | | `true` | Keep noncurrent object versions |
| `forceDestroy` | bool | | `false` | Delete contained objects when the bucket is destroyed |
| `deletionPolicy` | `Delete` \| `Orphan` | | `Delete` | `Orphan` keeps the cloud bucket when the XR is deleted (via `managementPolicies`) |
| `blockPublicAccess` | bool | | `true` | Block all public access |
| `uniformAccess` | bool | | `true` | Disable per-object ACLs, enforce bucket-level IAM |
| `encryptionKmsKeyId` | string | | | CMEK / SSE-KMS key; unset means provider-default encryption |
| `requesterPays` | bool | | `false` | Charge requesters for access |
| `retention` | object | | | WORM retention: `days` (required, ≥ 1), `mode` `governance` (default) \| `compliance` |
| `tags` | map of string | | | Labels / tags on the bucket |
| `logging` | object | | | Access logs: `targetBucket` (required), `targetPrefix` |
| `website` | object | | | Static hosting: `indexDocument` (default `index.html`), `errorDocument` |
| `cors` | list | | | Rules: `origins`, `methods` (required), `headers`, `maxAgeSeconds` (default 3600) |
| `lifecycleRules` | list | | | Rules: `id` (required), `prefix` (default `""`), `expirationDays`, `transitionDays`, `transitionStorageClass` |
| `import` | object | | | Adopt an existing bucket: `existingName` (required), `mode` `observe` (default) \| `manage`, `source` `terraform` \| `pulumi` \| `other`, `address`, `resourceGroup` (Azure only). See [docs/bucket-import.md](../../../../docs/bucket-import.md) |

Status fields: `ready`, `provider`, `mode` (`created` \| `observe` \|
`managed`), `bucketName`, `region`, `storageClass`, `url`, `cloud-url`,
`endpoint`, `arn` (AWS), `selfLink` (GCP), `id`. Printer columns: `READY`,
`PROVIDER`, `MODE`, `URL`, `CLOUD-URL`. Not every backend writes status; see
each backend's README.

The backend is picked by `spec.crossplane.compositionSelector.matchLabels.provider`.

## Backends

| dir | Composition | label |
| --- | --- | --- |
| [`../aws/`](../aws) | `bucket-aws` | `provider: aws` |
| [`../gcp/`](../gcp) | `bucket-gcp` | `provider: gcp` |
| [`../azure/`](../azure) | `bucket-azure` | `provider: azure` |
| [`../rustfs/`](../rustfs) | `bucket-rustfs` | `provider: rustfs` |

[`../import/`](../import) is not a backend: it turns Terraform / Pulumi state
into `Bucket` XRs that adopt existing buckets.

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | the `CompositeResourceDefinition` (`apiextensions.crossplane.io/v2`) |
| `providers.yaml` | `Provider`s `provider-aws-s3`, `provider-gcp-storage`, `provider-azure-storage`; the `rustfs` backend reuses provider-aws-s3 |
| `functions.yaml` | `Function`s `function-kcl` and `function-auto-ready`, pinned and sourced from ghcr.io |
| `examples/bucket-aws.yaml` | every portable field, `provider: aws` |
| `examples/bucket-gcp.yaml` | GCS-relevant fields, `deletionPolicy: Orphan`, `provider: gcp` |
| `examples/bucket-azure.yaml` | `storageClass: archive` (adds the lifecycle policy), `provider: azure` |
| `examples/bucket-rustfs.yaml` | `storageClass: cold` (adds the lifecycle transition), `provider: rustfs` |
| `examples/bucket-import.yaml` | adopts `legacy-assets-8f3a1c` in observe mode with `deletionPolicy: Orphan`, `provider: aws` |
| `models/` | generated KCL schemas (`v1alpha1/cloud_example_org_v1alpha1_bucket.k` + k8s meta) |
| `main.k` | placeholder; points at `models/` |
| `xrd_test.k` | the shipped examples are valid `Bucket`s; `import.mode` and the spec defaults match the XRD |

There is no `providerconfigs.yaml`: `just e2e-providerconfigs bucket` applies
nothing for this module.

## Usage

```bash
just install-module bucket   # xrd.yaml + every ../*/composition.yaml, repointed at the local registry
just workload bucket gcp     # functions, XRD, Compositions, providers, then examples/bucket-gcp.yaml
just e2e bucket              # kind cluster, local registry, publish, install, apply every example
kubectl apply -f packages/cloud/bucket/xrd/examples/bucket-gcp.yaml
just xrd-schema bucket       # regenerate models/ after editing xrd.yaml
```

## Development

```bash
pnpm exec nx run bucket-xrd:test     # kcl test
pnpm exec nx run bucket-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
