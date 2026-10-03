# bucket-import

Terraform or Pulumi state in, `Bucket` XRs out. Every bucket the state knows
becomes one XR that **adopts** it: `spec.import.existingName` pins the real
cloud name, `mode: observe` keeps Crossplane read-only, and
`deletionPolicy: Orphan` means deleting the XR never deletes the bucket. The
portable fields — versioning, public access, encryption, retention,
lifecycle, cors, logging, website, tags — are read off the state. Output is
typed against [`../xrd`](../xrd)'s generated `Bucket` schema, so a value the
XRD would reject fails in the terminal. The walk from old tool to Crossplane
is [docs/bucket-import.md](../../../../docs/bucket-import.md).

## Usage

```bash
# XRs, one per bucket, into namespace prod
kcl run packages/cloud/bucket/import -D state=state.json -D namespace=prod -q > buckets.yaml

# what was found, dropped and skipped — a report, never pipe it into kubectl
kcl run packages/cloud/bucket/import -D state=state.json -D report=true -q

# no state: maps the built-in demo state (one aws, one gcp bucket)
kcl run packages/cloud/bucket/import -q
```

`state` is resolved against the working directory; pass an absolute path
when running from elsewhere. The `just` recipes do that with `realpath`, so
process substitution works:

```bash
just bucket-import terraform.tfstate                    # namespace default, mode observe
just bucket-import <(terraform show -json) prod         # remote backends: no state file on disk
just bucket-import <(pulumi stack export) prod manage
just bucket-import-report state.json
```

## Inputs

All are KCL options (`-D key=value`).

| option | default | meaning |
| --- | --- | --- |
| `state` | `""` (demo state) | Path to a raw `terraform.tfstate`, `terraform show -json` output, or `pulumi stack export` output; told apart by shape. A missing file fails the render |
| `source` | detected | `terraform` or `pulumi`; overrides detection and is written to `spec.import.source`. Anything else fails |
| `namespace` | `default` | `metadata.namespace` of every XR |
| `mode` | `observe` | `spec.import.mode` of every XR: `observe` \| `manage` |
| `deletionPolicy` | `Orphan` | `spec.deletionPolicy` of every XR: `Orphan` \| `Delete` |
| `report` | `""` | Any non-empty value prints a `BucketImportReport` instead of the XRs |

Resources read: `aws_s3_bucket` and its S3 companions (versioning,
public-access-block, ownership-controls, server-side-encryption, lifecycle,
object-lock, cors, logging, website, request-payment),
`google_storage_bucket`, and Azure storage accounts, in Terraform and Pulumi
spellings, through child modules. The field-by-field mapping and what is
dropped are tabled in [docs/bucket-import.md](../../../../docs/bucket-import.md).

## Outputs

A YAML stream (no `items:` wrapper) of either:

- `Bucket` XRs (`cloud.example.org/v1alpha1`): `metadata.name` is the cloud
  name made DNS-1123 (lowercased, other characters to `-`, at most 63);
  `spec.import` carries `existingName`, `mode`, `source`, `address` (the
  Terraform address or Pulumi URN) and, for Azure, `resourceGroup`;
  `spec.crossplane.compositionSelector.matchLabels.provider` is the provider
  the state named (`aws`, `gcp` or `azure`). Anything the portable schema
  cannot express is named in the `cloud.example.org/import-notes` annotation.
  Because the XR is instantiated from the generated schema, XRD defaults the
  state did not speak for are written out too.
- one `BucketImportReport` (`report=true`): `source`, `state`, `buckets[]`
  (`name`, `provider`, `address`, `companions` — every address to remove from
  the old state — `xr`, `notes`) and `skipped` (bucket-family resources not
  folded in, e.g. `aws_s3_bucket_policy`, `BucketObject`).

## Examples

`testdata/` holds hand-cut state files the tests read; they also run as
inputs:

| file | content |
| --- | --- |
| `testdata/terraform-aws.tfstate.json` | raw tfstate: aws bucket `assets` with every companion and a bucket policy (skipped), plus a `for_each` bucket in `module.logs` |
| `testdata/terraform-show.json` | `terraform show -json`: an Azure storage account (`resourceGroup`) and a GCS bucket in `module.media` |
| `testdata/pulumi-export.json` | `pulumi stack export`: aws bucket with `V2` and unsuffixed companion tokens, a skipped `BucketObject`, gcp and Azure |

```bash
kcl run packages/cloud/bucket/import -D state=packages/cloud/bucket/import/testdata/terraform-aws.tfstate.json -q
kcl run packages/cloud/bucket/import -D state=packages/cloud/bucket/import/testdata/pulumi-export.json -D report=true -q
```

## Layout

| file | content |
| --- | --- |
| `main.k` | options, demo state, report vs XR output |
| `lib.k` | Terraform / Pulumi readers, companion fold, aws / gcp / azure mappers, `xr()`, `k8s_name()` |
| `import_test.k` | `kcl test` cases: both Terraform shapes, Pulumi, every aws companion, legacy inline blocks, GCS tier folding, drop notes, XR shape |
| `testdata/` | state fixtures above |

## Development

```bash
pnpm exec nx run bucket-import:test     # kcl test
pnpm exec nx run bucket-import:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
