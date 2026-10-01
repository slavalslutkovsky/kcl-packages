# kms-gcp

GCP backend for the `EncryptionKey` XR (`cloud.example.org/v1alpha1`).
Typed against the [`gcp-kms`](../../../providers/gcp-kms) provider schema
package, it composes a Cloud KMS `KeyRing` plus one `CryptoKey` inside it, both
named after the XR. The ring is composed rather than shared because its name is
part of the key's resource name. `CryptoKeyVersion`s are not composed: Cloud KMS
creates the first version and rotates it itself. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/kms-gcp`, then `function-auto-ready`.

Cloud KMS key rings and keys can never be deleted, only their versions
destroyed: deleting the XR schedules the key material for destruction and
leaves the empty ring behind.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `KeyRing` (`kms.gcp.m.upbound.io`) | `keyring` | always | external-name `<name>`; `location` from `spec.region` |
| `CryptoKey` (`kms.gcp.m.upbound.io`) | `managed` | always | external-name `<name>`; `keyRingSelector.matchControllerRef` |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on both.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `region` | `KeyRing.forProvider.location` | use a multi-regional location (e.g. `us`) for multi-region keys |
| `purpose` | `purpose` | `ENCRYPT_DECRYPT` / `ASYMMETRIC_SIGN` |
| `algorithm` | `versionTemplate.algorithm` | encrypt: `GOOGLE_SYMMETRIC_ENCRYPTION`, `RSA_DECRYPT_OAEP_<bits>_SHA256`; sign: `RSA_SIGN_PKCS1_<bits>_SHA256`, `EC_SIGN_P256_SHA256`, `EC_SIGN_P384_SHA384` |
| `protectionLevel` | `versionTemplate.protectionLevel` | `SOFTWARE` / `HSM` |
| `deletionWindowDays` | `destroyScheduledDuration` | days × 86400, `s` suffix |
| `rotationDays` | `rotationPeriod` | symmetric keys only; dropped for asymmetric |
| `tags` | `labels` | |
| `deletionPolicy` | `managementPolicies` | |

Rejected: `sign-verify` with `symmetric`, `encrypt-decrypt` with `ec-*`.
Ignored: `multiRegion`, `exportable`, `mountPath`, `resourceGroup`, `tenantId`.

Status written back: `provider: gcp`, `keyName`, `region`, `keyRing`,
`cloud-url`; once the `CryptoKey` id is observed: `keyId`, `keyUri`, `id` (all
the full Cloud KMS resource name) and a per-key console URL; from the observed
`versionTemplate`: `algorithm`, `protectionLevel`; `rotationEnabled` from
`rotationPeriod`. `ready` is true once the id is observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example`, `region: us-central1`). Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/kms/gcp
kcl run packages/cloud/kms/gcp -D 'params={"oxr":{"metadata":{"name":"app-data-key"},"spec":{"region":"us","algorithm":"ec-p384","purpose":"sign-verify","protectionLevel":"hsm","rotationDays":90}}}'
```

The second command renders an `ASYMMETRIC_SIGN` key with
`EC_SIGN_P384_SHA384` and no `rotationPeriod`.

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/kms-gcp.yaml`](../xrd/examples/kms-gcp.yaml):

```bash
pnpm exec nx run kms-gcp:render
```

On a cluster: `just install-module kms` or `just e2e kms`; needs a
`provider-gcp-kms` ProviderConfig with real GCP credentials.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: reads `option("params")`, emits `render` + `status` |
| `kms.k` | `render` (KeyRing + CryptoKey), `status` and the algorithm tables |
| `kms_test.k` | `kcl test` cases |
| `composition.yaml` | `kms-gcp` Composition, label `provider: gcp` |

## Development

```bash
pnpm exec nx run kms-gcp:test     # kcl test
pnpm exec nx run kms-gcp:lint     # kcl lint
pnpm exec nx run kms-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
