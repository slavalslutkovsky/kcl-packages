# bucket-gcp

GCP backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-gcp`, label `provider: gcp`). Typed against the provider schema
package [`packages/providers/gcp-storage`](../../../providers/gcp-storage).
GCS expresses versioning, access, encryption, retention, lifecycle, cors,
logging and website inline, so every portable field lands on a single
Cloud Storage `Bucket`. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/bucket-gcp`; `function-auto-ready` follows.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Bucket` (`storage.gcp.m.upbound.io/v1beta1`), resource name `managed` | always | the only managed resource |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to (`forProvider.`) |
| --- | --- |
| `region` | `location` |
| `storageClass` | `storageClass` (`STANDARD` / `NEARLINE` / `COLDLINE` / `ARCHIVE`); a non-`standard` tier also adds a `SetStorageClass` lifecycle rule at age 0 |
| `versioning` | `versioning.enabled` |
| `blockPublicAccess` | `publicAccessPrevention`: `enforced`, else `inherited` |
| `uniformAccess` | `uniformBucketLevelAccess` |
| `encryptionKmsKeyId` | `encryption.defaultKmsKeyName` |
| `requesterPays` | `requesterPays` |
| `retention` | `retentionPolicy.retentionPeriod` = `days` × 86400; `isLocked` when `mode: compliance` |
| `logging` | `logging.logBucket`, `logging.logObjectPrefix` |
| `website` | `website.mainPageSuffix` (default `index.html`), `website.notFoundPage` |
| `cors[]` | `cors[]`: `origin`, `method`, `responseHeader`, `maxAgeSeconds` (default 3600) |
| `lifecycleRules[]` | per entry, a `Delete` rule at `expirationDays` and/or a `SetStorageClass` rule at `transitionDays`; `prefix` becomes `matchesPrefix` |
| `tags` | `labels` |
| `forceDestroy` | `forceDestroy` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` — the bucket name is the whole identity |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]`; `manage` → the `deletionPolicy` mapping |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |

`import.resourceGroup` is ignored (Azure only). Adoption is walked through in
[docs/bucket-import.md](../../../../docs/bucket-import.md).

Status written back to the XR:

| field | value |
| --- | --- |
| `provider` | `gcp` |
| `mode` | `created`, `observe` or `managed` (from `spec.import`) |
| `ready` | observed `atProvider.id` is non-empty |
| `bucketName` | observed `atProvider.id`, else `import.existingName`, else `metadata.name` |
| `cloud-url` | Cloud console storage browser URL |
| `endpoint` | `<bucketName>.storage.googleapis.com` |
| `url`, `selfLink`, `id`, `region`, `storageClass` | from `atProvider` once observed (`region` is `atProvider.location`) |

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (`region: us-central1`, nothing
else). Pass a real XR as `params.oxr`:

```bash
# built-in example: one Bucket + status
kcl run packages/cloud/bucket/gcp

# a shipped example XR
kcl run packages/cloud/bucket/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-gcp.yaml)}"
```

Locally the XR has no API-server defaults applied, so the code's own
fallbacks stand in for them (`versioning`, `blockPublicAccess`,
`uniformAccess` true; `deletionPolicy` `Delete`; no `storageClass` set).

Through Crossplane:

```bash
pnpm exec nx run bucket-gcp:render   # crossplane render of ../xrd/examples/bucket-gcp.yaml; needs docker
just install-module bucket           # XRD + every bucket Composition, on the current cluster
just workload bucket gcp             # + provider-gcp-storage, then apply bucket-gcp.yaml
just e2e bucket                      # kind cluster, local registry, publish, install, apply every example
```

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` + `status` |
| `bucket.k` | `render(oxr)`, `status(oxr, ocds)`, `mode_of(oxr)`, storage-class map |
| `bucket_test.k` | `kcl test` cases: every field mapping, deletion policy, import, status |
| `composition.yaml` | Composition `bucket-gcp` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-gcp:test     # kcl test
pnpm exec nx run bucket-gcp:lint     # kcl lint
pnpm exec nx run bucket-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
