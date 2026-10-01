# apigateway-azure

Azure backend for the `ApiGateway` XR (`cloud.example.org/v1alpha1`). Typed
against [`azure-apimanagement`](../../../providers/azure-apimanagement), it
composes an API Management service on the Consumption tier, one catch-all API
proxying everything to the backend URL, a wildcard operation per HTTP method
and, when CORS is requested, an inbound CORS policy, all bound together by
controller reference. The `apigateway-azure` Composition runs it through
`function-kcl` from `oci://docker.io/yurikrupnik/apigateway-azure`, followed
by `function-auto-ready`.

## Composed resources

All kinds are `apimanagement.azure.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `Management` | always | resource name `managed`; external name = XR name, which is also the gateway hostname (`<name>.azure-api.net`); `skuName: Consumption_0` |
| `API` | always | resource name `api`; external name = XR name; `path: ""` (served at the gateway root), `protocols: [https]`, `revision: "1"`, `subscriptionRequired: false` |
| `APIOperation` × 7 | always | `op-get` … `op-options` for `GET POST PUT PATCH DELETE HEAD OPTIONS`; `urlTemplate: /*`; external name = lowercase method. APIM only routes requests that match a declared operation |
| `APIPolicy` | `spec.cors` set | resource name `cors`; `xmlContent` is an inbound `<cors>` policy |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `resourceGroup` | `resourceGroupName` on every resource; required, the render fails without it |
| `publisherEmail` | `Management.publisherEmail`; required, the render fails without it |
| `publisherName` | `Management.publisherName`; defaults to the XR name |
| `region` | `Management.location` |
| `backendUrl` | `API.serviceUrl` |
| `description` | `API.description`, when set |
| `tags` | `Management.tags`, when set |
| `cors` | `<allowed-origins>` from `allowOrigins`; `allowMethods` / `allowHeaders` fall back to `*` (the elements are mandatory); `exposeHeaders`, `allowCredentials` and `maxAgeSeconds` (→ `preflight-result-max-age`) only when set |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; otherwise the schema default `["*"]` |

Ignored: `project`, `hostname`, `apigeeInstance` (GCP-only).

Status written back to the XR, from the observed `managed` service:

| status | value |
| --- | --- |
| `provider` | `azure` |
| `ready` | `true` once `atProvider.gatewayUrl` is set |
| `url`, `host` | `gatewayUrl`, and the same without `https://` |
| `id`, `cloud-url` | ARM id and its Azure portal page, once observed |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/apigateway/azure

kcl run packages/cloud/apigateway/azure \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/apigateway/xrd/examples/apigateway-azure.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/apigateway-azure.yaml`](../xrd/examples/apigateway-azure.yaml):

```bash
pnpm exec nx run apigateway-azure:render     # or: just render apigateway-azure
```

On a Kind cluster: `just e2e apigateway` (publish, install, apply every
example), `just install-module apigateway` (XRD + Compositions only) or
`just workload apigateway azure` (module, providers, and this backend's
example). `just seed-apigateway-providers` regenerates the provider schema
packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `apigateway.k` | `cors_xml`, `render` (service, API, operations, policy) and `status` |
| `apigateway_test.k` | `kcl test` cases |
| `composition.yaml` | `apigateway-azure` Composition |

## Development

```bash
pnpm exec nx run apigateway-azure:test     # kcl test
pnpm exec nx run apigateway-azure:lint     # kcl lint
pnpm exec nx run apigateway-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
