# backup-azure

Azure Backup for AKS backend for the `BackupPlan` XR
(`cloud.example.org/v1alpha1`, Composition `backup-azure`, label
`provider: azure`). Typed against the schema packages
[`azure-dataprotection`](../../../providers/azure-dataprotection),
[`azure-containerservice`](../../../providers/azure-containerservice) and
[`azure-authorization`](../../../providers/azure-authorization).
`function-kcl` runs it from `oci://docker.io/yurikrupnik/backup-azure`;
`function-auto-ready` follows.

Azure Backup for AKS is Velero run for you: the AKS backup extension installs
it into the cluster and stages backups in a blob container, and a Backup vault
catalogues them. Wiring that up takes a vault, a policy, the extension, a
trusted-access binding, seven role assignments and the backup instance. The
wiring and the role set follow the azurerm example for
[`azurerm_data_protection_backup_instance_kubernetes_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/data_protection_backup_instance_kubernetes_cluster)
one-for-one.

## Composed resources

All are namespaced Upjet MRs (`*.azure.m.upbound.io/v1beta1`) in the XR's
namespace. Most need an id or identity Azure only assigns on creation, so the
plan renders in passes:

| resource | kind | when | notes |
| --- | --- | --- | --- |
| `cluster` | `KubernetesCluster` | always | **observe only** (`managementPolicies: [Observe]`, whatever `deletionPolicy` says); external name = cluster name; read for its system-assigned identity and tenant |
| `vault` | `BackupVault` | always | external name = XR name; cluster RG, `cluster.region`; `VaultStore`, `LocallyRedundant`, `SystemAssigned` identity; `tags` |
| `policy` | `BackupPolicyKubernetesCluster` | always | external name = XR name, in the vault; schedule, retention, `timeZone: UTC` |
| `extension` | `KubernetesClusterExtension` | a tenant id is observed (cluster identity, else vault identity) | external name `azure-aks-backup`; `Microsoft.DataProtection.Kubernetes`, train `stable`, namespace `dataprotection-microsoft`; storage location settings |
| `trusted-access` | `TrustedAccessRoleBinding` | the vault's ARM id is observed | role `Microsoft.DataProtection/backupVaults/backup-operator`; name = XR name (or its first 15 chars + hash when longer than 24) |
| `role-extension-storage` | `RoleAssignment` | extension identity observed | extension → **Storage Account Contributor** on the storage account |
| `role-vault-cluster-reader` | `RoleAssignment` | vault identity observed | vault → Reader on the cluster |
| `role-vault-snapshot-reader` | `RoleAssignment` | vault identity observed | vault → Reader on the snapshot RG |
| `role-vault-snapshot-contributor` | `RoleAssignment` | vault identity observed | vault → Disk Snapshot Contributor on the snapshot RG |
| `role-vault-disk-operator` | `RoleAssignment` | vault identity observed | vault → Data Operator for Managed Disks on the snapshot RG |
| `role-vault-storage` | `RoleAssignment` | vault identity observed | vault → Storage Blob Data Contributor on the storage account |
| `role-cluster-snapshot-contributor` | `RoleAssignment` | cluster identity observed | cluster → Contributor on the snapshot RG |
| `managed` | `BackupInstanceKubernetesCluster` | vault and policy ids observed **and** extension, trusted access and all seven role assignments Ready | external name = XR name; Azure checks every permission when the instance is created and fails it if one is missing |

The first column is the `krm.kcl.dev/composition-resource-name` annotation.
Role assignments are `principalType: ServicePrincipal` with
`skipServicePrincipalAadCheck` (the vault and extension identities are minutes
old). The role set is the azurerm example's exactly — note it grants the
extension *Storage Account Contributor*, where Microsoft's CLI walkthrough
grants *Storage Blob Data Contributor*.

Once a progressive resource exists it stays rendered from its own observed
spec, even if the thing it was derived from is briefly unobserved: dropping
it from the desired state would make Crossplane delete it, and deleting the
backup instance is "stop protection and delete data".

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `cluster.id` | AKS ARM id, parsed into subscription, resource group and name (case-insensitive segments); anything else fails the render. Instance `kubernetesClusterId`, extension `clusterId`, trusted access, Reader scope |
| `cluster.region` | **required**; vault and instance `location` |
| `cluster.snapshotResourceGroup` | instance `snapshotResourceGroupName` and the snapshot-RG role scopes; defaults to the cluster's RG |
| `schedule` | policy `backupRepeatingTimeIntervals` (table below) |
| `retentionDays` | policy `defaultRetentionRule` `P<n>D`, `OperationalStore` (default 30, max 360 — beyond fails the render) |
| `includedNamespaces` | `backupDatasourceParameters.includedNamespaces`; empty is omitted, meaning every namespace |
| `includedResources`, `excludedResources` | `includedResourceTypes`, `excludedResourceTypes` |
| `labelSelector` | `labelSelectors`, `"key=value"` sorted by key |
| `snapshotVolumes` | `volumeSnapshotEnabled` (default true) |
| `destination.provider` | must be `azure` |
| `destination.bucket` | the blob container: extension `configuration.backupStorageLocation.bucket` |
| `destination.storageAccount` | extension `...config.storageAccount`; storage role scopes |
| `destination.resourceGroup` | extension `...config.resourceGroup`; storage role scopes; defaults to the cluster's RG |
| `paused` | `true` fails the render (see below) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on everything but `cluster`, which is always `[Observe]` |
| `tags` | vault `tags` |

`clusterScopedResourcesEnabled` is always `true`: namespaced objects alone
restore into a cluster missing their CRDs, ClusterRoles and PVs.

Schedule translation — Azure Backup for AKS runs only daily or every 4, 6, 8
or 12 hours, in UTC:

| cron | interval |
| --- | --- |
| `m h * * *` | `R/2024-01-01T<hh>:<mm>:00+00:00/P1D` |
| `@daily` | `R/2024-01-01T00:00:00+00:00/P1D` |
| `m */N * * *`, N ∈ {4, 6, 8, 12} | `R/2024-01-01T00:<mm>:00+00:00/PT<N>H` |
| anything else (`@hourly`, `@weekly`, day-of-week, lists, …) | fails the render |

Failing the render (all messages start `backup-azure:`): missing `cluster`,
`cluster.id` that is not an AKS ARM id, missing `cluster.region`, missing
`destination` / `bucket` / `storageAccount`, a `provider` other than `azure`,
an untranslatable `schedule`, `retentionDays` over 360, `paused: true`, and an
XR name that is not 3-50 letters, digits or hyphens (it names the vault,
policy and instance).

Ignored: `encryptionKmsKeyId` (the vault is platform-key encrypted; the blob
container's own encryption applies), `defaultVolumesToFsBackup` (snapshots go
through the storage layer), `destination.prefix`, `destination.region`,
`destination.credentialsSecret`, `destination.s3Url` (Velero-only).

### Things to know before editing a plan

- **Filter edits are disruptive.** Every `backupDatasourceParameters` field is
  ForceNew in the azurerm provider
  ([terraform-provider-azurerm#33453](https://github.com/hashicorp/terraform-provider-azurerm/issues/33453)
  asks for in-place updates). Upjet refuses to replace a resource, so changing
  `includedNamespaces`, `includedResources`, `excludedResources`,
  `labelSelector` or `snapshotVolumes` on a protected plan leaves the
  instance `Synced=False` until it is deleted and recreated — which deletes
  its recovery points. The same holds for `schedule` and `retentionDays` on
  the policy, and for `backupPolicyId` on the instance.
- **`paused` cannot be honoured.** Azure stops protection only by deleting the
  backup instance, which deletes its backups. Delete the XR with
  `deletionPolicy: Orphan` to stop management while keeping them.
- **`deletionPolicy: Delete`** deletes the instance ("stop protection and
  delete data": recovery points are soft-deleted, then purged) and then the
  vault. Use `Orphan` to keep them.
- **One plan per cluster.** Azure allows one backup extension per cluster,
  and this backend names it `azure-aks-backup`; a cluster that already has
  the extension (enabled from the portal or CLI under that name) is adopted.
  Vault and policy names are the XR name in the cluster's resource group, so
  two plans with the same name there would also share a vault.
- **Azure Files volumes** cap retention at 30 days on Azure's side.
- `labelSelectors` semantics (AND vs OR across entries) are Azure's; at worst
  a multi-label selector backs up more than asked, never less. [INFERENCE]

Status written back to the XR:

| field | value |
| --- | --- |
| `provider` | `azure` |
| `ready` | every composed resource (all 13) observed with `Ready=True` |
| `storageLocation` | the vault name — the XR name, known before anything reconciles |
| `phase` | the instance's `protectionState` (`ConfiguringProtection`, `ProtectionConfigured`, `ProtectionError`, …), once reported |
| `message` | the first non-Ready resource in dependency order: `<name>: <Ready condition message or reason>`, or `<name>: waiting for …` when it is not created yet |

## Prerequisites

Outside the XR, before applying it:

- An AKS cluster with a **system-assigned** managed identity (a cluster on a
  user-assigned control-plane identity reports no principal, so
  `role-cluster-snapshot-contributor` and the instance never render; the
  status message says what it waits for).
- The AKS **CSI disk driver and snapshot controller** enabled (the AKS
  defaults; `az aks update --enable-disk-driver --enable-snapshot-controller`).
- Resource providers registered in the subscription:
  `Microsoft.KubernetesConfiguration` (the extension) and
  `Microsoft.DataProtection` (vault, policy, instance).
- The storage account and blob container in `destination` (a `Bucket` XR),
  in the cluster's subscription — the destination carries no subscription.
- The snapshot resource group, when `cluster.snapshotResourceGroup` is set.
- Crossplane providers `provider-azure-dataprotection`,
  `provider-azure-containerservice` and `provider-azure-authorization`, and a
  default `ProviderConfig` whose subscription is the cluster's (the vault and
  the observed cluster are addressed in the ProviderConfig's subscription)
  and whose identity may create role assignments (Owner or User Access
  Administrator on the cluster, snapshot RG and storage account).

## Usage

`main.k` reads `option("params")`, which `function-kcl` injects. Without it,
the package renders a built-in `_example` XR (pass 1: cluster, vault, policy).
Pass a real XR as `params.oxr`, and observed resources as `params.ocds`:

```bash
# built-in example
kcl run packages/cloud/backup/azure

# the shipped example
kcl run packages/cloud/backup/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/backup/xrd/examples/backup-azure.yaml)}"
```

Through Crossplane:

```bash
pnpm exec nx run backup-azure:render   # crossplane render of ../xrd/examples/backup-azure.yaml; needs docker
```

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point; `items` = `render` + `status` |
| `backup.k` | `render(oxr, ocds)`, `status(oxr, ocds)`, `repeating_interval(cron)`, `parse_cluster_id(id)`, `is_ready`, `observed_principals` |
| `backup_test.k` | `kcl test` cases: pass-1 set, progressive wiring, instance gating and stickiness, role set, cron table and rejects, ARM id parsing, required-field asserts, `paused`, `Orphan`, filters, ignored fields, status |
| `composition.yaml` | Composition `backup-azure` (function-kcl → function-auto-ready) |

## Development

```bash
pnpm exec nx run backup-azure:test     # kcl test
pnpm exec nx run backup-azure:lint     # kcl lint
pnpm exec nx run backup-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
