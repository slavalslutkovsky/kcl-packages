# project

The only backend for the `Project` XR (`platform.example.org/v1alpha1`,
Composition `project`, the XRD's `defaultCompositionRef`). One client project
in one namespace: the cloud resources it needs and the apps that use them.

- **Cloud resources** are child XRs of the `cloud.example.org` capabilities.
  `spec.cloud.provider` (`aws` | `azure`) picks every child's Composition
  through `crossplane.compositionSelector.matchLabels.provider`; each
  capability keeps its own cloud mapping.
- **Apps** are rendered by [`packages/app`](../../../app/) (`app.lib`), one
  Release per entry, shaped by `kind`, plus an HTTPRoute and Dapr Components.
- **Wiring** comes from the children's observed status, as in
  [`appstack`](../../appstack/stack/): an app's `uses` become env vars, and the
  app is composed only once those resources (and its own identity) are ready.
  Once composed it stays composed, so a dependency that flaps never deletes a
  running workload.

The XR is namespaced and composes only into its own namespace, the client's
tenant boundary: no ClusterRole, CRD or Namespace. Create the namespace (and an
operator's CRDs) from the platform layer, e.g. a `fleet` team.

## Clouds and backends

| capability | XR | aws | azure | in-cluster option |
| --- | --- | --- | --- | --- |
| `databases` | `PostgresInstance` | `aws` (RDS) | `azure` (Flexible Server) | `cnpg` |
| `caches` | `RedisInstance` | `aws` (ElastiCache) | `valkey` (default: no azure backend) | `valkey` |
| `queues` | `Queue` | `aws` (SQS) | none: the render fails | none |
| `buckets` | `Bucket` | `aws` (S3) | `azure` (Storage) | `rustfs` |
| `registries` | `Registry` | `aws` (ECR) | `azure` (ACR) | `zot` |
| app `identity` | `WorkloadIdentity` | IRSA role | user-assigned identity + federated credential | n/a |

A resource's `backend` is its project's cloud or its in-cluster option; any
other cloud fails the render. Child spec = project defaults (`region`,
`deletionPolicy`, `resourceGroup` on azure databases and registries), then the
resource's own `spec` (deep merge, validated by the child's XRD), then tags
(`cloud.tags`, then the resource's, then `project` / `client` / `environment`,
which always win) and the selector from `backend`.

Required on azure: `cloud.resourceGroup` once a database, registry or identity
exists. Required on either cloud once an app has an `identity`:
`cloud.oidcIssuer` (EKS: the IAM OIDC provider ARN; AKS: the issuer URL).

## App kinds

| kind | renders | defaults |
| --- | --- | --- |
| `cli` | Job, CronJob with `schedule` | `command`, `args`, `schedule` are cli-only |
| `ui` | Deployment + Service | 2 replicas, no scrape annotations; may have a `route` |
| `api` | Deployment + Service | 2 replicas, Prometheus scrape annotations; may have a `route` |
| `operator` | ServiceAccount, Role, RoleBinding, Deployment | 1 replica, no Service; Role = `rules` + leader election (leases, events); `WATCH_NAMESPACE` = the namespace |
| `dapr-server` | Deployment + Service | api + `dapr.io/enabled`, `app-id`, `app-port` (= `port`), `app-protocol`; may have a `route` |
| `dapr-client` | Deployment | 1 replica, no Service; `dapr.io/enabled`, `app-id`, no app port |

Every app: `image` (its tag becomes `app.kubernetes.io/version` unless
`version` is set), `port` (8080), `replicas`, `env`, `config` (ConfigMap
`<name>-config`, envFrom), `secrets` (ExternalSecret into `<name>-secrets`,
envFrom; store defaults to `cloud.secretStore`: `aws-secrets-manager` /
`azure-key-vault`), `uses`, `identity.accessPolicies`, and `overrides`, which is
deep-merged over the generated `app.Workload` / `app.Task` (probes, resources,
hpa, scaler, monitoring, volumes, ...).

With `identity`, the `WorkloadIdentity` child composes ServiceAccount `<name>`
(it carries the role ARN / client ID); the app references it, and on azure its
pods get the `azure.workload.identity/use` label.

## Labels and placement

- `spec.labels` go on every composed object and every app pod; `apps[].labels`
  on that app's objects and pods. The project's identity labels
  (`app.kubernetes.io/part-of`, `platform.example.org/project`, `/client`,
  `/environment`) win on a clash. Pod labels are what OpenCost allocates by.
- `spec.placement.nodeSelector` / `tolerations` go on every app's pods
  (Deployments and Jobs alike). Scheduling only: the nodes must already be
  labelled and tainted. [`packages/epics`](../../../epics/) sets both from
  Jira epics — a dedicated pool for paying customers, the shared pool for
  the rest.

## Wiring

For each resource in `uses`, prefixed with its upper-cased name
(`orders-db` → `ORDERS_DB_`), only once the child has published the value:

| capability | env vars |
| --- | --- |
| database | `_HOST`, `_PORT`, `_NAME`, `_USER`, `_URL`, `_PASSWORD` (secretKeyRef) |
| cache | `_HOST`, `_PORT`, `_URL`, `_PASSWORD` (secretKeyRef, when auth is on) |
| queue | `_NAME`, `_URL`, `_TOPIC`, `_DLQ_URL` |
| bucket | `_NAME`, `_URL`, `_ENDPOINT`, `_REGION` |
| registry | `_NAME`, `_ENDPOINT`, `_URL` |

A wired variable wins over an `env` entry of the same name. Dapr Component
metadata can take `fromResource: {name, field}`: a status field of a resource
(`field: password` → its auth Secret as a `secretKeyRef`); the component is
composed once every such value is published.

## Composed resources

`composition-resource-name`s: `<capability>.<name>` for children
(`database.orders-db`), `identity.<app>`, `app.<app>.<kind>.<object>` for app
objects (`app.api.deployment.api`), `dapr.<component>`. `status()` reads them
back, so renaming them breaks status.

Status: `ready` (every resource and identity ready, every workload has an
available replica, every cli app composed), `provider`, `resources.<name>`
(`kind`, `backend`, `ready`), `identities.<app>`, `apps.<name>` (`phase`
Waiting / Composed / Ready, `availableReplicas`, `waitingFor`), `message`.

## Usage

`main.k` renders `render(oxr, ocds) + [status(oxr, ocds)]` under `items`.
Without `option("params")` it uses a built-in aws example:

```bash
kcl run packages/platform/project/composite
kcl run packages/platform/project/composite \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/project/xrd/examples/project-azure.yaml)}"
```

In a cluster: `just install-module project` applies the XRD and the
Composition; [`../xrd/providers.yaml`](../xrd/providers.yaml) is the
ClusterRole that lets Crossplane compose the app kinds (including `escalate` /
`bind` on Roles for operators). The children resolve only once their own
modules and providers are installed for the chosen cloud (`postgres`, `redis`,
`queue`, `bucket`, `registry`, `workload-identity`), plus Gateway API,
external-secrets and Dapr for routes, secrets and Dapr apps.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `project.k` | capability and app-kind tables, validation, `render`, `status` |
| `project_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |
| `../xrd/` | XRD, functions, ClusterRole, aws and azure examples |

## Development

```bash
pnpm exec nx run project:test     # kcl test
pnpm exec nx run project:lint     # kcl lint
pnpm exec nx run project:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
