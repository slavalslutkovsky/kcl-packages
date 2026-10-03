# manager

The cluster around the workloads, from one values file per cluster: the
platform charts as Flux `HelmRepository` + `HelmRelease` pairs, cert-manager
issuers, cluster-scope Chaos Mesh experiments and Workflows, and the
cluster's Backstage entities. `app`'s sibling with the same contract: the
values are a typed `Manager` (`lib.k`), overlays deep-merge, and the chaos
objects are built by `app`'s own `Fault` schema and renderers, so a fault means
the same thing in both packages. Flux (source-controller + helm-controller)
must already be on the cluster.

## Usage

```bash
# manager cluster: every dependency
kcl run packages/manager -D values=packages/manager/examples/values.yaml -q | kubectl apply -f -

# workload cluster: the values.workload.yaml overlay sets role: workload
kcl run packages/manager -D values=packages/manager/examples/values.yaml -D env=workload -q

# Backstage entities of the `catalog:` block instead of the manifests
kcl run packages/manager -D values=packages/manager/examples/values.yaml -D catalog=true -q > catalog-info.yaml
```

The same through `just` (values default to `packages/manager/examples/values.yaml`):

```bash
just manager [values.yaml] [env]
just manager-catalog [values.yaml] [env]
just manager-phase <manager|application> [values.yaml] [env]   # yq-filter on platform.example.org/type
```

`manager-phase` keeps only objects labelled with that type: HelmRepositories,
HelmReleases and issuers. Namespaces and chaos objects carry no type label and
drop out.

From the published package: `kcl run oci://docker.io/yurikrupnik/manager --tag <version> -D values=… -q`.

| option | default | meaning |
| --- | --- | --- |
| `values` | `values.yaml` in the current directory | Base values file, CWD-relative. An explicit path that does not exist fails the render |
| `env` | `""` | Overlay `<stem>.<env>.yaml` next to the base; must exist when set. Maps merge recursively, lists replace, so an overlay can set `chaos: {experiments: []}` or `chaos: {paused: true}` |
| `catalog` | `false` | `true` / `1` / `yes` renders the Backstage entities; fails without a `catalog:` block |

Without `-D values` and with no `values.yaml` in the current directory, a
built-in demo renders (one chaos-mesh HelmRepository + HelmRelease, one
PodChaos), so a bare `kcl run packages/manager` from the repo root still
smoke-tests the package.

The charts install the CRDs the issuers and chaos objects are instances of, so
a bare cluster takes the render in two passes: Namespaces + HelmRepository +
HelmRelease first, wait for every HelmRelease Ready, then the whole stream
again. `just e2e-manager [manager|workload]` does that on its own Kind cluster
`kcl-manager` (Flux from `manifests/manager/devkit.toml`) and checks the role's
promise; needs docker. See [docs/devkit.md](../../docs/devkit.md).

A chart must have one owner: do not list one here and in a `devkit.toml`
`[[deps]]` for the same cluster.

## Inputs

`Manager` (`lib.k`):

| key | default | meaning |
| --- | --- | --- |
| `name` | `manager` | `app.kubernetes.io/part-of` on the Flux objects; default catalog entity name |
| `role` | required | `manager` renders every dependency; `workload` only `type: application` ones |
| `namespace` | `flux-system` | Where the HelmRepository / HelmRelease objects live |
| `dependencies` | `[]` | `Dependency` rows, one chart each (below) |
| `issuers` | `[]` | cert-manager issuers: `acme` (needs `email` + `solvers`, http01 or dns01 via `cloud-dns` / `route53` / `azure-dns`), `self-signed`, `ca` (`caSecret`). ClusterIssuer unless `namespace` is set |
| `chaos` | — | `namespace` (`chaos-mesh`), `paused`, `namespaces` (labelled `chaos-mesh.org/inject=enabled`), `experiments` (an `app.Fault` + a required `target`), `workflows` (serial or `parallel` steps under one `deadline`, optional `pauseBetween`) |
| `catalog` | — | Backstage cluster Resource; `owner` required |

`Dependency`:

| field | default | meaning |
| --- | --- | --- |
| `name` | required | HelmRepository, HelmRelease and Helm release name |
| `type` | required | `manager` (manager clusters only) or `application` (every cluster that runs apps); becomes label `platform.example.org/type` |
| `repo` | required | `http(s)://` chart index or `oci://` registry (`oci://` → `type: oci`) |
| `chart` | `name` | Chart name |
| `version` | latest | Chart version |
| `namespace` | `name` | `targetNamespace`, created on install |
| `values`, `valuesFrom` | — | `HelmRelease.spec.values` / `valuesFrom` |
| `dependsOn` | `[]` | Other dependencies in this file → `HelmRelease.spec.dependsOn` |
| `interval`, `timeout` | `10m` | HelmRelease interval / timeout; `interval` also on the HelmRepository |
| `install`, `upgrade`, `driftDetection`, `postRenderers` | — | HelmRelease.spec fields as typed by the Flux CRD schemas; `install` deep-merges over `createNamespace: true`, `remediation.retries: 3` |
| `secretRef`, `provider` | — | HelmRepository.spec auth; `provider` (`aws` / `azure` / `gcp`) only for `oci://` |

Rejected at render time: duplicate dependency or issuer names, a `dependsOn`
naming nothing in the file, and an `application` dependency depending on a
`manager` one (it must install on a workload cluster, where manager
dependencies are absent). Chaos section by section:
[docs/chaos.md](../../docs/chaos.md#the-manager-package).

## Outputs

In apply order:

1. `Namespace` per `chaos.namespaces`
2. `HelmRepository` (`source.toolkit.fluxcd.io/v1`) per installed dependency
3. `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) per installed dependency
4. `ClusterIssuer` / `Issuer` (`cert-manager.io/v1`). They take the
   `cert-manager` dependency's `type`, so they render wherever that chart does;
   with no cert-manager row, on manager clusters only
5. Chaos Mesh experiments or `Schedule`s per `chaos.experiments`, with
   `experiment.chaos-mesh.org/pause: "true"` when `chaos.paused`
6. `Workflow` per `chaos.workflows`

With `-D catalog=true`: `backstage.io/v1alpha1` `Resource`s — the cluster
(`kubernetes-cluster`) and one per Workflow (`chaos-workflow`). Not Kubernetes
objects; see [docs/backstage.md](../../docs/backstage.md).

The dependency graph of the example values is drawn in
[docs/install-graph.md](../../docs/install-graph.md) (`just graph`).

## Examples

| file | renders |
| --- | --- |
| `examples/values.yaml` | `role: manager`: crossplane (`manager`), cert-manager, chaos-mesh, keda, kube-prometheus-stack, backstage (`application`); four ClusterIssuers (two ACME, self-signed root, CA); cluster-scope experiments; two Workflows; `catalog:` |
| `examples/values.workload.yaml` | Overlay setting `role: workload`: crossplane drops out, the application charts and issuers stay |

## Layout

| file | content |
| --- | --- |
| `main.k` | Values / overlay / catalog options, demo fallback, stream output |
| `lib.k` | `Manager`, `Dependency`, `Issuer`, `Solver`, `Target`, `Experiment`, `Step`, `Workflow`, `Chaos`, `Catalog`; Flux, issuer, chaos and entity renderers |
| `manager_test.k` | `kcl test` cases |
| `examples/` | Values file and the workload overlay |

## Development

```bash
pnpm exec nx run manager:test     # kcl test
pnpm exec nx run manager:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
