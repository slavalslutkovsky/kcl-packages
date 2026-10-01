# kms-oci

OCI backend for the `EncryptionKey` XR (`cloud.example.org/v1alpha1`).
Typed against the [`oci-kms`](../../../providers/oci-kms) provider schema
package, it composes an OCI `Vault` and one `Key` (master encryption key)
created through that vault's management endpoint. The vault is a `DEFAULT`
(free, multitenant) vault; the fixed-cost `VIRTUAL_PRIVATE` vault is never
created. `KeyVersion`s are not composed. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/kms-oci`, then `function-auto-ready`.

The OCI provider has no per-resource region, so both resources bind to the
`ClusterProviderConfig` named `oci-<spec.region>`; create one (and its
credentials Secret) per region you use, see
[`../xrd/providerconfigs.yaml`](../xrd/providerconfigs.yaml).

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Vault` (`kms.oci.m.upbound.io`) | `vault` | always | `vaultType: DEFAULT`, `displayName: <name>`; external-name not pinned (OCID) |
| `Key` (`kms.oci.m.upbound.io`) | `managed` | once the vault's `managementEndpoint` is observed | `displayName: <name>`; `managementEndpoint` from the vault (falls back to the key's own spec/observation) |

The first reconcile renders the vault only; the key follows on a later one.
`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on both.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `region` | `providerConfigRef` `oci-<region>` | |
| `compartmentId` | `compartmentId` (both) | required; render fails without it |
| `algorithm` | `keyShape` | `symmetric` → AES 32 bytes; `rsa-2048/3072/4096` → RSA 256/384/512; `ec-p256`/`ec-p384` → ECDSA 32/48 with `curveId` `NIST_P256`/`NIST_P384` |
| `purpose` | validation only | OCI keys have no purpose field |
| `protectionLevel` | `Key.protectionMode` | `SOFTWARE` / `HSM`; immutable after creation |
| `tags` | `freeformTags` (both) | |
| `deletionPolicy` | `managementPolicies` | |

Rejected: `sign-verify` with `symmetric`, `encrypt-decrypt` with `ec-*`.
Ignored: `rotationDays` (auto rotation needs a private vault),
`deletionWindowDays` (OCI's 30-day default applies), `multiRegion`,
`exportable`, `mountPath`, `resourceGroup`, `tenantId`.

Status written back: `provider: oci`, `keyName`, `region`, `cloud-url`
(per-key console URL once key and vault ids are known); `vaultId`,
`managementEndpoint`, `cryptoEndpoint` from the vault; from the key: `keyId`,
`keyUri`, `id` (all the key OCID), `algorithm`, `protectionLevel`,
`rotationEnabled`. `ready` is true once the key OCID is observed.

## Usage

Unlike the other kms backends, `render` also takes the observed resources
(`params.ocds`). Without `option("params")`, `main.k` renders a built-in
example XR (`il-jerusalem-1`, an example compartment) with nothing observed:
vault only. Pass an observed vault endpoint to see the key:

```bash
kcl run packages/cloud/kms/oci
kcl run packages/cloud/kms/oci -D 'params={"oxr":{"metadata":{"name":"app-data-key"},"spec":{"region":"il-jerusalem-1","compartmentId":"ocid1.compartment.oc1..x"}},"ocds":{"vault":{"Resource":{"status":{"atProvider":{"managementEndpoint":"https://abc-management.kms.il-jerusalem-1.oraclecloud.com"}}}}}}'
```

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/kms-oci.yaml`](../xrd/examples/kms-oci.yaml):

```bash
pnpm exec nx run kms-oci:render
```

On a cluster: `just install-module kms` or `just e2e kms`; install
`provider-family-oci` before `provider-oci-kms` (see
[`../xrd/providers.yaml`](../xrd/providers.yaml)).

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: reads `option("params")`, emits `render(oxr, ocds)` + `status` |
| `kms.k` | `render` (Vault, then Key), `status`, key shapes, ProviderConfig binding |
| `kms_test.k` | `kcl test` cases |
| `composition.yaml` | `kms-oci` Composition, label `provider: oci` |

## Development

```bash
pnpm exec nx run kms-oci:test     # kcl test
pnpm exec nx run kms-oci:lint     # kcl lint
pnpm exec nx run kms-oci:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
