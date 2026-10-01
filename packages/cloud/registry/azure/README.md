# registry-azure

Azure backend for the `Registry` XR (`cloud.example.org/v1alpha1`). Typed
against the `azure-containerregistry` schema package
(`../../../providers/azure-containerregistry`). ACR carries its own retention,
replication, anonymous-pull and encryption settings, so this backend composes
exactly one MR. The Composition `registry-azure` runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/registry-azure`, followed by
`function-auto-ready`.

The ACR name is the XR name and must be 5-50 alphanumeric characters (no
dashes).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Registry` (`containerregistry.azure.m.upbound.io`) | always | `crossplane.io/external-name` pins the ACR name (login server `<name>.azurecr.io`) to the XR name; `adminEnabled: false`, `publicNetworkAccessEnabled: true` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` |
| `resourceGroup` | `resourceGroupName`; required, the render fails without it |
| `tier` | `sku`: `Premium` if `tier: premium`, `replicationRegions` is non-empty or `untaggedRetentionDays` is set; otherwise `Standard` |
| `untaggedRetentionDays` | `retentionPolicyInDays` (forces Premium) |
| `replicationRegions` | `georeplications` (forces Premium); the registry's own region is dropped from the list |
| `publicAccess` | `anonymousPullEnabled` |
| `encryptionKeyId` + `encryptionIdentityClientId` | `identity.type: UserAssigned` and `encryption.{keyVaultKeyId, identityClientId}`, only when both are set |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `forProvider.tags` |

`zoneRedundancyEnabled` follows the sku (true on Premium). Ignored:
`immutableTags`, `scanOnPush`, `keepLastImages`, `forceDestroy`, `storageGb`,
`htpasswdSecret`.

Status written back from the observed registry: `provider: azure`, `ready`
(login server observed), `registryName`, `region`, `cloud-url`, and once
`loginServer` is known: `endpoint`, `repository` (`<loginServer>/<name>`),
`url` (`oci://…`), plus `id`.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`region: westeurope`, `resourceGroup: example-rg`):

```bash
kcl run packages/cloud/registry/azure
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/registry/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/registry/xrd/examples/registry-azure.yaml)}"
```

`pnpm exec nx run registry-azure:render` runs `crossplane render` against
`../xrd/examples/registry-azure.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module registry` installs the XRD and every
backend Composition; `just e2e registry` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `registry.k` | `render`, `status`, `sku_for` |
| `registry_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `registry-azure` |

## Development

```bash
pnpm exec nx run registry-azure:test     # kcl test
pnpm exec nx run registry-azure:lint     # kcl lint
pnpm exec nx run registry-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
