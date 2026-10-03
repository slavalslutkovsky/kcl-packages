# forge-forgejo

The only backend for the `Forge` XR (`cloud.example.org/v1alpha1`,
namespaced): one self-hosted Forgejo per tenant namespace. Typed against the
[`helm`](../../../providers/helm) provider schema package, it composes one
provider-helm `Release` of the upstream Forgejo chart into the XR's own
namespace. Run by `function-kcl` (`target: Default`) from
`oci://docker.io/yurikrupnik/forge-forgejo`, then `function-auto-ready`.

This is a paid capability gated by
[`entitlement`](../../../platform/entitlement): the first item emitted is a
`meta.krm.kcl.dev/v1alpha1` `RequiredResources` request for the cluster-scoped
`Entitlement` named after the XR's namespace. Nothing is composed until that
record is fetched and grants the feature `forgejo`; a missing record or feature
is a fatal render with zero resources. `target: Default` is required for
function-kcl to dispatch that meta-kind.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `RequiredResources` (`meta.krm.kcl.dev`) | | always | Fetches `Entitlement/<namespace>`; not a composed resource |
| `Release` (`helm.m.crossplane.io`) | `managed` | gate resolved and entitled | external-name `<name>`; chart `forgejo` from `oci://code.forgejo.org/forgejo-helm`; `ClusterProviderConfig` `default`; `wait: true`, `waitTimeout: 10m` |

`deletionPolicy: Orphan` sets `managementPolicies` to
`Observe, Create, Update, LateInitialize`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml). All map into
`spec.forProvider.values` of the Release.

| spec field | chart values | notes |
| --- | --- | --- |
| `hostname` | `ingress.hosts[0].host`, `gitea.config.server.DOMAIN`, `ROOT_URL` | required |
| `storageGb` | `persistence.size` | default 10; above the plan's `quota.storageGb` fails the render |
| `adminSecret` | `gitea.admin.existingSecret` | Secret with `username`/`password` keys |
| `database.mode` | `gitea.config.database.DB_TYPE` | `sqlite` (chart default) or `postgres` |
| `database.host` / `name` / `user` | `HOST` / `NAME` / `USER` | `host` required for `postgres`; `name`, `user` default `forgejo` |
| `database.passwordSecret` | `gitea.additionalConfigSources` | key (default `password`) projected to path `database`; its value must be `PASSWD=<password>` |
| `ingress.enabled` | `ingress.enabled` | default true |
| `ingress.className` | `ingress.className` | |
| `ingress.tlsSecretName` | `ingress.tls` | also switches `ROOT_URL` and `status.url` to `https` |
| `highAvailability` | `replicaCount: 2`, `ReadWriteMany`, db indexer/session | needs plan `enterprise` and `database.mode: postgres` |
| `chartVersion` | Release `chart.version` | default `17.1.5` |
| `imageTag` | `image.tag` | |
| `values` | deep-merged last | escape hatch; wins over everything above |
| `deletionPolicy` | `managementPolicies` | |

`fullnameOverride` is always the XR name, so the web Service is `<name>-http`.

Status written back: `ready` (Release `Ready` condition), `url`, `apiUrl`
(`http://<name>-http.<namespace>.svc:3000/api/v1`, the value a `Repository`
XR's `spec.forge.baseUrl` takes), `service`, `plan`, `chartVersion` (observed
or requested), `release` (observed external-name).

## Usage

Without `option("params")`, `main.k` renders a built-in example (`git` in
`tenant-a`, host `git.tenant-a.example.org`) with an entitled `team`
record, so the Release is rendered. Without `requiredResources` the render is
the pending request only; a record without the feature fails:

```bash
kcl run packages/cloud/forge/forgejo
# pending: RequiredResources only
kcl run packages/cloud/forge/forgejo -D 'params={"oxr":{"metadata":{"name":"git","namespace":"tenant-a"},"spec":{"hostname":"git.tenant-a.example.org"}}}'
# entitled, external postgres, TLS
kcl run packages/cloud/forge/forgejo -D 'params={"oxr":{"metadata":{"name":"git","namespace":"tenant-a"},"spec":{"hostname":"git.tenant-a.example.org","storageGb":20,"database":{"mode":"postgres","host":"pg-rw.tenant-a.svc:5432","passwordSecret":{"name":"forge-db","key":"app-ini"}},"ingress":{"tlsSecretName":"git-tls"}}},"requiredResources":{"entitlement":[{"Resource":{"metadata":{"name":"tenant-a"},"spec":{"plan":"team","features":["forgejo"],"quota":{"storageGb":50}}}}]}}'
```

Local `kcl run` output also contains the module's public `chart_repository`,
`chart_name`, `default_chart_version`, `http_port` and `default_storage_gb`
next to `items`.

Against the working tree through `crossplane render` (needs docker), using
[`../xrd/examples/forge-forgejo.yaml`](../xrd/examples/forge-forgejo.yaml) and
the mocked record in
[`../xrd/required-resources/entitlement.yaml`](../xrd/required-resources/entitlement.yaml):

```bash
pnpm exec nx run forge-forgejo:render
```

On a cluster: `just install-module forge` or `just e2e forge`. The provider
is provider-helm ([`../xrd/providers.yaml`](../xrd/providers.yaml)) with
the `default` `ClusterProviderConfig` from
[`../xrd/providerconfigs.yaml`](../xrd/providerconfigs.yaml); the tenant's
`Entitlement` must exist (the `required-resources` file is one).

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry: entitlement request, gate, then `render` + `status` |
| `forge.k` | `chart_values`, `render` (Release), `status`, URL helpers |
| `forge_test.k` | `kcl test` cases: values mapping, ingress, policies, HA gate, status |
| `composition.yaml` | `forge-forgejo` Composition, label `provider: forgejo` |

## Development

```bash
pnpm exec nx run forge-forgejo:test     # kcl test
pnpm exec nx run forge-forgejo:lint     # kcl lint
pnpm exec nx run forge-forgejo:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
