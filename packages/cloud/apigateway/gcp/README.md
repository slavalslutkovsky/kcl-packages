# apigateway-gcp

GCP backend for the `ApiGateway` XR (`cloud.example.org/v1alpha1`). Typed
against [`gcp-apigee`](../../../providers/gcp-apigee), it composes the per-API
slice of an Apigee X runtime: an Environment, an environment group carrying the
serving hostname, the attachment binding the two, a TargetServer describing the
backend and, when an instance is named, the attachment that puts the
environment on that runtime instance. The `apigateway-gcp` Composition runs it
through `function-kcl` from `oci://docker.io/yurikrupnik/apigateway-gcp`,
followed by `function-auto-ready`.

Not composed, by design:

- the Apigee Organization: one per project, referenced as
  `organizations/<spec.project>`; the project must already host one;
- the runtime Instance: a regional, paid singleton shared by the org;
- the API proxy bundle: `provider-gcp-apigee` has no APIProxy resource, so the
  proxy is deployed outside Crossplane and targets the names reported in
  `status.environment` / `status.targetServer`.

## Composed resources

All kinds are `apigee.gcp.m.upbound.io/v1beta1`; parents are bound by
controller reference.

| resource | when | notes |
| --- | --- | --- |
| `Envgroup` | always | resource name `managed`; external name = XR name; `hostnames: [spec.hostname]` |
| `Environment` | always | resource name `env`; external name = XR name; `deploymentType: PROXY` (archive deployments forbid target servers) |
| `EnvgroupAttachment` | always | resource name `envgroup-attachment` |
| `TargetServer` | always | resource name `target`; external name = XR name; host/port from `backendUrl`, `protocol: HTTP`, `sSlInfo {enabled, enforce}` for `https://` |
| `InstanceAttachment` | `spec.apigeeInstance` set | resource name `instance-attachment`; `instanceId: organizations/<project>/instances/<apigeeInstance>` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `project` | `orgId: organizations/<project>`; required, the render fails without it |
| `hostname` | `Envgroup.hostnames`; required, the render fails without it |
| `backendUrl` | `TargetServer.host` / `port` (default 443 for `https://`, 80 for `http://`) / TLS; anything but `http(s)://`, or a URL with a path, fails the render |
| `apigeeInstance` | `InstanceAttachment.instanceId`, when set |
| `description` | `Environment.description` and `TargetServer.description`, when set |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; otherwise the schema default `["*"]` |

Rejected: `cors` fails the render (Apigee CORS is a proxy-bundle policy).
Ignored: `region` (an environment has no location), `tags` (no Apigee resource
here carries labels), `resourceGroup`, `publisherEmail`, `publisherName`
(Azure-only).

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | `true` once the observed Envgroup reports a hostname |
| `url`, `host` | `https://<first observed hostname>`, and the hostname |
| `environment`, `targetServer` | the XR name, available before anything is observed |
| `cloud-url` | Apigee environment-groups console page for `spec.project` |
| `id` | observed Envgroup id |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/apigateway/gcp

kcl run packages/cloud/apigateway/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/apigateway/xrd/examples/apigateway-gcp.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/apigateway-gcp.yaml`](../xrd/examples/apigateway-gcp.yaml):

```bash
pnpm exec nx run apigateway-gcp:render     # or: just render apigateway-gcp
```

On a Kind cluster: `just e2e apigateway` (publish, install, apply every
example), `just install-module apigateway` (XRD + Compositions only) or
`just workload apigateway gcp` (module, providers, and this backend's example).
`just seed-apigateway-providers` regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `apigateway.k` | `backend_target` (URL → host/port/TLS), `render` and `status` |
| `apigateway_test.k` | `kcl test` cases |
| `composition.yaml` | `apigateway-gcp` Composition |

## Development

```bash
pnpm exec nx run apigateway-gcp:test     # kcl test
pnpm exec nx run apigateway-gcp:lint     # kcl lint
pnpm exec nx run apigateway-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
