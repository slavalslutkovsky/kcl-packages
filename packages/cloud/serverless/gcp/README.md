# serverless-gcp

GCP backend for the `ServerlessApp` XR (`cloud.example.org/v1alpha1`),
Composition `serverless-gcp` (label `provider: gcp`). Typed against the
[gcp-cloudrun](../../../providers/gcp-cloudrun/) schema package, it maps the
portable app onto a Cloud Run v2 Service, plus an `allUsers` invoker binding
when public. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/serverless-gcp`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `V2Service` (`cloudrun.gcp.m.upbound.io`) | `managed` | always | external name pinned to the XR name |
| `ServiceIAMMember` (`cloudrun.gcp.m.upbound.io`) | `invoker` | `public` (default `true`) | `allUsers` → `roles/run.invoker`; bound by explicit `service` + `location` because its selector matches `Service`, not `V2Service` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `image` | container `image` |
| `region` | `location` on both resources |
| `port` | `ports.containerPort`, default 8080 |
| `cpu`, `memoryMb` | `resources.limits` `cpu: "<cpu>"`, `memory: "<memoryMb>Mi"`; defaults 1 and 512 |
| `minInstances` | `scaling.minInstanceCount`, default 0 |
| `maxInstances` | `scaling.maxInstanceCount`; unset keeps Cloud Run's default |
| `timeoutSeconds` | `timeout: "<n>s"`, default 60 |
| `env` | container `env`, sorted by name |
| `serviceAccount` | `template.serviceAccount` |
| `public` | `ingress` `INGRESS_TRAFFIC_ALL` vs `INGRESS_TRAFFIC_INTERNAL_ONLY`, and the invoker binding |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `labels` |

Status written back: `provider: gcp`, `ready` (`uri` observed), `url`, `host`,
`id`, and `cloud-url` (Cloud Run console; `?project=` added once observed).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` ServerlessApp (Cloud Run hello image in `us-central1`):

```bash
kcl run packages/cloud/serverless/gcp
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/serverless/gcp -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"ServerlessApp","metadata":{"name":"hello"},"spec":{"image":"us-docker.pkg.dev/cloudrun/container/hello","region":"europe-west1","public":false}}}'
```

In a cluster (needs docker/kind): `just e2e serverless` publishes the module's
packages to the local registry and applies every example XR;
`just install-module serverless` applies only the XRD and the Compositions,
repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `serverless.k` | `render` (managed resources) and `status` (XR status) |
| `serverless_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run serverless-gcp:test     # kcl test
pnpm exec nx run serverless-gcp:lint     # kcl lint
pnpm exec nx run serverless-gcp:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
