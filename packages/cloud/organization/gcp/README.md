# organization-gcp

GCP backend for the `Organization` XR (`cloud.example.org/v1alpha1`,
Composition `organization-gcp`, label `provider: gcp`). Typed against the
`gcp-cloudplatform` and `gcp-orgpolicy` schema packages under
[packages/providers/](../../../providers/). It composes the whole GCP resource
hierarchy: Folders, Projects with their enabled APIs, Org Policy v2 policies,
org-wide audit configs and IAM members. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/organization-gcp`.

Every parent/folder/scope reference resolves by selector on the label
`organization.cloud.example.org/folder` stamped on each composed Folder, so a
child waits for its parent and no numeric id has to be known up front. See
[docs/organization.md](../../../../docs/organization.md).

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `folder-<name>` | `Folder` (`cloudplatform.gcp.m.upbound.io`) | per `folders[]` | `parent: organizations/<orgId>` or `parentSelector` on the parent's label |
| `project-<name>` | `Project` | per `projects[]` | `projectId = name`; `orgId` or `folderIdSelector` |
| `service-<project>-<slug>` | `ProjectService` | per `projects[].services[]` | `project` set literally; `disableOnDestroy: false` |
| `policy-<scope>-<slug>` | `Policy` (`orgpolicy.gcp.m.upbound.io`) | per `policies[]` | external-name = `constraint`; `spec`, or `dryRunSpec` with `dryRun` |
| `audit-<slug>` | `OrganizationIAMAuditConfig` | per `auditLogging.services[]`, only when `auditLogging` is set | one `auditLogConfig` per log type |
| `iam-<scope>-<role>-<member>` | `FolderIAMMember` / `OrganizationIAMMember` | per `iamBindings[]` | folder-scoped with `folder`, else org; additive |

`<scope>` is `org` or `folder-<name>`; `<slug>` lowercases and replaces
`[^a-z0-9-]` with `-`. Renaming a composed resource deletes and recreates it.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `orgId` | `organizations/<orgId>` parent; `orgId` on root projects, audit configs and org IAM members |
| `billingAccount`, `projects[].billingAccount` | `Project.billingAccount` (per-project wins) |
| `folders[].displayName` / `deletionProtection` | `displayName` (default `name`) / `deletionProtection` (default `false`) |
| `projects[].displayName` | `Project.name` (default `name`) |
| `projects[].autoCreateNetwork` | `autoCreateNetwork` (default `false`) |
| `projects[].whenDeleted` | `deletionPolicy` `PREVENT` / `ABANDON` / `DELETE` (default `delete`) |
| `tags` + `projects[].labels` | project `labels` (labels win) |
| `policies[]` | `rules[]` with `enforce` / `allowAll` / `denyAll` as `"TRUE"`/`"FALSE"`, `values.allowedValues` / `deniedValues`; `inheritFromParent`; `reset` |
| `auditLogging` | services default `[allServices]`, logTypes default all three, `exemptedMembers` |
| `iamBindings[].condition` | IAM condition; `title` defaults to `<role> condition` |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |

Ignored: `owner`, `projects[].owner`. Rejected (render fails): duplicate folder
or project names; undeclared `parent`/`folder` references; a cycle or more
than 10 folder levels; a project name that is not a GCP project id (6-30
chars, leading letter); a project with no billing account; the same constraint
twice at one scope; a policy mixing `enforce` with list fields, both
`allowAll` and `denyAll`, `reset` with rules, or no rule at all; a repeated
member/role/scope grant.

Status written back: `provider: gcp`, `id: organizations/<orgId>`,
`folders[]` (observed `folderId`, `parent`), `projects[]` (`projectId`,
observed `number`), counts, `cloud-url`; `ready` once every folder has a
`folderId` and every project a `number`.

## Usage

`kcl run` with no options renders the built-in `_example` XR (one folder, one
project):

```bash
kcl run packages/cloud/organization/gcp

# a real XR: params is {oxr, ocds}, as function-kcl passes it
kcl run packages/cloud/organization/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/organization/xrd/examples/organization-gcp.yaml)}"
```

Output is `items:` — the managed resources, then the `Organization` carrying
status. `render` reads only the XR; `ocds` feeds `status` alone.

Through function-kcl (needs docker): `pnpm exec nx run organization-gcp:render`.
On a cluster: `just install-module organization`, `just e2e organization`
(needs GCP credentials in a ProviderConfig of your own).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `organization.k` | `render(oxr)`, `_policy_spec`, `_binding`, `status(oxr, ocds)` |
| `organization_test.k` | `kcl test` cases: folders, projects, services, policy shapes, audit, IAM, Orphan, status |
| `composition.yaml` | the `organization-gcp` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run organization-gcp:test     # kcl test
pnpm exec nx run organization-gcp:lint     # kcl lint
pnpm exec nx run organization-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
