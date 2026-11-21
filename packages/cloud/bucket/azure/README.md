# bucket-azure

Azure backend for the `Bucket` XR (`cloud.example.org/v1alpha1`, Composition
`bucket-azure`, label `provider: azure`). Typed against the provider schema
packages [`azure-storage`](../../../providers/azure-storage),
[`azure-managedidentity`](../../../providers/azure-managedidentity) and
[`azure-authorization`](../../../providers/azure-authorization), plus the
[`federation`](../../federation) library for `spec.access`.
Renders a Storage `Account` and, for the `archive` tier, a lifecycle
`ManagementPolicy` bound to it through `storageAccountIdSelector.matchControllerRef`;
`spec.access` adds keyless CI access to its blobs.
`function-kcl` runs it from `oci://docker.io/yurikrupnik/bucket-azure`;
`function-auto-ready` follows.

## Composed resources

`Account` and `ManagementPolicy` are `storage.azure.m.upbound.io/v1beta1`;
`UserAssignedIdentity` and `FederatedIdentityCredential` are
`managedidentity.azure.m.upbound.io/v1beta1`; `RoleAssignment` is
`authorization.azure.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `Account` (`managed`) | always | `accountTier: Standard`, `accountReplicationType: LRS` |
| `ManagementPolicy` (`lifecycle`) | `storageClass: archive`, and not adopting in observe mode | rule `archive`: block blobs tier to Archive 180 days after modification |
| `UserAssignedIdentity` (`access-<name>`) | per `access` entry | name `<xr name>-<name>` (≤ 128 chars), `location: region`, the access Resource Group, `tags` plus `access-for` (client label, `<ticket> via <client>` for ticket entries) |
| `FederatedIdentityCredential` (`access-<name>-<hash>`) | per subject of the entry, once the identity's `id` is observed | Azure name (external-name) `<identity name>-<hash>`; `issuer`, `subject`, `audience` from the entry; `parentId` = the observed identity id (several identities share the composite, so `matchControllerRef` would be ambiguous) |
| `RoleAssignment` (`access-<name>-grant`) | per entry, once the identity's `principalId` and the account's `id` are observed | `scope` = the account id, `principalType: ServicePrincipal`, `skipServicePrincipalAadCheck: true`; `role` `read` → `Storage Blob Data Reader`, `write` → `Storage Blob Data Contributor`, `admin` → `Storage Blob Data Owner` |

The name in parentheses is the `krm.kcl.dev/composition-resource-name`
annotation. `<name>` is the entry's federation name (its pool id, plus
`-<provider>` when set); `<hash>` is the first 8 hex characters of the
subject's SHA-256. Neither depends on list order, so reordering entries or
subjects replaces nothing. Access resources follow `deletionPolicy` only.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `Account.forProvider.location` |
| `providerConfigName` | `providerConfigRef: {kind: ProviderConfig, name: <it>}` on the `Account`, the `ManagementPolicy` and every access resource: the namespaced ProviderConfig of the subscription billed. Unset: the provider default |
| `storageClass` | `accessTier`: `standard` → `Hot`, `nearline` → `Cool`, `cold` and `archive` → `Cold` (Azure has no account-level Archive, hence the `ManagementPolicy`) |
| `tags` | `Account.forProvider.tags` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; `Delete` leaves the schema default `["*"]` |
| `import.existingName` | `crossplane.io/external-name` on the `Account` only; the `ManagementPolicy` is never pinned (the provider derives its id from the account) |
| `import.resourceGroup` | `Account.forProvider.resourceGroupName` — the ARM id needs it to observe an adopted account |
| `import.mode` | `observe` (default) → `managementPolicies: [Observe]` and no `ManagementPolicy`; `manage` → the `deletionPolicy` mapping |
| `import.source`, `import.address` | annotations `cloud.example.org/imported-from`, `cloud.example.org/import-address` |
| `access[]` | the access resources above, one set per entry; validated by the [`federation`](../../federation) library. Azure trusts only the token's `sub` and `aud`, matched exactly: every entry needs `subjects` (at most 20, no duplicates); `audiences` default to the client's Azure audience (`api://AzureADTokenExchange` for GitHub) |
| `access[].role` | `RoleAssignment.roleDefinitionName` (default `read`): blob data only, never account configuration, keys or IAM |
| `federation.azureResourceGroup` | Resource Group of the access identities and credentials; defaults to `import.resourceGroup`, one of them is required with `access` |
| `federation.gcpProjectNumber`, `federation.awsAccountId`, `federation.awsPermissionsBoundary` | rejected — other clouds only |

Every other portable field — `versioning`, `forceDestroy`,
`blockPublicAccess`, `uniformAccess`, `encryptionKmsKeyId`, `requesterPays`,
`retention`, `logging`, `website`, `cors`, `lifecycleRules` — is not read by
this backend. `main.k` also renders the composite's status: `provider: azure`,
`mode` (the `MODE` column), `ready` (the account's id is observed), `id`,
`bucketName` (the account name), `cloud-url`, `endpoint` (primary blob
endpoint), `region`, and with `access` one `status.access` entry per entry —
`{name, role, clientId, tenantId}`, the ids `azure/login` needs, once the
identity is observed. Adoption is walked through in
[docs/bucket-import.md](../../../../docs/bucket-import.md).

`access` fails the render when no Resource Group is known, when another
cloud's `federation` field is set, and when adopting in `import.mode:
observe` (access writes IAM; switch to `manage` or drop `access`).

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (`region: us-central1`, nothing
else). Pass a real XR as `params.oxr` and observed resources as
`params.ocds` (`{<resource name>: {Resource: {status: {atProvider: ...}}}}`):

```bash
# built-in example: one Account + the composite status
kcl run packages/cloud/bucket/azure

# a shipped example XR (storageClass: archive -> Account + ManagementPolicy)
kcl run packages/cloud/bucket/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/bucket/xrd/examples/bucket-azure.yaml)}"

# access, second pass: identity and account observed -> credential + grant
kcl run packages/cloud/bucket/azure -D params='{"oxr": {"metadata": {"name": "demo"}, "spec": {"region": "westeurope", "federation": {"azureResourceGroup": "rg-ci"}, "access": [{"client": "github", "owner": "acme", "role": "write", "subjects": ["repo:acme/app:ref:refs/heads/main"]}]}}, "ocds": {"managed": {"Resource": {"status": {"atProvider": {"id": "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/demost"}}}}, "access-github-actions-pool": {"Resource": {"status": {"atProvider": {"id": "/subscriptions/s/resourceGroups/rg-ci/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo-github-actions-pool", "principalId": "p", "clientId": "c", "tenantId": "t"}}}}}}'
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
| `main.k` | `params` / `_example` entry point; `items` = `render` + `render_access` + `status` |
| `bucket.k` | `render(oxr)`, `render_access(oxr, ocds)`, `status(oxr, ocds)`, `mode_of(oxr)`, access-tier and blob-role maps |
| `bucket_test.k` | `kcl test` cases: render, tiers, tags, deletion policy, import, `mode_of`, access (two-phase gating, names under reordering, roles, status, failures) |
| `composition.yaml` | Composition `bucket-azure` (function-kcl → function-auto-ready) |
| `CHANGELOG.md` | release notes written by `nx release` |

## Development

```bash
pnpm exec nx run bucket-azure:test     # kcl test
pnpm exec nx run bucket-azure:lint     # kcl lint
pnpm exec nx run bucket-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
