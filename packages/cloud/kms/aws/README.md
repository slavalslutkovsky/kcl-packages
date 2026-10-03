# kms-aws

AWS backend for the `EncryptionKey` XR (`cloud.example.org/v1alpha1`).
Typed against the [`aws-kms`](../../../providers/aws-kms) provider schema
package, it composes one KMS `Key` plus one `Alias` bound to it by controller
reference. AWS assigns the key id, so the XR name lands on the alias
(`alias/<name>`), never on the key. Key policies are not composed: the AWS
default root-account policy stays in place. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/kms-aws`, then `function-auto-ready`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Key` (`kms.aws.m.upbound.io`) | `managed` | always | external-name not pinned; description `EncryptionKey <name>` |
| `Alias` (`kms.aws.m.upbound.io`) | `alias` | always | external-name `alias/<name>`; `targetKeyIdSelector.matchControllerRef` |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on both.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `region` | `forProvider.region` (both) | |
| `purpose` | `keyUsage` | `ENCRYPT_DECRYPT` / `SIGN_VERIFY` |
| `algorithm` | `customerMasterKeySpec` | `SYMMETRIC_DEFAULT`, `RSA_2048/3072/4096`, `ECC_NIST_P256/P384` |
| `deletionWindowDays` | `deletionWindowInDays` | clamped to AWS's 30-day maximum |
| `rotationDays` | `enableKeyRotation` + `rotationPeriodInDays` | symmetric keys only (omitted otherwise); raised to AWS's 90-day floor |
| `multiRegion` | `multiRegion` | |
| `tags` | `tags` | |
| `deletionPolicy` | `managementPolicies` | |

Rejected: `sign-verify` with `symmetric`, `encrypt-decrypt` with `ec-*`.
Ignored: `protectionLevel` (KMS keys are always HSM-backed), `exportable`,
`mountPath`, `resourceGroup`, `tenantId`, `compartmentId`.

Status written back: `provider: aws`, `keyName`, `region`, `alias`,
`protectionLevel: hsm`, `cloud-url` (console link, per key once `keyId` is
known); from the observed `Key`: `keyId`, `arn` (also `keyUri`), `algorithm`,
`rotationEnabled`, `id`. `ready` is true once the ARN is observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example`, `region: us-east-1`). Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/kms/aws
kcl run packages/cloud/kms/aws -D 'params={"oxr":{"metadata":{"name":"app-data-key"},"spec":{"region":"eu-west-1","algorithm":"rsa-4096","purpose":"sign-verify","deletionPolicy":"Orphan"}}}'
```

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/kms-aws.yaml`](../xrd/examples/kms-aws.yaml):

```bash
pnpm exec nx run kms-aws:render
```

On a cluster: `just install-module kms` or `just e2e kms`; needs a
`provider-aws-kms` ProviderConfig with real AWS credentials.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: reads `option("params")`, emits `render` + `status` |
| `kms.k` | `render` (Key + Alias) and `status` |
| `kms_test.k` | `kcl test` cases: mappings, clamps, rotation rules, policies, status |
| `composition.yaml` | `kms-aws` Composition, label `provider: aws` |

## Development

```bash
pnpm exec nx run kms-aws:test     # kcl test
pnpm exec nx run kms-aws:lint     # kcl lint
pnpm exec nx run kms-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
