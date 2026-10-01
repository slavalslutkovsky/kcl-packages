# bucket-aws

AWS backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-aws`, label `provider: aws`). Typed against the provider schema
package [`packages/providers/aws-s3`](../../../providers/aws-s3). Renders a
minimal S3 `Bucket` plus one companion managed resource per S3 configuration
API, each bound back to the Bucket through
`bucketSelector.matchControllerRef`. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/bucket-aws`; `function-auto-ready` follows.

## Composed resources

All kinds are `s3.aws.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `Bucket` (`managed`) | always | `region`, `forceDestroy`, `tags`; `objectLockEnabled` when `retention` is set |
| `BucketVersioning` (`versioning`) | always | `Enabled`, or `Suspended` when `versioning: false` |
| `BucketPublicAccessBlock` (`public-access-block`) | always | all four flags set to `blockPublicAccess` |
| `BucketOwnershipControls` (`ownership`) | always | `BucketOwnerEnforced` when `uniformAccess`, else `BucketOwnerPreferred` |
| `BucketServerSideEncryptionConfiguration` (`encryption`) | `encryptionKmsKeyId` set | `aws:kms` with the key, bucket key on; otherwise S3's default SSE |
| `BucketLifecycleConfiguration` (`lifecycle`) | `storageClass` not `standard`, or `lifecycleRules` set | tier transition rule `storage-class` plus one rule per `lifecycleRules` entry |
| `BucketObjectLockConfiguration` (`object-lock`) | `retention` set | default retention `GOVERNANCE` / `COMPLIANCE` for `retention.days` |
| `BucketCorsConfiguration` (`cors`) | `cors` set | one rule per entry; `maxAgeSeconds` falls back to 3600 |
| `BucketLogging` (`logging`) | `logging` set | `targetBucket`, `targetPrefix` |
| `BucketWebsiteConfiguration` (`website`) | `website` set | index suffix (default `index.html`), optional error key |
| `BucketRequestPaymentConfiguration` (`request-payment`) | `requesterPays: true` | payer `Requester` |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every resource |
| `storageClass` | S3 has no bucket tier: a lifecycle transition — `nearline` → `STANDARD_IA` after 30 days, `cold` → `GLACIER_IR` after 90, `archive` → `DEEP_ARCHIVE` after 180; `standard` adds nothing |
| `lifecycleRules[]` | lifecycle rules: `prefix` filter, `expirationDays`, and `transitionDays` + `transitionStorageClass` (`standard`/`nearline`/`cold`/`archive` → `STANDARD`/`STANDARD_IA`/`GLACIER_IR`/`DEEP_ARCHIVE`) |
| `versioning`, `blockPublicAccess`, `uniformAccess`, `encryptionKmsKeyId`, `requesterPays`, `retention`, `cors`, `logging`, `website`, `tags`, `forceDestroy` | the companions above |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` on the Bucket **and** every companion; companions then set `forProvider.bucket` to it instead of `bucketSelector` |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]` on every resource; `manage` → the `deletionPolicy` mapping above |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |

`import.resourceGroup` is ignored (Azure only). Adoption is walked through in
[docs/bucket-import.md](../../../../docs/bucket-import.md).

Status written back to the XR:

| field | value |
| --- | --- |
| `provider` | `aws` |
| `mode` | `created`, `observe` or `managed` (from `spec.import`) |
| `ready` | observed `atProvider.arn` is non-empty |
| `bucketName` | observed `atProvider.id`, else `import.existingName`, else `metadata.name` |
| `region` | observed region, else `spec.region` |
| `url` | `s3://<bucketName>` |
| `cloud-url` | S3 console URL for the bucket |
| `arn`, `endpoint`, `id` | from `atProvider` once observed; `endpoint` prefers the regional domain name |

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (`region: us-east-1`, nothing
else). Pass a real XR as `params.oxr`:

```bash
# built-in example: Bucket, BucketVersioning, BucketPublicAccessBlock, BucketOwnershipControls + status
kcl run packages/cloud/bucket/aws

# a shipped example XR (every companion except request-payment)
kcl run packages/cloud/bucket/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-aws.yaml)}"

# adoption in observe mode: external-name and [Observe] on every resource
kcl run packages/cloud/bucket/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-import.yaml)}"
```

Locally the XR has no API-server defaults applied, so the code's own
fallbacks stand in for them (`versioning`, `blockPublicAccess`,
`uniformAccess` true; `deletionPolicy` `Delete`).

Through Crossplane:

```bash
pnpm exec nx run bucket-aws:render   # crossplane render of ../xrd/examples/bucket-aws.yaml; needs docker
just install-module bucket           # XRD + every bucket Composition, on the current cluster
just workload bucket aws             # + provider-aws-s3, then apply bucket-aws.yaml
just e2e bucket                      # kind cluster, local registry, publish, install, apply every example
```

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` + `status` |
| `bucket.k` | `render(oxr)`, `status(oxr, ocds)`, `mode_of(oxr)`, tier maps |
| `bucket_test.k` | `kcl test` cases: each companion, defaults, orphan policies, import, status |
| `composition.yaml` | Composition `bucket-aws` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-aws:test     # kcl test
pnpm exec nx run bucket-aws:lint     # kcl lint
pnpm exec nx run bucket-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
