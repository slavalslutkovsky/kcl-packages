# serverless-azure

Azure backend for the `ServerlessApp` XR (`cloud.example.org/v1alpha1`),
Composition `serverless-azure` (label `provider: azure`). Typed against the
[azure-containerapp](../../../providers/azure-containerapp/) schema package,
it maps the portable app onto a Container App inside its own Container App
Environment, bound by controller reference. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/serverless-azure`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Environment` (`containerapp.azure.m.upbound.io`) | `environment` | always | one per XR; no shared Environment is assumed |
| `ContainerApp` (`containerapp.azure.m.upbound.io`) | `managed` | always | `revisionMode: Single`; ingress always present, 100% to latest revision |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `resourceGroup` | `resourceGroupName` on both; **required**, the render fails without it |
| `region` | `Environment.location` |
| `image` | the single container's `image` (container named after the XR) |
| `cpu`, `memoryMb` | rounded **up** to the smallest Consumption-plan pair covering both (0.25/0.5Gi … 2/4Gi); defaults 1 and 512 → `1` / `2Gi` |
| `minInstances` | `minReplicas`, default 0 |
| `maxInstances` | `maxReplicas`; unset keeps Azure's default |
| `env` | container `env`, sorted by name |
| `port` | `ingress.targetPort`, default 8080 |
| `public` | `ingress.externalEnabled`, default `true`; `false` keeps the app reachable only inside the Environment |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` on both |

Ignored: `timeoutSeconds` (ingress timeout is platform-fixed),
`serviceAccount` (runtime identity would be a managed identity).

Status written back: `provider: azure`, `ready` (FQDN observed), `host`
(`latestRevisionFqdn`, falling back to `ingress.fqdn`), `url` (`https://<host>`),
`id` (ARM id) and `cloud-url` (Azure portal).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` ServerlessApp (GHCR image in `westeurope`, resource group `example-rg`):

```bash
kcl run packages/cloud/serverless/azure
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/serverless/azure -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"ServerlessApp","metadata":{"name":"hello"},"spec":{"image":"ghcr.io/acme/hello:1.0.0","region":"westeurope","resourceGroup":"rg","cpu":0.5,"memoryMb":1024}}}'
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
pnpm exec nx run serverless-azure:test     # kcl test
pnpm exec nx run serverless-azure:lint     # kcl lint
pnpm exec nx run serverless-azure:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
