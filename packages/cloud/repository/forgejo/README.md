# repository-forgejo

The only backend for the `Repository` XR (`cloud.example.org/v1alpha1`,
namespaced): one git repository inside a Forgejo/Gitea forge that already
runs, e.g. one installed by a `Forge` XR ([`../../forge/forgejo/`](../../forge/forgejo/)).
Typed against the [`http`](../../../providers/http) provider schema package, it
drives Forgejo's REST API through provider-http `Request`s, each with
`CREATE`/`OBSERVE`/`UPDATE`/`REMOVE` mappings written as jq over
`.payload`. Run by `function-kcl` (`target: Default`) from
`oci://docker.io/yurikrupnik/repository-forgejo`, then `function-auto-ready`.

This is a paid capability gated by
[`entitlement`](../../../platform/entitlement): the first item is a
`meta.krm.kcl.dev/v1alpha1` `RequiredResources` request for the cluster-scoped
`Entitlement` named after the XR's namespace, and nothing is composed until it
is fetched and grants the feature `repository`. `target: Default` is required
for function-kcl to dispatch that meta-kind.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `RequiredResources` (`meta.krm.kcl.dev`) | | always | Fetches `Entitlement/<namespace>`; not a composed resource |
| `ProviderConfig` (`http.m.crossplane.io`) | `providerconfig` | entitled | Explicit `metadata.name` = XR name; reads key `authorization` of Secret `spec.forge.secretRef` in the XR's namespace |
| `Request` (`http.m.crossplane.io`) | `organization` | `createOrganization: true` | `POST /orgs`, `GET`/`PATCH`/`DELETE /orgs/<owner>` |
| `Request` (`http.m.crossplane.io`) | `repository` | entitled | `POST /orgs/<owner>/repos`, `GET`/`PATCH`/`DELETE /repos/<owner>/<name>` |
| `Request` (`http.m.crossplane.io`) | `webhook` | `webhook.url` set | Type `forgejo`, `content_type: json`; all mappings target `/repos/<owner>/<name>/hooks` |

Every `Request` uses the XR's `ProviderConfig`, sends `Content-Type:
application/json` and carries the desired object as a JSON string in
`payload.body`. `deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize` on every `Request`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to | notes |
| --- | --- | --- |
| `forge.baseUrl` | `payload.baseUrl` | API root incl. `/api/v1`, e.g. a Forge's `status.apiUrl` |
| `forge.secretRef` | `ProviderConfig` credentials | value must be `token <PAT>` (or `Basic …`) |
| `owner` | URL owner segment; org `username` | required |
| `name` | repo `name` | default: XR name |
| `description` | `description` | mutable |
| `private` | `private` | default true; needs plan `team` or better |
| `defaultBranch` | `default_branch` | default `main`; mutable |
| `autoInit`, `template`, `gitignores`, `license`, `readme` | create body only | `autoInit` default true, `template` default false |
| `createOrganization` | `organization` Request | the XR then owns (and deletes) the org |
| `organization.fullName` / `visibility` / `description` / `website` | org payload | `fullName` defaults to `owner`, `visibility` to `private`; only `username`, `full_name`, `visibility` are sent on create, `full_name`, `visibility` on update |
| `webhook.url` / `events` / `active` | `webhook` Request | `events` default `["push"]`, `active` default true |
| `deletionPolicy` | `managementPolicies` | |

UPDATE bodies carry only `description`, `private`, `default_branch`, fields
Forgejo echoes on GET, so provider-http's default sync check holds.
`webhook.secretRef` is not read by this backend. The repository quota check
passes `used = 1` per XR (`ent.within_quota(gate, "repositories", 1, 1)`); the
function sees one XR at a time.

Status written back: `ready` (the `repository` Request's `Ready` condition),
`fullName` (`<owner>/<name>`, before the forge answers), `cloneUrl`, `sshUrl`,
`htmlUrl` (decoded from the observed `status.response.body`, empty if absent
or unparsable), `plan`.

## Usage

Without `option("params")`, `main.k` renders a built-in example (`platform`
in `tenant-a`, owner `acme`, private) with an entitled `team` record. Without
`requiredResources` the render is the pending request only:

```bash
kcl run packages/cloud/repository/forgejo
# pending: RequiredResources only
kcl run packages/cloud/repository/forgejo -D 'params={"oxr":{"metadata":{"name":"platform","namespace":"tenant-a"},"spec":{"forge":{"baseUrl":"http://git-http.tenant-a.svc:3000/api/v1","secretRef":"forge-token"},"owner":"acme"}}}'
# entitled, with organization and webhook Requests
kcl run packages/cloud/repository/forgejo -D 'params={"oxr":{"metadata":{"name":"platform","namespace":"tenant-a"},"spec":{"forge":{"baseUrl":"http://git-http.tenant-a.svc:3000/api/v1","secretRef":"forge-token"},"owner":"acme","createOrganization":true,"webhook":{"url":"https://ci.example.org/hook"}}},"requiredResources":{"entitlement":[{"Resource":{"metadata":{"name":"tenant-a"},"spec":{"plan":"team","features":["repository"],"quota":{"repositories":50}}}}]}}'
```

On a `free` plan a private repository (the default) fails the render with
`spec.private requires plan 'team' or better`. Local `kcl run` output also
contains the module's public `auth_key` and `webhook_type` next to `items`.

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/repository-forgejo.yaml`](../xrd/examples/repository-forgejo.yaml)
and the mocked record in
[`../xrd/required-resources/entitlement.yaml`](../xrd/required-resources/entitlement.yaml):

```bash
pnpm exec nx run repository-forgejo:render
```

On a cluster: `just install-module repository` or `just e2e repository`.
The provider is provider-http ([`../xrd/providers.yaml`](../xrd/providers.yaml));
no cluster-wide ProviderConfig is needed. Delete Repositories before their
Forge (or set `deletionPolicy: Orphan` first): a Repository whose forge is gone
cannot finish its DELETE call and keeps its finalizer.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: entitlement request, gate, then `render` + `status` |
| `repository.k` | `render` (ProviderConfig + Requests), `status`, mapping helpers |
| `repository_test.k` | `kcl test` cases: defaults, mappings, org, webhook, policies, plan gate, status |
| `composition.yaml` | `repository-forgejo` Composition, label `provider: forgejo` |

## Development

```bash
pnpm exec nx run repository-forgejo:test     # kcl test
pnpm exec nx run repository-forgejo:lint     # kcl lint
pnpm exec nx run repository-forgejo:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
