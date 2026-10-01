# serverless-knative

Self-hosted backend for the `ServerlessApp` XR (`cloud.example.org/v1alpha1`),
Composition `serverless-knative` (label `provider: knative`). Typed against the
[knative](../../../providers/knative/) schema package, it renders one
namespaced `serving.knative.dev/v1` `Service` directly: no provider MR, no
`providerConfigRef`, no `managementPolicies`. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/serverless-knative`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Service` (`serving.knative.dev`) | `managed` | always | named after the XR (deterministic route hostname); lands in the XR's namespace |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `image` | container `image` |
| `port` | `ports[0].containerPort`, default 8080 |
| `cpu`, `memoryMb` | `resources.limits` `cpu: "<cpu>"`, `memory: "<memoryMb>Mi"`; defaults 1 and 512 |
| `minInstances` | revision annotation `autoscaling.knative.dev/min-scale`, default `"0"` |
| `maxInstances` | `autoscaling.knative.dev/max-scale`, only when set |
| `timeoutSeconds` | `timeoutSeconds`, default 60 |
| `env` | container `env`, sorted by name |
| `serviceAccount` | `serviceAccountName` |
| `public` | `false` adds label `networking.knative.dev/visibility: cluster-local` |
| `tags` | Service labels |

Ignored: `region` (runs where the XR lives) and `deletionPolicy` (the
Service's lifetime follows the XR).

Status written back: `provider: knative`, `id` (the Service name), `ready`
(Route published a URL), `url`, `host`. No `cloud-url` or `arn`.

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` ServerlessApp (`ghcr.io/acme/hello:1.2.0` in namespace `default`):

```bash
kcl run packages/cloud/serverless/knative
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/serverless/knative -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"ServerlessApp","metadata":{"name":"hello"},"spec":{"image":"ghcr.io/acme/hello:1.2.0","region":"in-cluster","public":false,"maxInstances":5}}}'
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
pnpm exec nx run serverless-knative:test     # kcl test
pnpm exec nx run serverless-knative:lint     # kcl lint
pnpm exec nx run serverless-knative:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
