# kms-azure

Azure backend for the `EncryptionKey` XR (`cloud.example.org/v1alpha1`).
Typed against the [`azure-keyvault`](../../../providers/azure-keyvault)
provider schema package, it composes a Key Vault `Vault` and one `Key` inside
it, both named after the XR. Azure has no standalone key; one vault per XR keeps
the SKU, soft-delete window and RBAC surface owned by one claim. Run by
`function-kcl` from `oci://docker.io/yurikrupnik/kms-azure`, then
`function-auto-ready`.

The vault name is the data-plane host `<name>.vault.azure.net`, so the XR name
must be 3-24 characters, alphanumerics and dashes, and globally unique. The vault
uses RBAC authorization: the provider identity needs the
"Key Vault Crypto Officer" role on it, as does anything that encrypts with the
key.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Vault` (`keyvault.azure.m.upbound.io`) | `vault` | always | external-name `<name>`; RBAC authorization, purge protection and public network access on |
| `Key` (`keyvault.azure.m.upbound.io`) | `managed` | always | external-name `<name>`; `keyVaultIdSelector.matchControllerRef` |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on both.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `region` | `Vault.location` | |
| `resourceGroup` | `Vault.resourceGroupName` | required; render fails without it |
| `tenantId` | `Vault.tenantId` | required; render fails without it |
| `protectionLevel` | `Vault.skuName`, `Key.keyType` | `software` → `standard` + `RSA`/`EC`; `hsm` → `premium` + `RSA-HSM`/`EC-HSM` |
| `algorithm` | `keySize` or `curve` | `symmetric` → RSA 4096 wrap key; `rsa-*` → `keySize`; `ec-p256`/`ec-p384` → `curve` `P-256`/`P-384` |
| `purpose` | `keyOpts` | `decrypt, encrypt, wrapKey, unwrapKey` / `sign, verify` |
| `rotationDays` | `rotationPolicy` | `automatic.timeAfterCreation: P<n>D`, `expireAfter: P<2n>D`, `notifyBeforeExpiry: P30D` |
| `deletionWindowDays` | `Vault.softDeleteRetentionDays` | |
| `tags` | `tags` (both) | |
| `deletionPolicy` | `managementPolicies` | |

Rejected: `sign-verify` with `symmetric`, `encrypt-decrypt` with `ec-*`.
Ignored: `multiRegion`, `exportable`, `mountPath`, `compartmentId`.

Status written back: `provider: azure`, `keyName`, `region`, `cloud-url`
(vault keys blade once the vault id is observed); `vaultUri` from the vault;
from the key: `keyId` and `keyUri` (the versionless id), `version`,
`algorithm` (observed key type), `protectionLevel` (`hsm` when the key type
ends in `-HSM`), `rotationEnabled`, `id`. `ready` is true once the versionless
id is observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example`, `westeurope`, `platform-rg`, a zero tenant id). Pass a real XR as
`params.oxr`:

```bash
kcl run packages/cloud/kms/azure
kcl run packages/cloud/kms/azure -D 'params={"oxr":{"metadata":{"name":"app-data-key"},"spec":{"region":"westeurope","resourceGroup":"platform-rg","tenantId":"11111111-2222-3333-4444-555555555555","algorithm":"ec-p256","purpose":"sign-verify","protectionLevel":"hsm","rotationDays":180}}}'
```

The second command renders a `premium` vault and an `EC-HSM` key on curve
`P-256` with a 180-day rotation policy.

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/kms-azure.yaml`](../xrd/examples/kms-azure.yaml):

```bash
pnpm exec nx run kms-azure:render
```

On a cluster: `just install-module kms` or `just e2e kms`; needs a
`provider-azure-keyvault` ProviderConfig with real Azure credentials.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: reads `option("params")`, emits `render` + `status` |
| `kms.k` | `render` (Vault + Key), `status`, key-type/SKU/rotation helpers |
| `kms_test.k` | `kcl test` cases |
| `composition.yaml` | `kms-azure` Composition, label `provider: azure` |

## Development

```bash
pnpm exec nx run kms-azure:test     # kcl test
pnpm exec nx run kms-azure:lint     # kcl lint
pnpm exec nx run kms-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
