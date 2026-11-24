# app

One application release, Helm-style: a values file that is an `app.Release`
renders the Kubernetes manifests for one workload (Deployment and friends) or
one task (Job / CronJob / KEDA ScaledJob). The values are validated against
the typed schemas in `lib.k` — an unknown, mistyped or missing field fails the
render — and every object is typed against the real API (`k8s`,
`external-secrets`, `keda`, `prometheus-operator`, `chaos-mesh`, `litmus`). A
consumer ships only a values file; no local `main.k` / `kcl.mod` is needed.
`packages/manager` imports `app.lib` for its overlay merge, chaos renderers and
Backstage entity atoms, and platform-api's XChaosExperiment for the chaos
renderers.

## Usage

```bash
# one values file → manifest stream
kcl run packages/app -D values=packages/app/examples/values-backend.yaml -q | kubectl apply -f -

# env overlay: -D values=<dir>/values.yaml -D env=prod also reads <dir>/values.prod.yaml
kcl run packages/app -D values=<dir>/values.yaml -D env=prod -q

# Backstage entities of the `catalog:` block instead of the manifests
kcl run packages/app -D values=packages/app/examples/values-backend.yaml -D catalog=true -q > catalog-info.yaml
```

The same through `just`:

```bash
just app packages/app/examples/values-backend.yaml [env]
just catalog packages/app/examples/values-backend.yaml [env]
```

From the published package: `kcl run oci://docker.io/yurikrupnik/app --tag <version> -D values=… -q`.

| option | default | meaning |
| --- | --- | --- |
| `values` | `values.yaml` in the current directory | Base values file, CWD-relative. An explicit path that does not exist fails the render |
| `env` | `""` | Overlay `<stem>.<env>.yaml` next to the base; must exist when set. Maps merge recursively, lists and scalars replace |
| `catalog` | `false` | `true` / `1` / `yes` renders the Backstage entities; fails without a `catalog:` block |

Without `-D values` and with no `values.yaml` in the current directory, a
built-in demo workload renders (Deployment, Service, ScaledObject, ConfigMap), so a
bare `kcl run packages/app` from the repo root still smoke-tests the package.

Catalog entities (`backstage.io/v1alpha1`) are not Kubernetes objects: write
them to a `catalog-info.yaml`, never into `kubectl`
([docs/backstage.md](../../docs/backstage.md)).

`just component-push <name> <tag>` renders `manifests/apps/<name>.yaml` with this
package and pushes the result as the Flux OCI artifact a `Component` XR pulls
([docs/devkit.md](../../docs/devkit.md)).

## Inputs

A `Release` (`lib.k`) needs exactly one of `workload:` or `task:`.

| key | schema | meaning |
| --- | --- | --- |
| `workload` | `Workload` | Long-running app (backend, frontend, queue worker). Only `image` is required; `name` defaults to `app`, `port` to `8080` |
| `task` | `Task` | Run-to-completion app: a Job, a CronJob when `schedule` is set, a KEDA ScaledJob when `scaler` is (`schedule` and `scaler` are exclusive) |
| `config` | `{str:str}` | ConfigMap `<name>-config` |
| `externalSecret` | `ExternalSecretSpec` | ExternalSecret (default name `<name>-secrets`, store `gcp-secret-manager`, `ClusterSecretStore`) from `items: [{secretKey, key, property}]` |
| `catalog` | `Catalog` | Backstage Component (+ one API per `apis` entry); `owner` required. Rendered only with `-D catalog=true` |

Main `Workload` / `Task` field groups:

