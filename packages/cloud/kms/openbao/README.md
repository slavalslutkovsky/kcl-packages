# kms-openbao

Self-hosted backend for the `EncryptionKey` XR (`cloud.example.org/v1alpha1`):
the key lives in an OpenBao transit secrets engine. Typed against the
[`vault`](../../../providers/vault) provider schema package (upbound
`provider-vault`, wire-compatible with OpenBao), it composes a transit `Mount`
and a transit `SecretBackendKey`. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/kms-openbao`, then `function-auto-ready`.

The OpenBao server is a cluster prerequisite, not composed here: it is
installed by [`../xrd/providerconfigs.yaml`](../xrd/providerconfigs.yaml)
through provider-helm, then initialised and unsealed by hand (the commands are
in that file's header).

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Mount` (`vault.vault.m.upbound.io`) | `transit-mount` | always | external-name and `path` = mount path, `type: transit`; always `Observe, Create, Update, LateInitialize`, whatever `deletionPolicy` says, because the mount is shared by every key on that path |
| `SecretBackendKey` (`transit.vault.m.upbound.io`) | `managed` | always | `name: <XR name>`, `backend: <mount path>`, `minDecryptionVersion: 1`; external-name not pinned (provider derives it) |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `mountPath` | `Mount.path`, `SecretBackendKey.backend` | default `transit` |
| `algorithm` | `SecretBackendKey.type` | `aes256-gcm96`, `rsa-2048/3072/4096`, `ecdsa-p256/p384` |
| `purpose` | validation only | transit types are purely algorithmic |
| `exportable` | `exportable` + `allowPlaintextBackup` | one-way in OpenBao |
| `rotationDays` | `autoRotatePeriod` | days × 86400 seconds; symmetric and asymmetric keys |
| `deletionPolicy` | key `managementPolicies`, `deletionAllowed` | `Delete` → `deletionAllowed: true`; `Orphan` → orphan policies and `deletionAllowed: false` |

Rejected: `sign-verify` with `symmetric`, `encrypt-decrypt` with `ec-*`.
Ignored: `region` (still required by the XRD; the example uses `in-cluster`),
`protectionLevel`, `deletionWindowDays`, `multiRegion`, `tags`.

Status written back: `provider: openbao`, `keyName`, `mountPath`,
`keyId: <name>`, `keyUri: <mountPath>/keys/<name>`,
`cloud-url: bao://<mountPath>/keys/<name>`, `protectionLevel: software`,
`rotationEnabled`; `algorithm` and `id` once observed. `status.region` is never
set. `ready` is true once the observed `latestVersion` is at least 1.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example`, `region: in-cluster`). Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/kms/openbao
kcl run packages/cloud/kms/openbao -D 'params={"oxr":{"metadata":{"name":"app-data-key"},"spec":{"region":"in-cluster","algorithm":"rsa-2048","purpose":"sign-verify","rotationDays":30,"deletionPolicy":"Orphan"}}}'
```

Local `kcl run` output also contains the module's public `default_mount_path`
and `transit_types` next to `items`.

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/kms-openbao.yaml`](../xrd/examples/kms-openbao.yaml):

```bash
pnpm exec nx run kms-openbao:render
```

On a cluster: `just install-module kms` or `just e2e kms`, then the OpenBao
init/unseal and `openbao-token` Secret from `providerconfigs.yaml`.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: reads `option("params")`, emits `render` + `status` |
| `kms.k` | `render` (Mount + SecretBackendKey), `status`, transit type table |
| `kms_test.k` | `kcl test` cases |
| `composition.yaml` | `kms-openbao` Composition, label `provider: openbao` |

## Development

```bash
pnpm exec nx run kms-openbao:test     # kcl test
pnpm exec nx run kms-openbao:lint     # kcl lint
pnpm exec nx run kms-openbao:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
