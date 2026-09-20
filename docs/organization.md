# Organization (cloud resource hierarchy)

One `Organization` XR is a whole cloud organization: the folder tree, the
accounts inside it, the policies that constrain them, organization-wide
auditing, and the grants at the top. It does **not** create the organization
itself, the billing account or the identities that use them — those are bought
or live in their own XRs.

```
kubectl -n default apply -f packages/cloud/organization/xrd/examples/organization-gcp.yaml
kubectl -n default get organization
NAME          READY   PROVIDER   ORG            FOLDERS   PROJECTS
yurikrupnik   true    gcp        477132171939   12        6
```

Backend selection is a label, not a field:

```yaml
  crossplane:
    compositionSelector:
      matchLabels:
        provider: gcp        # gcp | aws | azure
```

**One XR per organization.** Two XRs naming the same `orgId` with different
folder or policy sets fight over the same external objects.

## The tool map

The three clouds agree on the tree and disagree on everything hanging off it.
The XRD carries no cloud-specific field: a field a backend cannot express
**fails the render with a message naming the alternative**, and is never
silently dropped.

| spec | gcp | aws | azure |
|---|---|---|---|
| `folders[]` | `Folder` (cloudplatform) | `OrganizationalUnit` | `ManagementGroup` |
| nesting bound by | `parentSelector` on the composed Folder | **observed parent id** — no ref/selector exists (see below) | `parentManagementGroupIdSelector` |
| depth limit | 10 levels | 5 levels | 6 levels |
| `folders[].deletionProtection` | `deletionProtection` | rejected — no such flag | rejected — no such flag |
| `projects[]` | `Project` | `Account` (needs `owner`, the root email) | **rejected** — no `azurerm_subscription` in the installed family |
| `projects[].services[]` | one `ProjectService` each | rejected — services are org-wide on AWS | rejected |
| `projects[].whenDeleted` | `deletionPolicy` PREVENT/ABANDON/DELETE | `closeOnDeletion` (delete closes, prevent/abandon leave) | n/a |
| `billingAccount` | linked to the project; missing is fatal | ignored — consolidated billing by construction | ignored |
| `policies[]` | Org Policy **v2** `Policy` | `Policy` (SCP) + `PolicyAttachment` | `ManagementGroupPolicyAssignment` |
| `policies[].enforce` | boolean constraint on/off | rejected — an SCP names actions | enforcement mode (`enforce`) |
| `policies[].allowedValues`/`deniedValues` | list-constraint values | IAM actions in the SCP document | rejected — assignment parameters are definition-specific |
| `policies[].allowAll`/`denyAll`/`inheritFromParent`/`reset` | supported | rejected | rejected |
| `policies[].dryRun` | `dryRunSpec` | rejected — an attached SCP always denies | enforcement mode `DoNotEnforce` |
| `auditLogging` | `OrganizationIAMAuditConfig` per service | rejected — an org trail needs a bucket | rejected — a diagnostic setting needs a destination |
| `iamBindings[]` | `Organization`/`FolderIAMMember` | rejected — no IAM at OU scope | `RoleAssignment` scoped to the management group |
| `iamBindings[].member` | IAM member (`group:…`, `serviceAccount:…`) | — | object id (GUID) |
| `iamBindings[].condition` | IAM condition (CEL) | — | rejected — ABAC is not portable |

Two consequences worth saying out loud:

1. **AWS is a second pass.** `OrganizationalUnit.parentId`, `Account.parentId`
   and `PolicyAttachment.targetId` have **no** ref or selector in the generated
   schemas, so `render(oxr, ocds)` reads the parent OU's observed id and emits
   a nested OU, an account or a folder-scoped attachment only once it is known.
   A node whose parent is not observed yet is withheld rather than created in
   the wrong place — AWS does not re-parent on update. Same pattern as
   `docs/hubspoke.md`, "Ordering the backends cannot avoid". `status.ready` is
   where the XR says the tree is complete.
2. **An AWS allow-list SCP emits two statements.** AWS attaches `FullAWSAccess`
   (Allow `*`) to every root, OU and account, so a bare `Allow` list changes
   nothing. `allowedValues` therefore renders `Allow Action=[…]` **plus**
   `Deny NotAction=[…]`, which is what makes an allow list mean "only these".
   `deniedValues` renders one `Deny Action=[…]`.

## Identity of a node

