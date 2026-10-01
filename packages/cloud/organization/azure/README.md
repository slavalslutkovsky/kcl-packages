# organization-azure

Azure backend for the `Organization` XR (`cloud.example.org/v1alpha1`,
Composition `organization-azure`, label `provider: azure`). Typed against the
`azure-management` and `azure-authorization` schema packages under
[packages/providers/](../../../providers/). It composes the Azure management
hierarchy: a `ManagementGroup` per folder, a `ManagementGroupPolicyAssignment`
per policy and a management-group-scoped `RoleAssignment` per IAM binding.
`function-kcl` runs it from `oci://docker.io/yurikrupnik/organization-azure`.

Each management group's name is its folder key, pinned as
`crossplane.io/external-name`, so every ARM id
(`/providers/Microsoft.Management/managementGroups/<name>`) is known before
Azure answers. Subscriptions are not composed: the installed provider family
ships no `azurerm_subscription`. See
[docs/organization.md](../../../../docs/organization.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `folder-<name>` | `ManagementGroup` (`management.azure.m.upbound.io`) | per `folders[]` | `parentManagementGroupId` = root, or `parentManagementGroupIdSelector` on label `organization.cloud.example.org/folder` |
| `policy-<scope>-<slug>` | `ManagementGroupPolicyAssignment` (`authorization.azure.m.upbound.io`) | per `policies[]` | external-name = definition's last segment, slugged, truncated to 24 chars |
| `iam-<scope>-<role>-<member>` | `RoleAssignment` | per `iamBindings[]` | `scope` is the management-group ARM id as a plain string (no selector); retries until the group exists |

`<scope>` is `org` or `folder-<name>`; `<slug>` lowercases and replaces
`[^a-z0-9-]` with `-`. Renaming a composed resource deletes and recreates it.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `orgId` | root management group: parent of top-level groups, root-scoped policies and grants |
| `folders[].displayName` | `displayName` (default `name`) |
| `policies[].constraint` | `policyDefinitionId`: a value starting with `/` verbatim, else `/providers/Microsoft.Authorization/policyDefinitions/<value>` |
| `policies[].enforce`, `dryRun` | `enforce: false` when `dryRun: true` or `enforce: false` (DoNotEnforce), else `true` |
| `policies[].folder`, `iamBindings[].folder` | `managementGroupIdSelector` / `scope` |
| `iamBindings[].member` | `principalId` (object id GUID) |
| `iamBindings[].role` | `roleDefinitionId` when it starts with `/`, else `roleDefinitionName` |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |

Ignored: `billingAccount`, `owner`, `tags`. Rejected (render fails):
`projects`, `auditLogging`, `folders[].deletionProtection: true`; on policies
`allowedValues`/`deniedValues`, `allowAll`/`denyAll`, `inheritFromParent`,
`reset`, `enforce: true` with `dryRun: true`, a constraint yielding an empty
assignment name, two entries truncating to the same name at one scope; on
bindings a non-GUID `member` or any `condition`; plus duplicate names,
undeclared references, a cycle or more than 6 levels, the same definition
twice at one scope, a repeated member/role/scope grant.

Status written back: `provider: azure`,
`id: /providers/Microsoft.Management/managementGroups/<orgId>`, `folders[]`
(`folderId` = the pinned name, observed `parent`), `projects: []`,
`projectCount: 0`, `folderCount`, `policyCount`, `cloud-url`; `ready` once
every management group has an observed ARM id.

## Usage

`kcl run` with no options renders the built-in `_example` XR (three groups,
one nested):

```bash
kcl run packages/cloud/organization/azure

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/organization/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/organization/xrd/examples/organization-azure.yaml)}"
```

Output is `items:` — the managed resources, then the `Organization` carrying
status. `render` reads only the XR; `ocds` feeds `status` alone.

Through function-kcl (needs docker): `pnpm exec nx run organization-azure:render`.
On a cluster: `just install-module organization`, `just e2e organization`
(needs Azure credentials in a ProviderConfig of your own).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `organization.k` | `definition_id`, `assignment_name`, `render(oxr)`, `status(oxr, ocds)` |
| `organization_test.k` | `kcl test` cases |
| `composition.yaml` | the `organization-azure` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run organization-azure:test     # kcl test
pnpm exec nx run organization-azure:lint     # kcl lint
pnpm exec nx run organization-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