| field | applies to | meaning |
| --- | --- | --- |
| `image`, `env`, `envFrom`, `resources`, `volumes`, `volumeMounts` | both | Container; non-root (`runAsUser` 65534), read-only root filesystem, `/tmp` emptyDir by default |
| `command`, `args` | task | Container entrypoint override |
| `port`, `portName`, `service`, `serviceType`, `startupProbe` / `livenessProbe` / `readinessProbe` | workload | Container port, Service (on by default), http / grpc probes |
| `serviceAccount` | both | ServiceAccount (token not mounted unless `automountToken`), `cloud` + `identity` workload-identity annotation (gcp / aws / azure), `rules` → namespaced Role + RoleBinding |
| `scaler` | both | The only autoscaler. Workload: KEDA ScaledObject (`cpu`, `memory`, `triggers`, `minReplicas: 0` for scale-to-zero); KEDA creates and owns the HorizontalPodAutoscaler behind it, so the Deployment omits `replicas`. Task: KEDA ScaledJob. `authentications` → TriggerAuthentications referenced by a trigger's `auth`. Needs KEDA on the cluster |
| `dapr` | workload | Dapr sidecar via pod-template annotations: `dapr.io/enabled`, `app-id` (default `name`), `app-port` (always `port`), `app-protocol` (`http` / `grpc`), `log-as-json`, optional `maxConcurrency` / `config`, `sidecarResources` (→ `sidecar-{cpu,memory}-{request,limit}`), and the app health check on the readiness (else liveness) http probe's path |
| `disruptionBudget` | workload | PodDisruptionBudget, exactly one of `minAvailable` / `maxUnavailable` |
| `route` | workload | Gateway API HTTPRoute (`gateway.networking.k8s.io/v1`) to the Service. `enabled` (default true) is the switch an env overlay flips; `hostnames` and `gateway` (`name`, optional `namespace` / `sectionName` / `port`, referenced, never created) are required when enabled. One rule from `path` / `pathType` (default `/`, `PathPrefix`), or up to 16 `rules`; `port` (default the workload's), `timeout` (Gateway API duration) and `requestHeaders` (`set` / `add` / `remove`) are every rule's defaults. `httpsRedirect` (`sectionName`, default `http`; `statusCode` 301 / 302) adds `<name>-https-redirect` on the plain-HTTP listener |
| `monitoring` | workload | ServiceMonitor or PodMonitor, PrometheusRule (`defaultRules`, `rules`), Grafana dashboard ConfigMaps for kube-prometheus-stack |
| `chaos` | workload | List of `Fault`s, selector pinned to `app=<name>` in the workload's namespace. `provider: chaos-mesh` (default): one Chaos Mesh experiment each (or a `Schedule` with `schedule`). `provider: litmus`: a ChaosEngine + its chaos-charts ChaosExperiment + runner ServiceAccount/Role/RoleBinding in `litmus`, and a Role/RoleBinding in the workload's namespace; runs once, no `schedule`, fewer fault types |
| `schedule`, `concurrencyPolicy`, `backoffLimit`, `restartPolicy`, … | task | CronJob / Job controls |
| `podLabels` | both | Extra pod template labels (cost attribution, `azure.workload.identity/use` for a ServiceAccount created elsewhere) |
| `nodeSelector`, `tolerations` | both | Pod scheduling, e.g. a customer's dedicated node pool |
| `extraManifests` | both | Appended to the stream as written |

`monitoring`, `chaos` and `serviceAccount.rules` need an explicit `namespace`.
A ServiceMonitor scrapes through the Service, so `service: false` needs
`monitoring.kind: PodMonitor`. Fault types and their knobs:
[docs/chaos.md](../../docs/chaos.md).

`dapr` needs the target namespace labelled `shluviza.com/dapr: enabled`:
that label gives it the `pubsub` Component and the platform `Resiliency`
defaults (gitops `platform/dapr`). The app names only `pubsub` and a topic and
declares its own subscriptions, so no subscription object is rendered. The pod
keeps `seccompProfile: RuntimeDefault`, which is what lets the injected sidecar
pass Pod Security `restricted`.

`route` attaches to a Gateway the platform owns; turn it off for one
environment with `route: {enabled: false}` in `values.<env>.yaml` (an overlay
merges, so deleting the block there is not possible). `httpsRedirect` needs
`gateway.sectionName` set to the HTTPS listener, so the route itself does not
also serve plain HTTP, and a plain-HTTP listener that admits routes from the
workload's namespace: on a Gateway whose HTTP listener is `from: Same` (gitops
`main-gateway`, which already redirects every host) leave it unset.

## Outputs

In apply order, each only when its input is set:

- Workload: ServiceAccount (+ Role, RoleBinding), Deployment, Service,
  HTTPRoute (+ its https redirect), PodDisruptionBudget,
  TriggerAuthentication(s) +
  ScaledObject, ServiceMonitor / PodMonitor + PrometheusRule + dashboard
  ConfigMaps, chaos experiments (Chaos Mesh: PodChaos, NetworkChaos,
  StressChaos, HTTPChaos, IOChaos, DNSChaos, TimeChaos, Schedule; Litmus:
  ServiceAccount + Role + RoleBinding + Role + RoleBinding + ChaosExperiment +
  ChaosEngine per fault), `extraManifests`.
- Task: ServiceAccount (+ Role, RoleBinding), then TriggerAuthentication(s) +
  ScaledJob, a CronJob, or a Job; `extraManifests`.
- Then the `config` ConfigMap and the ExternalSecret.

The workload / task objects carry the `backstage.io/kubernetes-id` label, so
the portal's Kubernetes plugin finds them from the catalog entity; the
`config` ConfigMap and the ExternalSecret do not.

Library use: `renderRelease`, `render` (Workload), `renderTask`,
`catalogEntities`, `mergeValues`, `configMap`, `secret`, `externalSecret`, and
the chaos atoms `experiment` / `faultSpec` / `faultKind` / `faultEmbedKey`
(Chaos Mesh) and `litmusObjects` / `litmusEnv` / `litmusExperiment` /
`LitmusTarget` (Litmus).

### Litmus

A `provider: litmus` fault is a run, not a CR: the operator starts a runner
pod, the runner an experiment Job, and network / stress / http / dns faults a
privileged go-runner helper on the target's node, all in the ChaosEngine's
namespace — always `litmus`, the one namespace allowed to run them. The
workload's namespace only gets a Role + RoleBinding for the runner's
ServiceAccount (pods get/list, owner lookup; pod delete for `pod-kill`,
NetworkPolicies for `partition`). Names in `litmus` are
`<namespace>-<workload>-<fault>`; the ChaosExperiment definition is the
chaos-charts one (`litmus_hub.k`, regenerated by `just litmus-hub <ref>`)
named `<experiment>-<hash>` so no two engines share it. `engineState` is never
rendered: the operator sets it to `stop` when the run completes, and an
applier that re-asserted `active` would restart it. Re-running means a new
fault name (or deleting the engine). Anything Litmus cannot express is a
render error, not an approximation — see docs/chaos.md.

## Examples

| file | renders |
| --- | --- |
| `examples/values-backend.yaml` | API workload: ServiceAccount, Deployment, Service, PDB, HPA, ServiceMonitor, PrometheusRule, dashboard ConfigMap, ConfigMap, ExternalSecret; `catalog:` with an API entity |
| `examples/values-frontend.yaml` | Static frontend: Deployment + Service, uid/gid 101, no prometheus |
| `examples/values-worker.yaml` | Pull-based queue worker: KEDA ScaledObject with scale-to-zero, no Service |
| `examples/values-dapr-worker.yaml` | Broker-agnostic worker consuming through a Dapr sidecar (`pubsub` Component), app health check on its readiness probe, CPU-based KEDA scaling, no Service |
| `examples/values-cli.yaml` | One-shot Job (CronJob once `schedule` is set) |
| `examples/values-queue-job.yaml` | KEDA ScaledJob on a Pub/Sub backlog, GKE Workload Identity, `podIdentity: gcp` TriggerAuthentication |
| `examples/values-chaos.yaml` | Every Chaos Mesh fault type, one-shot and scheduled, three of them again through Litmus, plus the `catalog:` block |
| `examples/consumer-main.k.example` | A consumer `main.k` + `kcl.mod` for adding manifests in code on top of `renderRelease` |

## Layout

| file | content |
| --- | --- |
| `main.k` | Values / overlay / catalog options, demo fallback, stream output |
| `lib.k` | `Release`, `Workload`, `Task` and component schemas; all renderers |
| `litmus_hub.k` | Generated: the chaos-charts ChaosExperiment definitions Litmus faults render (`tools/litmus-hub.sh`) |
| `app_test.k` | `kcl test` cases |
| `examples/` | Values files and the consumer entry point |

## Development

```bash
pnpm exec nx run app:test     # kcl test
pnpm exec nx run app:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