| | gcp | aws | azure |
|---|---|---|---|
| folder `name` is | a label on the composed Folder; GCP assigns the numeric id | a label on the OU; AWS assigns `ou-…` | **the management group's name**, pinned as `crossplane.io/external-name` |
| project `name` is | the project id verbatim (the gcp backend enforces GCP's 6-30/leading-letter rule itself, because the XRD pattern is the portable one) | the account name; AWS assigns the 12-digit id | — |
| policy identity | the constraint id (`crossplane.io/external-name`) | `forProvider.name`; the SCP id `p-…` is provider-assigned | the assignment name, derived from the definition's last segment and truncated to Azure's 24-character cap |

Because an Azure management-group name is deterministic, `status.folders[].folderId`
is known before Azure answers; readiness there comes from the observed ARM id
instead.

## Status

| field | meaning |
|---|---|
| `ready` | every declared folder has an id **and** every declared account has one; on aws this is also "the second pass is done" |
| `folders[]` | spec order: `name`, `folderId` (GCP numeric id / `ou-…` / management-group name), observed `parent` |
| `projects[]` | spec order: `name`, `projectId` (GCP project id / AWS 12-digit account id), `number` (GCP project number only) |
| `folderCount`, `projectCount`, `policyCount` | what this XR manages |
| `id`, `cloud-url` | the hierarchy root and its console page |

## Rejected at render time, on every backend

- a `parent`/`folder` naming a folder that is not declared;
- a parent cycle, or nesting deeper than that cloud's limit;
- duplicate folder keys or account keys;
- the same policy twice at the same scope, or a repeated member/role/scope grant;
- plus each backend's own list from the table above, and on gcp: a project with
  no billing account, a policy mixing `enforce` with list fields or carrying no
  rule at all; on aws: an account with no `owner`, a policy with neither value
  list, a `(scope, constraint)` pair too long to be a Kubernetes label value
  (the `PolicyAttachment` selects its `Policy` by that label); on azure: a
  non-GUID `member`, `enforce: true` together with `dryRun: true`, and two
  entries whose truncated assignment names would collide.

## Files

| path | what |
|---|---|
| `packages/cloud/organization/xrd/xrd.yaml` | the API: `organizations.cloud.example.org`, Namespaced, v1alpha1 — cloud-neutral, every field documents its per-backend fate |
| `packages/cloud/organization/xrd/models/` | generated schemas (`just xrd-schema organization`) — never hand-edited |
| `packages/cloud/organization/xrd/providers.yaml` | the five provider families across the three backends |
| `packages/cloud/organization/xrd/examples/` | one XR per backend |
| `packages/cloud/organization/gcp/organization.k` | folders, projects, services, org policies, audit configs, IAM members |
| `packages/cloud/organization/aws/organization.k` | OUs, accounts, SCP documents + attachments; the observed-id second pass |
| `packages/cloud/organization/azure/organization.k` | management groups, policy assignments, role assignments |
| `packages/providers/registry.yaml` | rows `gcp-orgpolicy`, `aws-organizations`, `azure-management`; `gcp-cloudplatform` and `azure-authorization` gained `organization` |
| `devkit.toml` | the `organization-*` deps rows: XRD wave 2, providers 3, Compositions 4, examples 5 |

## Commands

```bash
nx run-many -t build test lint --projects=organization-xrd,organization-gcp,organization-aws,organization-azure
just render organization-gcp          # render the example XR through function-kcl (docker)
just render organization-aws
just render organization-azure
just xrd-schema organization          # regenerate xrd/models after an XRD change
just seed-organization-providers      # regenerate the five schema packages
kubectl -n default get organization
```

## Not covered on purpose

- **No service accounts or per-account IAM.** `Identity`
  (`cloud.example.org/v1alpha1`) owns those; this XR grants only at the top of
  the tree, where a cloud supports it.
- **No organization, billing account, subscription purchase or domain
  verification.** None of them is creatable through an API a controller may
  call, and Azure subscriptions additionally have no resource in the installed
  provider families.
- **No audit destinations.** Carrying a bucket, storage account or workspace
  reference would be exactly the cloud-specific field this API refuses; compose
  the destination with its own XR and point an explicit trail or diagnostic
  setting at it.
- **No essential contacts, tag keys/values, VPC Service Controls perimeters or
  AWS delegated administrators.** Each is a separate family and a separate
  lifecycle.
