# fleet

The app of apps of one cluster, typed. One values file lists what the platform
team owns and what each application team owns; the render is one `Component` XR
(`platform.example.org/v1alpha1`, [xrd](../platform/component/xrd/xrd.yaml)) per
app plus the team Namespaces. A Component is one Flux source plus one
Kustomization or HelmRelease, so the cluster needs Crossplane with the Component
XRD and Composition (`just install-module component`) and Flux. Nothing here
installs itself.

```
values.yaml ──► fleet.render ──► [Namespace…, Component…] ──► Flux ──► cluster
```

Two layers: `platform` apps render first; every `teams[].apps` entry by default
`dependsOn` every platform app (`waitForPlatform`), so Flux holds the whole
application layer until the platform layer is Ready.

## Usage

`-D values=<path>` (like `helm -f`), or `values.yaml` in the current directory.
`-D env=<name>` deep-merges `<stem>.<name>.yaml` over it (maps merge, scalars
and lists replace, so an overlay restates any layer it changes). The merged
result is validated against the `Fleet` schema. With no values file the package
renders a built-in demo (one platform app, one team).

```bash
kcl run packages/fleet -D values=packages/fleet/examples/values.yaml -q
kcl run packages/fleet -D values=packages/fleet/examples/values.yaml -D env=prod -q

just fleet                                            # examples/values.yaml
just fleet packages/fleet/examples/values.yaml prod   # same, with the overlay
```

Applying in one pass is fine: ordering is `dependsOn` on the composed Flux
objects, not apply order. Every object carries `platform.example.org/layer`, so
one layer can be applied at a time (needs a cluster):

```bash
kcl run packages/fleet -D values=packages/fleet/examples/values.yaml -q \
  | kubectl apply -l platform.example.org/layer=platform -f -
```

From the published package: `kcl run oci://docker.io/yurikrupnik/fleet -D values=… -q`.
In code: `import fleet.lib as fleet; fleet.render(fleet.Fleet {**values})`.

## Inputs

`Fleet`:

| key | default | meaning |
| --- | --- | --- |
| `name` | `fleet` | `app.kubernetes.io/part-of` on everything |
| `namespace` | `flux-system` | Where every Component XR is created. One namespace for the tree because `Component.spec.dependsOn` only reaches siblings in the same namespace |
| `platform` | `[]` | `App` list; a platform app may only depend on other platform apps |
| `teams` | `[]` | `Team` list; names unique |
| `waitForPlatform` | `true` | Every team app depends on every platform app; an app opts out with `waitForPlatform: false` |

`Team`: `name`, `namespace` (where its apps' workloads land), `createNamespace`
(`true`), `labels` (added to the Namespace and every Component of the team),
`apps` (non-empty, names unique).

`App` (one Component; `name` unique across the whole fleet):

| key | default | meaning |
| --- | --- | --- |
| `name` | required | XR name, Flux object name, `dependsOn` handle |
| `engine` | required | `helm` → HelmRelease; `kustomize` → Kustomization of plain YAML; `crossplane` → Kustomization of Crossplane claims/XRs |
| `source` | required | `url` (no trailing `/`), `kind` (derived: helm → `HelmRepository`, else `OCIRepository` for `oci://`, else `GitRepository`; set `OCIRepository` for a helm chart that is an OCI artifact), `tag` / `branch` / `semver` / `digest`, `interval` (`1m`), `insecure` (plain-HTTP OCI only), `secretRef` (existing Secret, never rendered) |
| `chart`, `version` | | helm from a Helm repository only; `chart` required there, forbidden for an OCI-artifact chart |
| `values` | `{}` | helm only; → `HelmRelease.spec.values` |
| `path` | `./` | kustomize / crossplane: directory inside the source |
| `targetNamespace` | team namespace | Where the workload lands |
| `dependsOn` | `[]` | Other app names in this file |
| `waitForPlatform` | `Fleet.waitForPlatform` | Per-app override of the platform barrier |
| `interval`, `timeout` | `5m`, `5m` | Delivery object reconcile interval and per-apply timeout |
| `prune`, `wait` | `true`, `true` | Kustomization only |
| `suspend` | `false` | Stop reconciling; the source keeps fetching |
| `serviceAccount` | | ServiceAccount in `namespace` the Flux controller impersonates |
| `labels` | `{}` | Extra labels on the Component |

The `App` checks reject source/engine mismatches (a HelmRepository behind a
kustomize app, `branch` on OCI, `digest` on Git, `insecure` off OCI, wrong URL
scheme per source kind) at `kcl run` time.

## Outputs

In order: a `Namespace` per team with `createNamespace: true`, the platform
layer's `Component`s, then each team's `Component`s in file order. Labels:
`app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by: fleet`,
`platform.example.org/layer` (`platform` / `application`),
`platform.example.org/team` (team apps), `platform.example.org/engine`.
`Component.spec` carries `source`, `deliver` (`kind: HelmRelease` or
`Kustomization`, plus `targetNamespace`), `interval`, and `dependsOn` /
`suspend` / `serviceAccountName` when set.

## Examples

| file | content |
| --- | --- |
| `examples/values.yaml` | Platform layer (crossplane chart, `platform-apis` crossplane artifact, `policy` from Git) and two teams: `web` (nginx chart, `web-api` kustomize from Git with `serviceAccount`), `data` (`data-resources` crossplane artifact on a semver range, `cnpg` chart into `cnpg-system`). Default for `just fleet` |
| `examples/values.prod.yaml` | `-D env=prod`: `name: platform-prod`, only the `web` team, `web-api` from a tagged public OCI artifact |

## Layout

| file | content |
| --- | --- |
| `main.k` | values file + env overlay loading (own deep merge, no dependency on `app`), demo fallback, `render` to a YAML stream |
| `lib.k` | `Fleet`, `Team`, `App`, `Source` schemas and checks, the Component and Namespace renderers |
| `fleet_test.k` | `kcl test` cases for order and identity, the platform barrier, each engine, the example file |

## Development

```bash
pnpm exec nx run fleet:test     # kcl test
pnpm exec nx run fleet:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
