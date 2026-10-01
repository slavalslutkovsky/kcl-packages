# app

One application release, Helm-style: a values file that is an `app.Release`
renders the Kubernetes manifests for one workload (Deployment and friends) or
one task (Job / CronJob / KEDA ScaledJob). The values are validated against
the typed schemas in `lib.k` — an unknown, mistyped or missing field fails the
render — and every object is typed against the real API (`k8s`,
`external-secrets`, `keda`, `prometheus-operator`, `chaos-mesh`). A consumer
ships only a values file; no local `main.k` / `kcl.mod` is needed.
`packages/manager` imports `app.lib` for its overlay merge, chaos renderers and
Backstage entity atoms.

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
built-in demo workload renders (Deployment, Service, HPA, ConfigMap), so a
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
| `hpa` | workload | Native HPA on cpu / memory; exclusive with `scaler` |
| `scaler` | both | Workload: KEDA ScaledObject (`cpu`, `memory`, `triggers`, `minReplicas: 0` for scale-to-zero). Task: KEDA ScaledJob. `authentications` → TriggerAuthentications referenced by a trigger's `auth` |
| `disruptionBudget` | workload | PodDisruptionBudget, exactly one of `minAvailable` / `maxUnavailable` |
| `monitoring` | workload | ServiceMonitor or PodMonitor, PrometheusRule (`defaultRules`, `rules`), Grafana dashboard ConfigMaps for kube-prometheus-stack |
| `chaos` | workload | List of `Fault`s, one Chaos Mesh experiment each (or a `Schedule` with `schedule`), selector pinned to `app=<name>` in the workload's namespace |
| `schedule`, `concurrencyPolicy`, `backoffLimit`, `restartPolicy`, … | task | CronJob / Job controls |
| `extraManifests` | both | Appended to the stream as written |

`monitoring`, `chaos` and `serviceAccount.rules` need an explicit `namespace`.
A ServiceMonitor scrapes through the Service, so `service: false` needs
`monitoring.kind: PodMonitor`. Fault types and their knobs:
[docs/chaos.md](../../docs/chaos.md).

## Outputs

In apply order, each only when its input is set:

- Workload: ServiceAccount (+ Role, RoleBinding), Deployment, Service,
  PodDisruptionBudget, HorizontalPodAutoscaler or TriggerAuthentication(s) +
  ScaledObject, ServiceMonitor / PodMonitor + PrometheusRule + dashboard
  ConfigMaps, Chaos Mesh experiments (PodChaos, NetworkChaos, StressChaos,
  HTTPChaos, IOChaos, DNSChaos, TimeChaos, Schedule), `extraManifests`.
- Task: ServiceAccount (+ Role, RoleBinding), then TriggerAuthentication(s) +
  ScaledJob, a CronJob, or a Job; `extraManifests`.
- Then the `config` ConfigMap and the ExternalSecret.

The workload / task objects carry the `backstage.io/kubernetes-id` label, so
the portal's Kubernetes plugin finds them from the catalog entity; the
`config` ConfigMap and the ExternalSecret do not.

Library use: `renderRelease`, `render` (Workload), `renderTask`,
`catalogEntities`, `mergeValues`, `configMap`, `secret`, `externalSecret`, and
the chaos atoms `experiment` / `faultSpec` / `faultKind` / `faultEmbedKey`.

## Examples

| file | renders |
| --- | --- |
| `examples/values-backend.yaml` | API workload: ServiceAccount, Deployment, Service, PDB, HPA, ServiceMonitor, PrometheusRule, dashboard ConfigMap, ConfigMap, ExternalSecret; `catalog:` with an API entity |
| `examples/values-frontend.yaml` | Static frontend: Deployment + Service, uid/gid 101, no prometheus |
| `examples/values-worker.yaml` | Pull-based queue worker: KEDA ScaledObject with scale-to-zero, no Service |
| `examples/values-cli.yaml` | One-shot Job (CronJob once `schedule` is set) |
| `examples/values-queue-job.yaml` | KEDA ScaledJob on a Pub/Sub backlog, GKE Workload Identity, `podIdentity: gcp` TriggerAuthentication |
| `examples/values-chaos.yaml` | Every fault type, one-shot and scheduled, plus the `catalog:` block |
| `examples/consumer-main.k.example` | A consumer `main.k` + `kcl.mod` for adding manifests in code on top of `renderRelease` |

## Layout

| file | content |
| --- | --- |
| `main.k` | Values / overlay / catalog options, demo fallback, stream output |
| `lib.k` | `Release`, `Workload`, `Task` and component schemas; all renderers |
| `app_test.k` | `kcl test` cases |
| `examples/` | Values files and the consumer entry point |

## Development

```bash
pnpm exec nx run app:test     # kcl test
pnpm exec nx run app:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
