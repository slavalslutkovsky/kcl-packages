# bucket-azure

Azure backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-azure`, label `provider: azure`). Typed against the provider schema
package [`packages/providers/azure-storage`](../../../providers/azure-storage).
Renders a Storage `Account` and, for the `archive` tier, a lifecycle
`ManagementPolicy` bound to it through `storageAccountIdSelector.matchControllerRef`.
`function-kcl` runs it from `oci://docker.io/yurikrupnik/bucket-azure`;
`function-auto-ready` follows.

## Composed resources

Both kinds are `storage.azure.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `Account` (`managed`) | always | `accountTier: Standard`, `accountReplicationType: LRS` |
| `ManagementPolicy` (`lifecycle`) | `storageClass: archive`, and not adopting in observe mode | rule `archive`: block blobs tier to Archive 180 days after modification |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `Account.forProvider.location` |
| `storageClass` | `accessTier`: `standard` → `Hot`, `nearline` → `Cool`, `cold` and `archive` → `Cold` (Azure has no account-level Archive, hence the `ManagementPolicy`) |
| `tags` | `Account.forProvider.tags` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` on the `Account` only; the `ManagementPolicy` is never pinned (the provider derives its id from the account) |
| `import.resourceGroup` | `Account.forProvider.resourceGroupName` — the ARM id needs it to observe an adopted account |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]` and no `ManagementPolicy`; `manage` → the `deletionPolicy` mapping |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |

Every other portable field — `versioning`, `forceDestroy`,
`blockPublicAccess`, `uniformAccess`, `encryptionKmsKeyId`, `requesterPays`,
`retention`, `logging`, `website`, `cors`, `lifecycleRules` — is not read by
this backend. No status is written back: `main.k` renders managed resources
only, so `status.mode` (the `MODE` column), `ready` and `bucketName` stay
unset for Azure buckets. Adoption is walked through in
[docs/bucket-import.md](../../../../docs/bucket-import.md).

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (`region: us-central1`, nothing
else). Pass a real XR as `params.oxr`:

```bash
# built-in example: one Account
kcl run packages/cloud/bucket/azure

# a shipped example XR (storageClass: archive -> Account + ManagementPolicy)
kcl run packages/cloud/bucket/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-azure.yaml)}"
```

Through Crossplane:

```bash
pnpm exec nx run bucket-azure:render   # crossplane render of ../xrd/examples/bucket-azure.yaml; needs docker
just install-module bucket             # XRD + every bucket Composition, on the current cluster
just workload bucket azure             # + provider-azure-storage, then apply bucket-azure.yaml
just e2e bucket                        # kind cluster, local registry, publish, install, apply every example
```

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` |
| `bucket.k` | `render(oxr)`, `mode_of(oxr)`, access-tier map |
| `bucket_test.k` | `kcl test` cases: render, tiers, tags, deletion policy, import, `mode_of` |
| `composition.yaml` | Composition `bucket-azure` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-azure:test     # kcl test
pnpm exec nx run bucket-azure:lint     # kcl lint
pnpm exec nx run bucket-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
