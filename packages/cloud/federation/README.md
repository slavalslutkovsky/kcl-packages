# federation

Keyless access for CI pipelines (git clients) and the ticket systems that start
them, as data. A library, not a Composition: cloud backends import it
(`import federation.lib as fed`, path dependency `federation = { path = "../../federation" }`)
and turn the same entry into their own IAM. Used by
[`bucket`](../bucket/xrd/README.md) `spec.access`.

```yaml
- client: github            # or customClient: {id, label, issuer, ...}
  owner: acme               # org / group / workspace / organization id
  repositories: [acme/app]  # owner/name, group/project, {uuid}
  workflows: [acme/ops/.github/workflows/jira.yml@refs/heads/main]
  ticket: jira              # or customTicket: {id, label, triggers}
  subjects: [...]           # exact token subjects
  audiences: [...]          # token aud; per-cloud defaults below
  condition: "..."          # extra CEL (GCP)
  role: write               # Access only: read | write | admin
```

## Git clients (`client`)

| client | issuer | owner | repositories | ticket trigger claim | AWS sub patterns | default aud (aws / azure) |
| --- | --- | --- | --- | --- | --- | --- |
| `github` | `https://token.actions.githubusercontent.com` | `assertion.repository_owner` | `attribute.repository` | `event_name` | `repo:<owner>/*`, `repo:<repo>:*` | `sts.amazonaws.com` / `api://AzureADTokenExchange` |
| `github-enterprise` | `https://{host}/_services/token` | same | same | `event_name` | same | same |
| `gitlab` | `https://{host}`, host default `gitlab.com` | `assertion.namespace_path` | `attribute.project_path` | `pipeline_source` | `project_path:<owner>/*`, `project_path:<repo>:*` | none — set `audiences` |
| `bitbucket` | `https://api.bitbucket.org/2.0/workspaces/{owner}/pipelines-config/identity/oidc` | workspace (issuer) | `attribute.repository_uuid` | none | `*`, `<uuid>:*` | none — set `audiences` (`ari:cloud:bitbucket::workspace/<uuid>`) |
| `azure-devops` | `https://vstoken.dev.azure.com/{owner}` (organization id) | organization (issuer) | — | none | `subjects` only | `api://AzureADTokenExchange` |

## Ticket systems (`ticket`)

None mints a token a cloud accepts (Jira Cloud's Forge Invocation Token has
issuer `forge/invocation-token`, not an https issuer). They start a git client
run through its dispatch/trigger API, so a ticket entry is a git client entry
narrowed to those runs, in its own GCP pool (`<ticket>-<client>`).

| ticket | trigger values |
| --- | --- |
| `jira`, `clickup`, `monday`, `asana`, `trello`, `linear`, `shortcut`, `youtrack`, `servicenow`, `zendesk`, `azure-boards` | GitHub `repository_dispatch`, `workflow_dispatch`; GitLab `trigger`, `api` |
| `github-issues` | GitHub `issues`, `issue_comment` |

Every external system arrives through the same API: two ticket entries are
rejected unless something in the token separates them (issuer, triggers,
`workflows`, `repositories`, `subjects` or a `condition`). A pool proves which
workflow ran from a dispatch, not who sent it; give each system its own
dispatch token.

## Per cloud

| function | result |
| --- | --- |
| `expand(entries)` | GCP Fabric-shaped `workloadIdentityPools` map: pool → provider with issuer, mapping and CEL condition (owner, repositories, subjects, ticket trigger, workflows, condition) |
| `gcp_members(entry, projectNumber)` | IAM members naming that pool: `principal://…/subject/<sub>` per subject, else `principalSet://…/attribute.<attr>/<repo>` per repository, else `principalSet://…/<pool>/*` |
| `aws_trust(entry, accountId)` | role trust policy: `Federated` = `arn:aws:iam::<account>:oidc-provider/<issuer host>` (must exist), `StringEquals <host>:aud`, `StringLike <host>:sub` |
| `azure_subjects(entry)` | the exact subjects of the federated credentials (required, ≤ 20) |
| `access_list(entries)` | validated `Access` entries (each a Binding + `role`) |
| `access_name(entry)` | stable name for composed resources: pool id [+ `-<provider>`] |

AWS and Azure trust only the token's `sub` and `aud`. A `ticket`, `workflows`
or `condition` is not in GitHub's default sub claim, so on AWS such an entry
fails unless it lists `subjects` from a customized sub claim
(`PUT /repos/{owner}/{repo}/actions/oidc/customization/sub`); Azure always
needs `subjects` because credentials match exactly.

Rejected for every cloud: a shared issuer (`github`, `gitlab.com`) with no
owner, repositories, subjects, workflows or condition; Bitbucket without
`audiences`; a missing `host` / `owner` the issuer needs; quotes or
backslashes in values spliced into CEL; duplicate pool/provider pairs; ids or
display names GCP refuses; ticket entries that admit the same tokens.

## Usage

```bash
kcl run packages/cloud/federation/main.k     # a demo list on gcp, aws and azure
kcl run packages/cloud/federation/main.k -D access='[{"client": "gitlab", "owner": "acme", "audiences": ["sts.amazonaws.com"]}]'
cd packages/cloud/federation && kcl test
```
