# bucket-rustfs

RustFS backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-rustfs`, label `provider: rustfs`). RustFS is an in-cluster,
S3-compatible server, so this package is typed against the AWS schema package
[`packages/providers/aws-s3`](../../../providers/aws-s3) and reaches the
server through provider-aws-s3 with a `ProviderConfig` named `rustfs`. It
renders an S3 `Bucket` and, for a non-`standard` tier, a lifecycle companion.
`function-kcl` runs it from `oci://docker.io/yurikrupnik/bucket-rustfs`;
`function-auto-ready` follows.

## Composed resources

Both kinds are `s3.aws.m.upbound.io/v1beta1`, both with
`providerConfigRef: {kind: ProviderConfig, name: rustfs}` and
`forProvider.region: us-east-1`.

| resource | when | notes |
| --- | --- | --- |
| `Bucket` (`managed`) | always | nothing else in `forProvider` |
| `BucketLifecycleConfiguration` (`lifecycle`) | `storageClass` is `nearline`, `cold` or `archive` | rule `storage-class`: transition to `STANDARD_IA` after 30 days, `GLACIER_IR` after 90, `DEEP_ARCHIVE` after 180; bound by `bucketSelector.matchControllerRef` |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `storageClass` | the lifecycle companion above; `standard` adds nothing |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` on both resources; the companion then sets `forProvider.bucket` to it instead of `bucketSelector` |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]`; `manage` → the `deletionPolicy` mapping |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |

`region` is required by the XRD but not read: the region is pinned to
`us-east-1`. Every other portable field — `versioning`, `forceDestroy`,
`blockPublicAccess`, `uniformAccess`, `encryptionKmsKeyId`, `requesterPays`,
`retention`, `tags`, `logging`, `website`, `cors`, `lifecycleRules`,
`import.resourceGroup` — is not read either. No status is written back:
`main.k` renders managed resources only, so `status.mode` (the `MODE`
column), `ready` and `bucketName` stay unset.

The `rustfs` ProviderConfig is not shipped by the bucket module (there is no
`../xrd/providerconfigs.yaml`); it must exist, pointing provider-aws-s3 at the
RustFS endpoint, before these resources can reconcile. Adoption works as for
`aws` ([docs/bucket-import.md](../../../../docs/bucket-import.md)), but the
importer never selects this backend: edit the composition selector to
`rustfs` by hand.

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (`region: us-central1`, nothing
else). Pass a real XR as `params.oxr`:

```bash
# built-in example: one Bucket
kcl run packages/cloud/bucket/rustfs

# a shipped example XR (storageClass: cold -> Bucket + BucketLifecycleConfiguration)
kcl run packages/cloud/bucket/rustfs \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-rustfs.yaml)}"
```

Through Crossplane:

```bash
pnpm exec nx run bucket-rustfs:render   # crossplane render of ../xrd/examples/bucket-rustfs.yaml; needs docker
just install-module bucket              # XRD + every bucket Composition, on the current cluster
just workload bucket rustfs             # + the bucket providers, then apply bucket-rustfs.yaml
just e2e bucket                         # kind cluster, local registry, publish, install, apply every example
```

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` |
| `bucket.k` | `render(oxr)`, `mode_of(oxr)`, tier transition map |
| `bucket_test.k` | `kcl test` cases: render, tiers, deletion policy, import, `mode_of` |
| `composition.yaml` | Composition `bucket-rustfs` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-rustfs:test     # kcl test
pnpm exec nx run bucket-rustfs:lint     # kcl lint
pnpm exec nx run bucket-rustfs:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
