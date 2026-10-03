# organization-aws

AWS backend for the `Organization` XR (`cloud.example.org/v1alpha1`,
Composition `organization-aws`, label `provider: aws`). Typed against the
`aws-organizations` schema package under
[packages/providers/](../../../providers/). It composes the AWS Organizations
hierarchy: an `OrganizationalUnit` per folder, an `Account` per project, and
per policy a service control `Policy` plus the `PolicyAttachment` binding it to
the root or an OU. `function-kcl` runs it from
`oci://docker.io/yurikrupnik/organization-aws`.

Not composed: the organization itself (`spec.orgId` names an existing root),
delegated administrators, IAM inside an account (the `Identity` XR) and
per-account infrastructure. See
[docs/organization.md](../../../../docs/organization.md).

## Second pass

`OrganizationalUnit.parentId`, `Account.parentId` and
`PolicyAttachment.targetId` have no ref or selector in the generated schemas.
`render(oxr, ocds)` reads the parent OU's observed id from
`ocds["folder-<parent>"]` and emits a nested OU, an account in an OU, or a
folder-scoped attachment only once that id is known; root-level nodes use
`spec.orgId` immediately. AWS does not re-parent on update, so nothing is
emitted with a guessed parent. `status.ready` reports when the tree is
complete.

## Composed resources

| composition-resource-name | resource (API group) | when | notes |
| --- | --- | --- | --- |
| `folder-<name>` | `OrganizationalUnit` (`organizations.aws.m.upbound.io`) | per `folders[]` whose parent is the root or observed | label `organization.cloud.example.org/folder: <name>` |
| `project-<name>` | `Account` | per `projects[]` whose folder is the root or observed | `email` = owner, `closeOnDeletion` from `whenDeleted` |
| `policy-<scope>-<slug>` | `Policy` | per `policies[]`, immediately | `SERVICE_CONTROL_POLICY`; label `organization.cloud.example.org/policy: <scope>-<slug>` |
| `attachment-<scope>-<slug>` | `PolicyAttachment` | per `policies[]` whose target is the root or observed | `policyIdSelector` on the policy label |

`<scope>` is `org` or `folder-<name>`; `<slug>` lowercases and replaces
`[^a-z0-9-]` with `-`. Renaming a composed resource deletes and recreates it.

SCP documents: `deniedValues` → one `Deny Action=[…]`; `allowedValues` →
`Allow Action=[…]` plus `Deny NotAction=[…]` (AWS's `FullAWSAccess` would
otherwise make a bare allow list a no-op). Resource is `*`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `orgId` | `parentId` / `targetId` of root-level nodes; `status.id` |
| `owner`, `projects[].owner` | `Account.email` (per-project wins; one is required) |
| `folders[].displayName`, `projects[].displayName` | `name` (default `name`) |
| `projects[].whenDeleted` | `closeOnDeletion: true` only for `delete` (default) |
| `tags` | OU `tags`; account `tags` merged with `projects[].labels` (labels win) |
| `policies[].constraint` | `Policy.forProvider.name` |
| `policies[].allowedValues` / `deniedValues` | SCP statements above |
| `deletionPolicy: Orphan` | `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |

Ignored: `billingAccount`, `projects[].billingAccount`. Rejected (render
fails): `auditLogging`, `iamBindings`, `projects[].services`,
`projects[].autoCreateNetwork: true`, `folders[].deletionProtection: true`;
on policies `enforce`, `allowAll`, `denyAll`, `inheritFromParent`, `reset`,
`dryRun: true`, or neither value list; duplicate folder/project names,
undeclared references, a cycle or more than 5 OU levels, an account with no
owner, the same constraint twice at one scope, and a `<scope>-<slug>` that is
not a valid label value (≤ 63 chars).

Status written back: `provider: aws`, `id: <orgId>`, `folders[]` (observed
`ou-…` id, `parentId`), `projects[]` (observed 12-digit account id, `number`
empty), counts, `cloud-url`; `ready` once every folder and account has an id.

## Usage

`kcl run` with no options renders the built-in `_example` XR — its account sits
in an OU that is not observed yet, so only the OU renders:

```bash
kcl run packages/cloud/organization/aws

# a real XR: root-level OUs, both SCPs and the root attachment
kcl run packages/cloud/organization/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/organization/xrd/examples/organization-aws.yaml)}"

# second pass: observed OU ids add the nested OU, the sandbox account and the sandbox attachment
kcl run packages/cloud/organization/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/organization/xrd/examples/organization-aws.yaml), \"ocds\": {\"folder-workloads\": {\"Resource\": {\"status\": {\"atProvider\": {\"id\": \"ou-ab12-workload\"}}}}, \"folder-sandbox\": {\"Resource\": {\"status\": {\"atProvider\": {\"id\": \"ou-ab12-sandbox1\"}}}}}}"
```

Output is `items:` — the managed resources, then the `Organization` carrying
status.

Through function-kcl (needs docker): `pnpm exec nx run organization-aws:render`.
On a cluster: `just install-module organization`, `just e2e organization`
(needs AWS credentials in a ProviderConfig of your own).

## Layout

| file | content |
| --- | --- |
| `main.k` | `option("params")` or `_example`; `items` = `render` + `status` |
| `organization.k` | `_policy_document`, `render(oxr, ocds)`, `status(oxr, ocds)` |
| `organization_test.k` | `kcl test` cases |
| `composition.yaml` | the `organization-aws` Composition: function-kcl then function-auto-ready |

## Development

```bash
pnpm exec nx run organization-aws:test     # kcl test
pnpm exec nx run organization-aws:lint     # kcl lint
pnpm exec nx run organization-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
