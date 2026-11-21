# bucket-aws

AWS backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-aws`, label `provider: aws`). Typed against the provider schema
packages [`packages/providers/aws-s3`](../../../providers/aws-s3) and
[`packages/providers/aws-iam`](../../../providers/aws-iam). Renders a
minimal S3 `Bucket` plus one companion managed resource per S3 configuration
API, each bound back to the Bucket through
`bucketSelector.matchControllerRef`, and an IAM role per `spec.access`
entry. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/bucket-aws`; `function-auto-ready` follows.

## Composed resources

Bucket kinds are `s3.aws.m.upbound.io/v1beta1`.

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

Per `spec.access` entry (`iam.aws.m.upbound.io/v1beta1`, needs
provider-aws-iam; `<name>` is the entry's pool id, plus `-<provider>` when
`provider` is set, so reordering entries replaces nothing):

| resource | when | notes |
| --- | --- | --- |
| `Role` (`access-<name>`) | always | `crossplane.io/external-name` pinned to `<xr namespace>-<xr name>-<name>` (over 64 characters: its first 55 + `-` + 8 hex of its sha256); `assumeRolePolicy` = `sts:AssumeRoleWithWebIdentity` from `arn:aws:iam::<awsAccountId>:oidc-provider/<issuer host>` with `<host>:aud` (StringEquals) and `<host>:sub` (StringLike) from the federation library; `description` names the XR, client and ticket system; `tags`; with `federation.awsPermissionsBoundary`, `permissionsBoundary` plus the tag `cloud.example.org/permissions-boundary: <boundary ARN>` (set last, so `spec.tags` cannot override it) |
| `RolePolicy` (`access-<name>-policy`) | once the bucket name is known: `import.existingName`, else the observed Bucket's `atProvider.id` (second pass) | inline policy on the pinned role, statements `Bucket` (`arn:aws:s3:::<bucket>`), `Objects` (`arn:aws:s3:::<bucket>/*`) and, with `encryptionKmsKeyId`, `Kms` on that key |

Actions per `role` (object data only, never bucket configuration, bucket
policy or IAM):

| role | bucket | objects | KMS key |
| --- | --- | --- | --- |
| `read` | `ListBucket`, `GetBucketLocation` | `GetObject`, `GetObjectVersion` | `Decrypt` |
| `write` | read + `ListBucketMultipartUploads` | read + `PutObject`, `DeleteObject`, `AbortMultipartUpload`, `ListMultipartUploadParts` | `Decrypt`, `GenerateDataKey` |
| `admin` | write + `ListBucketVersions` | write + `DeleteObjectVersion`, `RestoreObject`, object (version) ACLs, tagging, retention, legal hold, `BypassGovernanceRetention` | `Decrypt`, `GenerateDataKey` |

The IAM OIDC provider for each issuer (one per account) is not composed: it
must already exist in `federation.awsAccountId`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every resource |
| `providerConfigName` | `providerConfigRef: {kind: ProviderConfig, name: <it>}` on every resource, access roles and policies included: the namespaced ProviderConfig of the account the bucket is created in and billed to ([platform/tenant-account](../../../platform/tenant-account) renders them for client accounts). Unset: no ref, the provider default `ClusterProviderConfig/default` |
| `storageClass` | S3 has no bucket tier: a lifecycle transition — `nearline` → `STANDARD_IA` after 30 days, `cold` → `GLACIER_IR` after 90, `archive` → `DEEP_ARCHIVE` after 180; `standard` adds nothing |
| `lifecycleRules[]` | lifecycle rules: `prefix` filter, `expirationDays`, and `transitionDays` + `transitionStorageClass` (`standard`/`nearline`/`cold`/`archive` → `STANDARD`/`STANDARD_IA`/`GLACIER_IR`/`DEEP_ARCHIVE`) |
| `versioning`, `blockPublicAccess`, `uniformAccess`, `encryptionKmsKeyId`, `requesterPays`, `retention`, `cors`, `logging`, `website`, `tags`, `forceDestroy` | the companions above |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` on the Bucket **and** every companion; companions then set `forProvider.bucket` to it instead of `bucketSelector` |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]` on every resource; `manage` → the `deletionPolicy` mapping above |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |
| `access[]` | the access resources above; the federation fields (client/owner/repositories/subjects/audiences/...) go through `packages/cloud/federation` `aws_trust`: AWS sees only `sub` and `aud`, so `ticket`, `workflows` or `condition` without explicit `subjects` fail the render |
| `federation.awsAccountId` | account of the trusted IAM OIDC providers; required with `access` |
| `federation.awsPermissionsBoundary` | `permissionsBoundary` and the boundary tag on every access `Role`; must be a policy of `awsAccountId`. Required in a client account whose provisioner role only creates capped roles (tenant-account `accessRoles`) |

`import.resourceGroup` is ignored (Azure only). Adoption is walked through in
[docs/bucket-import.md](../../../../docs/bucket-import.md).

The render fails (`bucket-aws: ...`) when `access` is set without
`federation.awsAccountId`, when `federation.gcpProjectNumber` or
`federation.azureResourceGroup` is set, when `access` is combined with an
observe-mode import (access writes IAM), when `access` meets an
`encryptionKmsKeyId` that is not a key ARN (the policy grants on the ARN), and
when `federation.awsPermissionsBoundary` is a policy of another account than
`federation.awsAccountId`.

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
| `access[]` | with `spec.access`: `{name, role}` per entry, plus `roleArn` (the role to assume, e.g. `role-to-assume` of aws-actions/configure-aws-credentials) once the role is observed |

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
| `main.k` | `params` / `_example` entry point; `items` = `render` + `render_access` + `status` |
| `bucket.k` | `render(oxr)`, `render_access(oxr, ocds)`, `status(oxr, ocds)`, `mode_of(oxr)`, `access_role_name`, `access_policy`, tier and action maps |
| `bucket_test.k` | `kcl test` cases: each companion, defaults, orphan policies, import, status, access (trust, actions per role, KMS, two-phase, names, failures) |
| `composition.yaml` | Composition `bucket-aws` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-aws:test     # kcl test
pnpm exec nx run bucket-aws:lint     # kcl lint
pnpm exec nx run bucket-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
