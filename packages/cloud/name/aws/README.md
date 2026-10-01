# name-aws

AWS backend for the `Name` XR (`cloud.example.org/v1alpha1`): an S3 bucket,
plus a lifecycle configuration that stands in for the portable storage tier.
Typed against the vendored `aws-s3` schema package
([../../../providers/aws-s3](../../../providers/aws-s3)). The `name-aws`
Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/name-aws`, followed by `function-auto-ready`.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `Bucket` (`s3.aws.m.upbound.io`) | always | composition-resource-name `managed` |
| `BucketLifecycleConfiguration` (`s3.aws.m.upbound.io`) | `spec.storageClass` is `nearline`, `cold` or `archive` | composition-resource-name `lifecycle`; binds the bucket with `bucketSelector.matchControllerRef`; one enabled rule `storage-class` with an empty filter and one transition |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on both MRs |
| `storageClass` | S3 has no bucket-level class, so the tier becomes an object transition: `nearline` → `STANDARD_IA` after 30 days, `cold` → `GLACIER_IR` after 90, `archive` → `DEEP_ARCHIVE` after 180; `standard` or unset adds no lifecycle MR |

No status is written back to the XR.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR (region
`us-central1`, no storage class), so only the bucket:

```bash
kcl run packages/cloud/name/aws
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>}`):

```bash
kcl run packages/cloud/name/aws \
    -D params='{"oxr":{"metadata":{"name":"demo"},"spec":{"region":"us-east-1","storageClass":"archive"}}}'
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker). The module has no `name-aws` example under
[../xrd/examples/](../xrd/examples/), so pass one with `--example=<file>`:

```bash
pnpm exec nx run name-aws:render --example=<file>
```

On a cluster: `just install-module name` applies the XRD and both Compositions
repointed at the local registry. The module ships no `providers.yaml`, so
`just e2e name` installs no provider for the S3 MRs.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` |
| `name.k` | `render`: Bucket + tier lifecycle |
| `name_test.k` | `kcl test` cases: bucket only, bucket + lifecycle |
| `composition.yaml` | `name-aws` Composition (`provider: aws` label) |

## Development

```bash
pnpm exec nx run name-aws:test     # kcl test
pnpm exec nx run name-aws:lint     # kcl lint
pnpm exec nx run name-aws:render   # crossplane render (docker; needs --example)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
