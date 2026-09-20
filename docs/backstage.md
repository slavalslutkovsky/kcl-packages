# Backstage

Two layers, one values file each — the same files that render the manifests:

- **`app`** — a `Release` carries a `catalog:` block, and the release becomes a
  Backstage **Component** plus one **API** entity per declared api. Owner,
  lifecycle and relations are authored; the id, namespace, archetype and chaos
  summary are derived from the workload, so the portal cannot describe a
  different app than the cluster runs.
- **`manager`** — the cluster around the workloads: a **Resource** of type
  `kubernetes-cluster` annotated with the charts Flux keeps installed and the
  cluster-scope experiments, plus one Resource of type `chaos-workflow` per game
  day. See [Chaos in the portal](#chaos-in-the-portal).

```
just catalog packages/app/examples/values-backend.yaml     > catalog/zerg-api.yaml
just manager-catalog                                       > catalog/platform.yaml
```

Or directly, with the same `-D env=<env>` overlay as the manifest render:

```
kcl run packages/app     -D values=<file> -D catalog=true -q
kcl run packages/manager -D values=<file> -D catalog=true -q
```

**A Backstage entity is not a Kubernetes object.** `backstage.io/v1alpha1` is
not an API the cluster serves, which is why `-D catalog=true` is a second
render and not extra items in the manifest stream: nothing here may ever reach
`kubectl apply`. `test_catalog_absent` in both packages pins that.

## What renders to what

| values | entity | `spec.type` | notes |
|---|---|---|---|
| `app` `workload:` + `catalog:` | Component | `service` | the default; `catalog.type` overrides it |
| `app` `task:` + `catalog:` | Component | `cronjob` / `job` | `job` without `task.schedule` |
| `app` `catalog.apis[]` | API | `openapi` (default), `asyncapi`, `graphql`, `grpc` | auto-added to the Component's `providesApis` |
| `manager` `catalog:` | Resource | `kubernetes-cluster` | one per values file |
| `manager` `chaos.workflows[]` | Resource | `chaos-workflow` | one per game day, `dependsOn` the cluster |

Derived, never hand-written — a values file cannot lie about what it renders:

| field | source |
|---|---|
| `metadata.name` | the workload's / task's name, or the Manager's `name` |
| `backstage.io/kubernetes-id` | the same, and the label on every rendered object |
| `backstage.io/kubernetes-namespace` | the workload's `namespace` (the chaos namespace for a game day) |
| `spec.system` | `catalog.system`, else the workload's `partOf` |
| `platform.example.org/chaos-faults` | the `chaos:` list, as `<name>=<type>` pairs |
| `platform.example.org/chaos-experiments` | `manager` `chaos.experiments`, same shape |
| `platform.example.org/chaos-steps` | a Workflow's steps, same shape |
| `platform.example.org/chaos-target` | a Workflow's target namespaces |
| `platform.example.org/charts` | the charts this cluster's `role` actually installs, as `<chart>=<type>` |
| `platform.example.org/cluster-role` | the Manager's `role` |
| a game day's `description` | `"<n> chaos faults in series\|parallel, <deadline> deadline, against <namespaces>"` |

`catalog.annotations` is merged **over** the derived set, so a values file can
override the id (e.g. to swap it for `backstage.io/kubernetes-label-selector`)
without the renderer growing a flag for it.

Only `catalog.owner` is required: Backstage rejects an ownerless entity. Entity
names and tags are validated at render time (`[A-Za-z0-9._-]` for names,
lowercase `[a-z0-9+#-]` for tags) rather than at catalog import, where the error
is a red banner in a web UI.

## The id contract

One string links the portal to the cluster: the entity is annotated
`backstage.io/kubernetes-id`, and **every object the same values file renders
carries the matching label**. That is what makes the component page's Kubernetes
tab show this release and nothing else.

Objects labelled by `app`: Deployment (and its pod template), Service,
HorizontalPodAutoscaler, KEDA ScaledObject, every Chaos Mesh experiment and
Schedule, Job / CronJob. By `manager`: every experiment, Schedule and Workflow.

The label is **not** in a Deployment's `selector.matchLabels`, which stays
`app: <name>` alone — a selector is immutable, and this label has to stay free
to change. It *is* on the pod template, so the plugin resolves pods too; adding
it to an existing release therefore rolls the Deployment once.

It is emitted unconditionally, with or without a `catalog:` block: a label is
free, and a cluster where only half the objects are discoverable is worse than
either extreme.

## Chaos in the portal

Chaos engineering already works end to end ([docs/chaos.md](chaos.md)); what
Backstage adds is somewhere to see it. Two mechanisms, no new fault machinery:

1. **Without cluster access** — the annotations above. `chaos-faults` on a
   component, `chaos-experiments` on a cluster, `chaos-steps` +
   `chaos-target` on a game day. A portal plugin, a table in a README or
   `yq` can read what is aimed at what.
2. **With cluster access** — the Chaos Mesh objects carry the component's (or
   the game day's) id, so the Kubernetes plugin lists them next to the
   Deployment once the custom resources are declared in `app-config.yaml`:

```yaml
kubernetes:
  serviceLocatorMethod: {type: multiTenant}
  clusterLocatorMethods:
    - type: config
      clusters:
        - name: platform-manager
          url: https://kubernetes.default.svc
          authProvider: serviceAccount
  customResources:
    - {group: chaos-mesh.org, apiVersion: v1alpha1, plural: podchaos}
    - {group: chaos-mesh.org, apiVersion: v1alpha1, plural: networkchaos}
    - {group: chaos-mesh.org, apiVersion: v1alpha1, plural: stresschaos}
    - {group: chaos-mesh.org, apiVersion: v1alpha1, plural: schedules}
    - {group: chaos-mesh.org, apiVersion: v1alpha1, plural: workflows}
    - {group: keda.sh, apiVersion: v1alpha1, plural: scaledobjects}
```

The four kinds `app` renders and the two more `manager` adds are exactly the
ones listed there; the other 17 Chaos Mesh kinds are unreachable from a values
file on purpose (docs/chaos.md § What renders to what).

`catalog.dashboardUrl` in a `manager` values file links the Chaos Mesh
dashboard from the cluster and from every game day. It is off by default —
`devkit.toml` sets `dashboard.create=false` (docs/chaos.md § Dashboard).

## Crossplane in the portal

63 Composition packages, 25 XRDs and 69 example XRs are not something a values
file renders: a Composition's output *is* Kubernetes objects, so a catalog entity
cannot ride along with it. They are **scanned** instead — `just
crossplane-catalog` runs `tools/catalog` over `packages/**` and writes two
committed artifacts, `catalog/crossplane.yaml` (the entities) and
[docs/crossplane-graph.md](crossplane-graph.md) (the graph, the usage table, the
findings table). `just crossplane-catalog-check` fails when either is stale,
which is what CI runs; nothing is generated at read time.

| source | entity | `spec.type` | notes |
|---|---|---|---|
| the estate | Domain | — | `crossplane-platform`, exactly one |
| a capability module directory | System | — | `bucket`, `dns`, `postgres` … one per module, whatever backends it has |
| `packages/*/*/xrd/xrd.yaml` | API | `crossplane-xrd` | `spec.definition` is a `$text` placeholder pointing at the committed `xrd.yaml`; Backstage resolves it at ingestion, so the page shows the schema on `main` and the entity file stays a diff a human can read |
| a package with a sibling `composition.yaml` | Component | `crossplane-composition` | one per backend implementation — `bucket-aws`, `bucket-gcp`, … |
| `packages/providers/*` | Component | `kcl-provider-schema` | the generated provider schemas a Composition imports |
| every other `kcl.mod` | Component | `crossplane-xrd-package`, `kcl-manifest-package`, `kcl-library` | the XRD packages, the values-driven manifest packages (`app`, `manager`, `fleet` …) and the shared libraries — without them the dependency graph stops at the Composition |
| `packages/*/*/xrd/examples/*.yaml` | Resource | `crossplane-xr` | the example XRs; one entity per document, so the seven-XR `workload-identity-gcp-platform.yaml` is seven |

Relations are derived, never authored: a Composition `providesApis` its XRD,
`consumesApis` every XR it renders as a **child** XR (that is how `AppStack` and
`Component` compose lower capabilities), and `dependsOn` the provider schema
packages its `kcl.mod` lists as `path =` dependencies. Backstage's graph tab then
draws the same edges the Mermaid diagram does, from the same scan.

Two numbers ride along as annotations, because they are the two questions a
repo this size cannot answer by reading: `platform.example.org/usage-count` (and
`/usages`) is how often a capability is referenced at all — Compositions,
backends, examples, child XRs, `devkit.toml` rows — so a module with a count of
one is a candidate for deletion, not a platform API. `platform.example.org/findings`
puts each refactor finding on the entity it is about, instead of in a report
nobody opens. `/backends`, `/kcl-package`, `/oci-image` and `/composition-pin`
are the same idea: what implements this, what it is called to `kcl run`, what
image it publishes, and which tag the Composition pins — drift between repo and
cluster without needing a cluster.

The portal side is config, not code: [backstage/](../backstage) holds
`app-config.crossplane.yaml` (the Location for `catalog/crossplane.yaml`, the
`Domain, System, API, Component, Resource` rules, the GitHub integration, the
Jira proxy, all 25 XR plurals for the Kubernetes plugin, and the rag-ai `ai:`
block), plus `mcp.json` so an agent reads the same two artifacts over MCP. There
is still no Backstage app in this repo — the chart runs the stock image, so the
plugin list in `backstage/README.md` is something the app you already run has to
install.

## Getting the entities into Backstage

Entities are files, and Backstage reads them from a **Location**, not from the
cluster:

```yaml
catalog:
  locations:
    - type: url
      target: https://github.com/<org>/<repo>/blob/main/catalog/zerg-api.yaml
    - type: url
      target: https://github.com/<org>/<repo>/blob/main/catalog/platform.yaml
```

So the flow is: render → commit → Backstage polls. Re-render in CI from the same
values file the manifests come from and the catalog cannot drift from the
cluster; nothing needs to push to the portal.

Backstage itself is just another chart —
`packages/manager/examples/values.yaml` lists it as an `application` dependency
(`backstage` 2.10.1 from `https://backstage.github.io/charts`), so Flux installs
it like cert-manager or KEDA. It needs a Postgres: point the chart's values at
one, or provision it with the `PostgresInstance` XR
(`packages/cloud/postgres`).

## Deliberately absent

| not here | why |
|---|---|
| Software Templates (scaffolder) | A template is a repo of skeleton files plus a `template.yaml`, not something a values file renders. The entities here describe what exists; scaffolding new things is a different job. |
| TechDocs content | `catalog.techdocs` emits `backstage.io/techdocs-ref`; building and publishing the MkDocs site is the portal's pipeline, not this render. |
| Kubernetes-ingested entities | There is no controller here turning cluster objects into catalog entries. Locations in git are reproducible, reviewable and work when the cluster is down. |
| `System` / `Domain` entities from a values file | `spec.system` references one; owning the System entity belongs to whoever owns the estate, not to a single app's values file. The estate-level ones are emitted by `tools/catalog`, which scans every package rather than one release. |
| One entity per chaos experiment | An experiment is a fault, a Workflow is a run, and only a run is worth owning. Experiments are listed on the cluster entity instead. |
| Catalog entities emitted *by* a Composition | A Composition's output is Kubernetes objects; `backstage.io/v1alpha1` is not an API the cluster serves, so an entity cannot ride along with the XR it describes. `tools/catalog` scans the repo instead — `just crossplane-catalog` (§ Crossplane in the portal). |

## Files

| file | role |
|---|---|
| `packages/app/lib.k` | `Link`, `Api`, `Catalog` schemas, `Release.catalog`; the public `entity` / `link` / `faultSummary` atoms and `catalogEntities` |
| `packages/app/app_test.k` | `test_catalog_*` — entity shape, archetype defaults, api entities, the id/label contract, selector immutability |
| `packages/app/main.k` | `-D catalog=true` |
| `packages/app/examples/values-backend.yaml` | a Component with an API entity |
| `packages/app/examples/values-chaos.yaml` | the chaos-faults annotation |
| `packages/manager/lib.k` | the cluster-level `Catalog` schema, `Manager.catalog`, the cluster and game-day Resources, `catalogEntities` |
| `packages/manager/manager_test.k` | `test_catalog_*` — chart roster follows `role`, game day per Workflow, ids match the rendered objects |
| `packages/manager/examples/values.yaml` | the `backstage` chart row and the cluster's `catalog:` block |
| `justfile` | `just catalog`, `just manager-catalog` |
