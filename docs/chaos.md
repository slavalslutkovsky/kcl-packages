# Chaos engineering

Two layers, one fault vocabulary:

- **`app`** — a `Workload` carries a `chaos:` list, and every entry renders as
  one Chaos Mesh experiment pinned to that workload's own pods. A fault is a
  few lines in the same values.yaml that describes the Deployment it targets,
  and it lands with the rest of the release.
- **`manager`** — the cluster around the workloads: the same faults with a free
  target (namespaces, labels, nodes, pod phases), Chaos Mesh **Workflows** that
  run several faults as one managed run, a global pause, and the platform
  charts (Chaos Mesh itself among them) as Flux HelmReleases. See
  [The manager package](#the-manager-package).

Both render with the kcl CLI and print a manifest stream:

```
just app manifests/apps/app1.yaml [env]      | kubectl apply -f -
just manager [values.yaml] [env]             | kubectl apply -f -
```

```yaml
workload:
  name: zerg-api
  namespace: zerg            # required once chaos: is set (see Blast radius)
  image: yurikrupnik/zerg-api:latest
  chaos:
    - name: kill-one         # → PodChaos zerg-api-kill-one (or a Schedule around it)
      type: pod-kill
      schedule: "*/10 * * * *"
    - name: slow-net         # → NetworkChaos, one-shot, stops after `duration`
      type: delay
      latency: 200ms
      duration: 2m
```

`packages/app/examples/values-chaos.yaml` is the full worked example; `kcl run
packages/app -D values=packages/app/examples/values-chaos.yaml` renders it.

## Operators

| operator | status | why |
|---|---|---|
| **Chaos Mesh** v2.8.4 | **used** — `devkit.toml` `[[deps]]` `chaos-mesh` (helm chart 2.8.4, namespace `chaos-mesh`, wave 0); schemas in `packages/providers/chaos-mesh` generated from `chaos-mesh/chaos-mesh@v2.8.4` | Each experiment is one self-contained CR: a kind, a selector, a duration. Nothing to install per fault type, nothing to grant per namespace. |
| **Litmus** 3.31.0 | **not used, not installed** | A Litmus fault needs a `ChaosExperiment` installed from the ChaosHub per fault type, plus a chaos ServiceAccount/Role/RoleBinding per target namespace, before a `ChaosEngine` can run. That is three objects of setup and a hub dependency where Chaos Mesh needs none. Its CRDs (`ChaosEngine`, `ChaosExperiment`, `ChaosResult`) are listed as unused in `packages/providers/crds.yaml` so the decision is on record. |

Chaos Mesh on Kind: the chart is installed with
`chaosDaemon.runtime=containerd` and
`chaosDaemon.socketPath=/run/containerd/containerd.sock` (the chart defaults to
docker) — chaos-daemon needs the node's container runtime socket to kill
containers and to enter their network namespace for `tc`/`iptables`. The three
pods that land: `chaos-controller-manager`, one `chaos-daemon` per node
(DaemonSet, privileged), and `chaos-dns-server` (unused here; only DNSChaos
needs it).

The version is pinned in two places that must agree: the chart version in
`devkit.toml` and the `ref` of the `chaos-mesh` row in
`packages/providers/registry.yaml` (`just seed chaos-mesh` regenerates the
schemas; `just providers-check` reports drift against the registry).

## What renders to what

`packages/providers/crds.yaml` has the full used/unused list. The app package
renders four of Chaos Mesh's 23 kinds:

| `type` | kind | knobs |
|---|---|---|
| `pod-kill` | PodChaos | `mode`, `value`. Instantaneous — `duration` is not emitted, so a Schedule kills once per tick rather than holding the experiment open. |
| `pod-failure` | PodChaos | `duration`: the pod's containers are replaced with a pause image for that long. |
| `container-kill` | PodChaos | `containerNames` (default: the first container = the workload's). |
| `delay` | NetworkChaos | `latency`, `jitter`, `correlation`, `externalTargets`, `duration`. |
| `loss` | NetworkChaos | `loss` (percent), `correlation`, `externalTargets`, `duration`. |
| `partition` | NetworkChaos | `direction` (`to`/`from`/`both`), `externalTargets`, `duration`. |
| `cpu` | StressChaos | `workers`, `load` (percent of one core per worker), `containerNames`, `duration`. |
| `memory` | StressChaos | `workers`, `size` (`256MB`, `50%`), `containerNames`, `duration`. |
| any + `schedule` | Schedule | wraps the above; `concurrencyPolicy` (default `Forbid`), `historyLimit` (default 1). |

Common to all: `mode` (`one` by default; `all`, `fixed`, `fixed-percent`,
`random-max-percent` with `value`) and `duration` (default `30s`). The object is
named `<workload>-<fault>` and carries the workload's labels, so
`kubectl -n zerg get podchaos,networkchaos,stresschaos,schedule -l app=zerg-api`
lists everything aimed at one app.

The other 19 kinds are not reachable from `chaos:` on purpose. `HTTPChaos`,
`IOChaos`, `DNSChaos`, `TimeChaos`, `JVMChaos`, `KernelChaos`, `BlockChaos`
are fault types with no `type` yet — add one by extending `Fault.$type` and the
`_faultKind`/`_*ChaosSpec` lambdas in `packages/app/lib.k`. `Pod{Http,IO,Network}Chaos`
are the per-pod records the controller derives from an experiment, never
authored. `Workflow`/`WorkflowNode`/`StatusCheck` are the workflow engine,
`RemoteCluster`/`PhysicalMachine*`/`AWSChaos`/`GCPChaos`/`AzureChaos` target
things that are not pods.

## Blast radius

A `Fault` has no selector field. The renderer always emits

```yaml
selector:
  namespaces: [<workload.namespace>]
  labelSelectors: {app: <workload.name>}
```

and nothing else. Chaos Mesh label selectors are cluster-wide unless
`namespaces` pins them, which is why the `Workload` schema refuses `chaos:`
without an explicit `namespace` — a values file that relies on `kubectl -n` for
the Deployment would otherwise select every `app=<name>` pod in the cluster.
The schema also rejects duplicate fault names, `fixed`/percent modes without
`value`, and the two shapes Chaos Mesh's own webhook rejects (`delay`/`loss`
with `direction: from|both` and no target; `partition` `from|both` with no
`externalTargets`) so they fail at render time instead of at apply time.

Chaos Mesh's own guard rails on top of that (chart values, not set here):
`clusterScoped: false` + `controllerManager.targetNamespace` confines the
controller to a single namespace, and `controllerManager.enableFilterNamespace:
true` makes it ignore namespaces without the `chaos-mesh.org/inject=enabled`
label.

## Running it

- **One-shot** (no `schedule`): applying the object starts the experiment;
  after `duration` Chaos Mesh recovers the pods and the object stays behind as
  a record (`status.experiment.desiredPhase: Stop`). Re-applying an unchanged
  object does nothing — delete and re-apply, or use a Schedule, to run again.
- **Schedule**: one experiment per cron tick. `concurrencyPolicy: Forbid`
  skips a tick while the previous one is still running.
- **Pause** without deleting: annotate the experiment or Schedule with
  `experiment.chaos-mesh.org/pause: "true"`; remove the annotation to resume.
- **Stop**: delete the object. Chaos Mesh's finalizer recovers the pods before
  the object goes away.
- **Watch**: `kubectl -n zerg describe podchaos zerg-api-kill-one` — the
  `Events` section and `status.experiment.containerRecords` say which pod was
  hit and when; `status.conditions` (`Selected`, `AllInjected`,
  `AllRecovered`, `Paused`) are the phase.

Keep chaos in an overlay (`values.staging.yaml`) rather than the base when the
same values file also drives production: `mergeValues` deep-merges maps but
replaces lists, so an overlay can set `chaos: []` to switch it off entirely.

## The manager package

`packages/manager` is `app`'s sibling for everything that is not one workload.
Same contract (`kcl run packages/manager -D values=<file> [-D env=<env>]`,
`Manager {**values}` validated by schema, overlays deep-merged), three
sections in the values file — `packages/manager/examples/values.yaml` is the
worked example:

```yaml
role: manager                 # manager (renders every chart) | workload (application charts only)
dependencies:                 # platform charts, delivered by Flux
  - name: crossplane
    type: manager             # manager clusters only → label platform.example.org/type=manager
    repo: https://charts.crossplane.io/stable
  - name: chaos-mesh
    type: application         # every cluster that runs apps
    repo: https://charts.chaos-mesh.org
    version: 2.8.4
    values: {chaosDaemon: {runtime: containerd, socketPath: /run/containerd/containerd.sock}}
  - name: kube-prometheus-stack
    type: application
    repo: oci://ghcr.io/prometheus-community/charts
    dependsOn: [keda]         # → HelmRelease.spec.dependsOn (devkit's `wave`, per chart)
chaos:
  namespace: chaos-mesh       # where the objects below are created
  paused: false               # true → every experiment/Schedule applied with the pause annotation
  namespaces: [zerg, dbs]     # labelled chaos-mesh.org/inject=enabled
  experiments:                # an app Fault + a `target`
    - name: node-memory-pressure
      type: memory
      mode: all
      size: 512MB
      duration: 5m
      target: {namespaces: [zerg, dbs], nodes: [kcl-e2e-worker], phases: [Running]}
  workflows:                  # managed runs: one Workflow object
    - name: game-day
      deadline: 30m
      pauseBetween: 5m
      target: {namespaces: [zerg]}
      steps:
        - {name: kill-half, type: pod-kill, mode: fixed-percent, value: "50"}
        - {name: cut-db, type: partition, direction: both, externalTargets: [postgres-rw.dbs.svc], duration: 2m}
        - {name: cpu-burn, type: cpu, workers: 4, duration: 3m, target: {namespaces: [zerg], labels: {app: zerg-api}}}
```

What each section renders:

| section | objects | notes |
|---|---|---|
| `dependencies` | one `HelmRepository` (`type: oci` for `oci://`) + one `HelmRelease` per chart, in `namespace` (default `flux-system`), `targetNamespace` = the chart's namespace, `install.createNamespace`, `remediation.retries: 3`; both carry the label `platform.example.org/type: manager\|application` from the required `type` field | This is the GitOps twin of `devkit.toml` `[[deps]]`. **Do not list a chart in both**: helm-controller adopts a release with the same name and the two owners fight. devkit bootstraps the e2e cluster; a manager values file is for a cluster Flux owns. Two kinds of cluster: a *manager* cluster manages other clusters and cloud resources (crossplane), a *workload* cluster only runs apps — and a manager can run apps too. `type: manager` charts install on manager clusters only; `type: application` charts (the operators behind `app`: keda, chaos-mesh, cert-manager, monitoring) on every cluster that runs apps. The required `Manager.role` picks what renders — `manager` everything, `workload` the application charts (and the issuers, which take cert-manager's type) — so one base file plus a `role: workload` overlay serves both kinds (`packages/manager/examples/values.workload.yaml`). An application chart may not `dependsOn` a manager one, since on a workload cluster it would wait forever. `just manager-phase <type>` still splits a stream by the label. Beyond the sugar (`repo`, `chart`, `version`, `namespace`, `values`, `dependsOn`) a dependency takes the Flux objects' own fields, typed by the generated CRD schemas: `install` (deep-merged over the defaults), `upgrade`, `driftDetection`, `postRenderers`, `valuesFrom` go to `HelmRelease.spec` verbatim; `secretRef` and `provider` (`aws`/`azure`/`gcp`, `oci://` only) to `HelmRepository.spec`. |
| `chaos.namespaces` | `Namespace` objects carrying `chaos-mesh.org/inject: enabled` | Only meaningful when Chaos Mesh runs with `enableFilterNamespace`; harmless otherwise. |
| `chaos.experiments` | `PodChaos` / `NetworkChaos` / `StressChaos`, or a `Schedule`, exactly as `app` renders them — `Experiment` *is* `app.Fault` plus a `target` | `target.namespaces` is required, for the same reason `app` requires `namespace`: a selector without it is cluster-wide. `labels`, `nodes`, `nodeLabels`, `phases` narrow it. "Memory on the whole cluster" is `type: memory, mode: all` with a target spanning the namespaces. |
| `chaos.workflows` | one `Workflow`: an `entry` template (`Serial`, or `Parallel` with `parallel: true`) under `deadline`, one template per step (`deadline` = the step's `duration`, spec built by the same renderers), `Suspend` templates between serial steps when `pauseBetween` is set | A step may carry its own `target` to narrow the workflow's. A step cannot have `schedule` — the Workflow is the run. Workflows are not pausable by annotation: delete one or let the deadline pass. |
| `chaos.paused` | adds `experiment.chaos-mesh.org/pause: "true"` to every experiment and Schedule | An overlay with `chaos: {paused: true}` holds a whole cluster's chaos without deleting anything. |

The renderers are shared, not copied: `manager` imports `app.lib` and calls
`app.experiment` / `app.faultSpec` / `app.faultKind`, so a `type: delay` means
the same thing, with the same validation, whether it targets one workload or
three namespaces.

## Dashboard

**Installed: no.** `devkit.toml` sets `dashboard.create=false` — nothing in the
repo talks to it, and everything it shows is on the objects themselves
(`kubectl get`/`describe` above). Same reasoning as the Flux image/notification
controllers: each one is a pod on a throwaway Kind cluster.

To turn it on, flip the value in `devkit.toml` and re-run `devkit cluster deps`:

```toml
set = [
    "chaosDaemon.runtime=containerd",
    "chaosDaemon.socketPath=/run/containerd/containerd.sock",
    "dashboard.create=true",
    "dashboard.service.type=ClusterIP",   # chart default is NodePort
]
```

then `kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333` and
open <http://localhost:2333>. The dashboard runs with `securityMode: true` by
default, so it asks for a ServiceAccount token on first load: the login page
has a generator that prints the ServiceAccount/Role/RoleBinding to apply for a
given namespace and the `kubectl create token` line to run. Setting
`dashboard.securityMode=false` skips the login (Kind only — it makes the
dashboard a cluster-wide chaos console with no auth). Whatever you create in
the UI is the same PodChaos/NetworkChaos/… CR, outside the values file — the
UI is for looking and for one-off experiments, the values file is the source
of truth for anything meant to recur.

## Files

| file | role |
|---|---|
| `packages/app/lib.k` | `Fault` schema, `Workload.chaos`; the public `experiment` / `faultSpec` / `faultKind` renderers both packages use |
| `packages/app/app_test.k` | `test_chaos_*` — one object per fault, pinned selector, Schedule wrapping, release ordering |
| `packages/app/examples/values-chaos.yaml` | every fault type, one-shot and scheduled |
| `packages/manager/lib.k` | `Dependency`, `Target`, `Experiment`, `Step`, `Workflow`, `Chaos`, `Manager`; Flux and Workflow renderers |
| `packages/manager/manager_test.k` | dependencies, free-target experiments, pause, serial/parallel Workflows |
| `packages/manager/examples/values.yaml` | charts + cluster-scope experiments (incl. node memory pressure) + two Workflows |
| `packages/providers/chaos-mesh/` | generated KCL schemas for the 23 chaos-mesh.org CRDs (`just seed chaos-mesh`) |
| `packages/providers/registry.yaml` | the `chaos-mesh` row: source ref, `install: none`, consumers `app`, `manager` |
| `packages/providers/crds.yaml` | which Chaos Mesh (and Litmus, and every other operator/provider) kinds are used vs unused |
| `devkit.toml` | the `chaos-mesh` chart row: Kind runtime settings, dashboard off |
| `justfile` | `just app`, `just manager` — render locally with the kcl CLI |
