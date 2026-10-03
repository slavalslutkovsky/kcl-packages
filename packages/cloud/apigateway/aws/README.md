# apigateway-aws

AWS backend for the `ApiGateway` XR (`cloud.example.org/v1alpha1`). Typed
against [`aws-apigatewayv2`](../../../providers/aws-apigatewayv2), it composes a
single API Gateway v2 HTTP API using AWS quick create: `forProvider.target` set
to the backend URL makes AWS produce the `HTTP_PROXY` integration, the
catch-all `$default` route and an auto-deploying `$default` stage itself, so no
separate Integration/Route/Stage resources are composed. The `apigateway-aws`
Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/apigateway-aws`, followed by `function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `API` (`apigatewayv2.aws.m.upbound.io/v1beta1`) | always | resource name `managed`; `protocolType: HTTP`, `name` = XR name, `target` = `spec.backendUrl` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `backendUrl` | `forProvider.target` (quick-create `HTTP_PROXY` integration) |
| `region` | `forProvider.region` |
| `description` | `forProvider.description`, when set |
| `tags` | `forProvider.tags`, when set |
| `cors` | `forProvider.corsConfiguration`; `allowOrigins` always, `allowMethods` / `allowHeaders` / `exposeHeaders` only when set, `allowCredentials` and `maxAgeSeconds` (→ `maxAge`) whenever present, including `false` / `0` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]`; otherwise the schema default `["*"]` |

Ignored: `resourceGroup`, `publisherEmail`, `publisherName` (Azure-only) and
`project`, `hostname`, `apigeeInstance` (GCP-only).

Status written back to the XR, from the observed `managed` API:

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once `atProvider.apiEndpoint` is set |
| `url`, `host` | `apiEndpoint`, and the same without `https://` |
| `id`, `cloud-url` | API id and its console page; only once the id is observed |
| `arn` | `atProvider.arn`, when observed |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/apigateway/aws

kcl run packages/cloud/apigateway/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/apigateway/xrd/examples/apigateway-aws.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/apigateway-aws.yaml`](../xrd/examples/apigateway-aws.yaml):

```bash
pnpm exec nx run apigateway-aws:render     # or: just render apigateway-aws
```

On a Kind cluster: `just e2e apigateway` (publish, install, apply every
example), `just install-module apigateway` (XRD + Compositions only) or
`just workload apigateway aws` (module, providers, and this backend's example).
`just seed-apigateway-providers` regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `apigateway.k` | `render` (the HTTP API) and `status` |
| `apigateway_test.k` | `kcl test` cases |
| `composition.yaml` | `apigateway-aws` Composition |

## Development

```bash
pnpm exec nx run apigateway-aws:test     # kcl test
pnpm exec nx run apigateway-aws:lint     # kcl lint
pnpm exec nx run apigateway-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
