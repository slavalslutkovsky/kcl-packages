# organization-xrd

The `Organization` XRD (`organizations.cloud.example.org`, group
`cloud.example.org`, version `v1alpha1`, `Namespaced`): one cloud
organization's resource hierarchy in a single XR — folder tree, accounts,
organization policies, org-wide audit logging and IAM grants at the top of the
tree. `models/` holds the KCL schemas generated from `xrd.yaml` by
`just xrd-schema organization`; do not edit them by hand. Import the composite
type as
`organization_xrd.models.v1alpha1.cloud_example_org_v1alpha1_organization`.

The XR picks its backend with a label:
`spec.crossplane.compositionSelector.matchLabels.provider: gcp | aws | azure`.
Create one XR per cloud organization; two XRs naming the same `orgId` fight
over the same objects. A field a backend cannot honour fails the render with a
message naming the alternative. The per-cloud map is in
[docs/organization.md](../../../../docs/organization.md).

Not here: service accounts and their grants (the `Identity` XR), per-account
networks/clusters/databases, billing accounts, creating the organization
itself and domain verification.

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `orgId` | string | ✓ | | Hierarchy root. gcp: numeric organization id; aws: Organizations root id (`r-…`); azure: parent management group name (tenant id for a whole tenant) |
| `billingAccount` | string | | | gcp: billing account linked to every project (required per project); ignored by aws and azure |
| `owner` | string | | | Default account owner email; aws needs one per account, gcp ignores it |
| `folders[]` | list | | | `{name, displayName?, parent?, deletionProtection (false)}`. gcp Folder / aws OU / azure Management Group. `name` is a lowercase RFC 1123 label ≤ 30; `parent` names another entry; `deletionProtection: true` is gcp-only |
| `projects[]` | list | | | `{name, displayName?, folder?, owner?, billingAccount?, services[]?, labels?, autoCreateNetwork (false), whenDeleted (delete)}`. gcp Project / aws Account; rejected by azure. `services` and `autoCreateNetwork: true` are gcp-only |
| `policies[]` | list | | | `{constraint, folder?, enforce?, allowedValues?, deniedValues?, allowAll?, denyAll?, inheritFromParent?, reset?, dryRun (false)}`. gcp Org Policy v2 / aws SCP + attachment / azure policy assignment; each backend rejects the shapes it cannot express |
| `auditLogging` | object | | | `{services ([allServices]), logTypes ([ADMIN_READ, DATA_READ, DATA_WRITE]), exemptedMembers?}`. gcp only; aws and azure reject it |
| `iamBindings[]` | list | | | `{member, role, folder?, condition?}`. gcp Organization/FolderIAMMember, azure RoleAssignment; aws rejects it; `condition` is gcp-only |
| `deletionPolicy` | `Delete` \| `Orphan` | | `Delete` | `Orphan` sets `managementPolicies` on every MR |
| `tags` | map | | | Merged under `projects[].labels`; GCP project labels, AWS OU and account tags; reaches nothing else |

Status: `ready` (every declared folder and account has a cloud id), `provider`,
`id` (hierarchy root), `folders[]` (`name`, `folderId`, `parent`),
`projects[]` (`name`, `projectId`, `number`), `folderCount`, `projectCount`,
`policyCount`, `cloud-url`. Printer columns: READY, PROVIDER, ORG, FOLDERS,
PROJECTS.

## Backends

| dir | Composition | composes |
| --- | --- | --- |
| [`../gcp/`](../gcp/) | `organization-gcp` | Folder, Project, ProjectService, orgpolicy Policy, OrganizationIAMAuditConfig, Organization/FolderIAMMember |
| [`../aws/`](../aws/) | `organization-aws` | OrganizationalUnit, Account, Policy (SCP), PolicyAttachment |
| [`../azure/`](../azure/) | `organization-azure` | ManagementGroup, ManagementGroupPolicyAssignment, RoleAssignment |

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | the `CompositeResourceDefinition` |
| `providers.yaml` | `provider-gcp-cloudplatform`, `provider-gcp-orgpolicy`, `provider-aws-organizations`, `provider-azure-management`, `provider-azure-authorization`. Versions match the schema packages from `just seed-organization-providers` |
| `functions.yaml` | `function-kcl` and `function-auto-ready`, pinned |
| `examples/organization-gcp.yaml` | `yurikrupnik`: 12 folders, 6 projects with services, 8 policies, org-wide audit logging, 2 grants |
| `examples/organization-aws.yaml` | `example-aws`: 3 OUs (one nested), 2 accounts, 2 SCPs (one sandbox-scoped) |
| `examples/organization-azure.yaml` | `contoso`: 4 management groups, 2 policy assignments (one `dryRun`), 2 role assignments |

There is no `providerconfigs.yaml`: every backend needs real cloud credentials
in a ProviderConfig of your own.

## Usage

```bash
just install-module organization     # xrd.yaml + every backend composition.yaml, repointed at the local registry
just e2e organization                # local cluster + registry, publish, install, providers, every example XR
kubectl -n default apply -f packages/cloud/organization/xrd/examples/organization-gcp.yaml
kubectl -n default get organization
```

These need a cluster (`just e2e` creates one with `devkit cluster create`) and,
to reconcile, cloud credentials. After changing `xrd.yaml`, regenerate
`models/` with `just xrd-schema organization`.

## Development

```bash
pnpm exec nx run organization-xrd:test     # kcl test
pnpm exec nx run organization-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
