# application

The only backend for the `Application` XR (`platform.example.org/v1alpha1`,
Composition `application`, the XRD's `defaultCompositionRef`). A wrapper, not a
second renderer: the Deployment, Service, ConfigMap, KEDA ScaledObject and
ExternalSecret come out of [`packages/app`](../../../app/) (`app.lib`), so an
Application XR and a values file produce the same objects from the same code.
This package adds the envFrom wiring between them and the north-south route,
typed against the [gateway-api](../../../providers/gateway-api/) and
[istio](../../../providers/istio/) schema packages. No Crossplane provider and
no managed resources: core and CRD kinds are composed directly into the XR's
namespace. Run by `function-kcl` from `oci://docker.io/yurikrupnik/application`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Deployment` (`apps`) | `deployment` | always | `spec.replicas` omitted once `scaling` is set |
| `Service` (core) | `service` | always | named after the XR; the route backend |
| `ConfigMap` (core) | `config` | `config` set | `<name>-config`, mounted with envFrom |
| `ScaledObject` (`keda.sh`) | `scaler` | `scaling` set | needs KEDA in the cluster |
| `ExternalSecret` (`external-secrets.io`) | `secrets` | `secrets` set | target Secret `<name>-secrets`, mounted with envFrom (`optional: false`) unless `mountAsEnv: false` |
| `HTTPRoute` (`gateway.networking.k8s.io`) | `route` | `route.type: gateway-api` | one rule; `parentRefs` to the shared gateway |
| `VirtualService` (`networking.istio.io`) | `route` | `route.type: istio` | gateway ref `<namespace>/<name>` |
| `DestinationRule` (`networking.istio.io`) | `destination` | `route.type: istio` and `route.trafficPolicy` set | outlier detection is fixed at 5 consecutive 5xx, 10s interval, 30s ejection, 50% max |

The Gateway is referenced, never created. The composition-resource-names are
what `status()` reads back out of the observed resources; renaming one breaks
status.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `image` | the Deployment's only container image (required) |
| `port` | containerPort, Service port, scrape port, route backend port; default 8080 |
| `replicas` | Deployment replicas, default 2; ignored once `scaling` is set |
| `component`, `partOf`, `version` | `app.kubernetes.io/{component,part-of,version}`; defaults `server`, `platform`, app package default |
| `prometheus`, `metricsPath` | `prometheus.io/*` pod annotations; defaults `true`, `/metrics` |
| `env` | container env, sorted by name |
| `config` | ConfigMap `<name>-config` + envFrom |
| `resources` | deep-merged onto the app package defaults (`app.mergeValues`) |
| `health.{startup,liveness,readiness}Path` | one probe each on `port`; `failureThreshold` 3 and `periodSeconds` 10 apply to all |
| `scaling` | KEDA ScaledObject: `minReplicas` 1, `maxReplicas` 10, `cpu` / `memory` triggers, `triggers[]` passed through |
| `secrets` | ExternalSecret: `store` (ClusterSecretStore, default `gcp-secret-manager`), `refreshInterval` 1h, `items[]` |
| `route.type` | `none` (default), `gateway-api`, `istio` |
| `route.hosts`, `route.gateway` | required once `type` is not `none`; the render fails with an assert otherwise |
| `route.path`, `route.pathType` | HTTPRoute path match / Istio `uri.prefix` or `uri.exact`; defaults `/`, `PathPrefix` |
| `route.gateway.sectionName` | HTTPRoute `parentRefs[].sectionName`; ignored by istio |
| `route.timeoutSeconds` | HTTPRoute `timeouts.request` / VirtualService `timeout` |
| `route.retries`, `route.trafficPolicy` | Istio only; ignored by gateway-api |

Not exposed, per the XRD: the app package's batch archetype, Chaos Mesh faults
and Backstage `catalog:` block.

Status written back: `ready` (available replicas > 0 and route ready),
`workloadReady`, `routeReady` (gateway-api: a parent reports `Accepted=True`;
istio: the VirtualService exists), `replicas`, `availableReplicas`,
`serviceName`, `endpoint` (`<name>.<namespace>.svc.cluster.local:<port>`),
`route`, `hosts`, `url` (`https://<first host><path>`), `message`.

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` (gateway-api route to
`api.example.org`):

```bash
kcl run packages/platform/application/k8s
```

Pass a real XR the way function-kcl does:

```bash
kcl run packages/platform/application/k8s \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/application/xrd/examples/application-istio.yaml)}"
```

`pnpm exec nx run application:render` (or `just render application`) renders
`composition.yaml` through function-kcl against an example XR; needs docker.

In a cluster (needs docker/kind): `just e2e application` publishes the package
to the local registry, installs the XRD, Composition and the ClusterRole in
[`../xrd/providers.yaml`](../xrd/providers.yaml), and applies every example;
`just install-module application` applies only the XRD and the Composition,
repointed at the local registry. The route and scaling kinds need their CRDs
on the cluster (Gateway API, Istio, KEDA). `just seed-application-providers`
regenerates the gateway-api and istio schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `application.k` | `render` (app package objects + route) and `status` |
| `application_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run application:test     # kcl test
pnpm exec nx run application:lint     # kcl lint
pnpm exec nx run application:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
