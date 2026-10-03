# gitops

GitOps for a self-hosted forge from one values file. It renders the tenant
Namespace, its cluster-scoped `Entitlement`, a `Forge` XR (Forgejo via
provider-helm), one `Repository` XR per repository to create inside the forge,
and the engine pair that reconciles the cluster from a seed repository: Flux
`GitRepository` + `Kustomization`, or Argo CD `AppProject` + `Application`.
After the history is pushed into the forge, `source.origin: forge` points the
same engine at the in-cluster clone instead of GitHub.

The loop:

1. The engine reads the cluster state from the seed repo (`source.origin: github`).
2. That state includes the Namespace, Entitlement and Forge rendered here.
3. The Repository XRs create **empty** repositories in the forge over its REST
   API (`autoInit: false`). Nothing mirrors git history.
4. A human `git push`es the history into the forge, then sets
   `source.origin: forge` (the `forge` overlay).

The Entitlement rules the Forge and Repository Compositions enforce in the
cluster are restated as schema checks, so a values file the tenant is not
entitled to fails on `kcl run`.

## Usage

`-D values=<path>` (like `helm -f`), or `values.yaml` in the current directory.
`-D env=<name>` deep-merges `<stem>.<name>.yaml` over it (right wins; lists
replace). The merged result is validated against the `Gitops` schema. With no
values file the package renders a built-in demo.

```bash
kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -q
kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -D env=forge -q
kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -D env=argocd -q

just gitops                                               # examples/values.yaml
just gitops packages/gitops/examples/values.yaml forge    # same, with the overlay
```

From the published package: `kcl run oci://docker.io/yurikrupnik/gitops -D values=… -q`.
In code: `import gitops.lib as gitops; gitops.render(gitops.Gitops {**values})`.

The stream is in apply order, but a bare cluster needs two passes: `Entitlement`
([crd](../platform/entitlement/crd.yaml)), `Forge`
([xrd](../cloud/forge/xrd/xrd.yaml)) and `Repository`
([xrd](../cloud/repository/xrd/xrd.yaml)) need Crossplane and
`just install-module forge` / `just install-module repository`, and the engine
(Flux or Argo CD) must already run. Credentials are referenced, never rendered;
`examples/values.yaml` shows the `kubectl create secret` commands.

## Inputs

`Gitops`:

| key | default | meaning |
| --- | --- | --- |
| `name` | `gitops` | Engine object names; `app.kubernetes.io/part-of` on everything |
| `engine` | `flux` | `flux` or `argocd`; must already run on the cluster |
| `namespace` | `argocd` for argocd, else `flux-system` | Where the engine objects live |
| `tenant` | required | `namespace` (the tenant; Entitlement name), `plan` (`free` / `team` / `enterprise`, default `team`), `features` (must include `forgejo` and `repository`), `quota.storageGb` (`50`), `quota.repositories` (`50`), `reference`, `createNamespace` (`true`), `manageEntitlement` (`true`; false when billing writes it) |
| `source` | required | `origin` (`github` / `forge`), `url` (required for `github`, kept after the switch), `branch` (`main`), `path` (`./clusters/dev`), `repository` (the `repositories` entry `forge` follows), `prune` (`true`); Flux only: `interval` (`1m`), `reconcileInterval` (`10m`), `secretRef`, `wait` (`true`), `timeout` (`5m`) |
| `forge` | required | `name` (`git`; XR, release and Service prefix), `hostname` (required), `storageGb` (`10`), `database` (`sqlite` / `postgres` with `host`, `name`, `user`, `passwordSecret`), `ingress` (`enabled`, `className`, `tlsSecretName`), `highAvailability`, `chartVersion`, `imageTag`, `adminSecret`, `deletionPolicy` (`Delete`), `values` (raw chart values), `tokenSecret` (`forge-token`: Secret with key `authorization` = `token <PAT>`) |
| `repositories` | `[]` | `name`, `owner`, `description`, `private` (`true`), `defaultBranch` (`main`), `autoInit` (`false`), `license` / `gitignores` / `readme` (autoInit only), `createOrganization` (`false`) + `organization`, `webhook`, `deletionPolicy` (`Orphan`) |

Cross-field checks: `source.secretRef` is rejected with `engine: argocd` (Argo CD
matches credentials by repository URL); repository count and `forge.storageGb`
stay within the tenant quota; private repositories need plan `team` or
`enterprise`; `forge.highAvailability` needs plan `enterprise` and
`database.mode: postgres`; `source.repository` must name a `repositories` entry.

## Outputs

In order:

| kind | when | notes |
| --- | --- | --- |
| `Namespace` `<tenant.namespace>` | `tenant.createNamespace` | |
| `Entitlement` (`platform.example.org/v1alpha1`) | `tenant.manageEntitlement` | Cluster-scoped, named after the tenant namespace |
| `Forge` (`cloud.example.org/v1alpha1`) | always | In the tenant namespace |
| `Repository` (`cloud.example.org/v1alpha1`) | per `repositories` entry | `forge.baseUrl` = `http://<forge.name>-http.<tenant.namespace>.svc:3000/api/v1`, `forge.secretRef` = `forge.tokenSecret` |
| `GitRepository` + `Kustomization` | `engine: flux` | URL is `source.url`, or `http://<forge.name>-http.<tenant>.svc:3000/<owner>/<name>.git` on `origin: forge` |
| `AppProject` + `Application` | `engine: argocd` | Project admits only that one URL; automated sync with `selfHeal`; cascade finalizer when `prune` |

## Examples

| file | content |
| --- | --- |
| `examples/values.yaml` | Loop for `github.com/yurikrupnik-org/gitops`: tenant `platform`, sqlite Forgejo at `git.yurikrupnik.com`, repositories `gitops` and `kcl-packages`. Default for `just gitops` |
| `examples/values.forge.yaml` | `-D env=forge`: `source.origin: forge`, `secretRef: forge-auth` |
| `examples/values.argocd.yaml` | `-D env=argocd`: `engine: argocd`, `namespace: argocd`, `secretRef` dropped |

## Layout

| file | content |
| --- | --- |
| `main.k` | values file + env overlay loading, demo fallback, `render` to a YAML stream |
| `lib.k` | Schemas and entitlement checks, URL helpers (`serviceHost`, `apiUrl`, `cloneUrl`, `sourceUrl`), renderers for every kind |
| `gitops_test.k` | `kcl test` cases for order, opt-outs, Entitlement, Forge, Repository, both origins, both engines, URLs |

## Development

```bash
pnpm exec nx run gitops:test     # kcl test
pnpm exec nx run gitops:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
