# registry-aws

AWS backend for the `Registry` XR (`cloud.example.org/v1alpha1`). Typed
against the `aws-ecr` schema package (`../../../providers/aws-ecr`), it maps
the portable registry onto one ECR `Repository` plus two optional companion
policy MRs bound to it by controller reference. The Composition
`registry-aws` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/registry-aws`, followed by `function-auto-ready`.

Account-wide ECR resources (`RegistryScanningConfiguration`,
`ReplicationConfiguration`) are deliberately not composed: they configure the
whole account registry, so one XR would overwrite another's settings.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Repository` (`ecr.aws.m.upbound.io`) | always | `crossplane.io/external-name` pins the ECR repository name to the XR name (it is part of every image reference) |
| `LifecyclePolicy` (`ecr.aws.m.upbound.io`) | `untaggedRetentionDays` or `keepLastImages` set | Rule 1 expires untagged images after N days (`sinceImagePushed`); rule 2 (`tagStatus=any`, always last) keeps the N most recent images |
| `RepositoryPolicy` (`ecr.aws.m.upbound.io`) | `publicAccess: true` | Anonymous (`Principal: *`) `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` |

Both policy MRs select the repository with `repositorySelector.matchControllerRef`.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every MR |
| `immutableTags` | `imageTagMutability`: `IMMUTABLE` / `MUTABLE` (default `false`) |
| `scanOnPush` | `imageScanningConfiguration.scanOnPush` (default `true`) |
| `forceDestroy` | `forceDelete` (default `false`) |
| `encryptionKeyId` | `encryptionConfiguration: [{encryptionType: KMS, kmsKey}]`; omitted entirely otherwise (AES256) |
| `untaggedRetentionDays`, `keepLastImages` | `LifecyclePolicy` rules |
| `publicAccess` | `RepositoryPolicy` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | `forProvider.tags` on the repository |

Ignored: `tier`, `resourceGroup`, `encryptionIdentityClientId`,
`replicationRegions`, `storageGb`, `htpasswdSecret`.

Status written back from the observed repository: `provider: aws`,
`ready` (ARN observed), `registryName`, `region`, `cloud-url`, and once ECR
reports `repositoryUrl`: `endpoint` (`<account>.dkr.ecr.<region>.amazonaws.com`),
`repository`, `url` (`oci://…`), plus `arn` and `id`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`metadata.name: example`, `region: us-east-1`):

```bash
kcl run packages/cloud/registry/aws
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/registry/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/registry/xrd/examples/registry-aws.yaml)}"
```

`pnpm exec nx run registry-aws:render` runs `crossplane render` against
`../xrd/examples/registry-aws.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module registry` installs the XRD and every
backend Composition; `just e2e registry` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `registry.k` | `render`, `status`, `lifecycle_policy`, `public_pull_policy` |
| `registry_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `registry-aws` |

## Development

```bash
pnpm exec nx run registry-aws:test     # kcl test
pnpm exec nx run registry-aws:lint     # kcl lint
pnpm exec nx run registry-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
