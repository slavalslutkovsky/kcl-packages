# platform-addons

The addons a client's repositories need, as Flux or Argo CD install objects.
The ClientPlatform controller (toolkit `kcl-operator`) scans the client repos
from their Flux source artifacts before they are applied, reads the client's
`ClientConfig` from its bucket, and renders this package with what it saw. It
writes the result to a KclModule, which applies, prunes and reports health.

Detection maps API groups and kinds to catalog rows: a Kyverno `ClusterPolicy`
installs Kyverno, a `storage.gcp.m.upbound.io` Bucket installs Crossplane and
the GCP storage provider. Platform XRs (`platform.shluviza.com`) install their
API and only the operator their `spec.provider` selects: an XCanary on
`flagger` never installs Argo Rollouts. Crossplane providers are installed for
the client's main cloud only. Installs are sticky: an addon stays until the
config says `remove: true`.

## Usage

```bash
kcl run packages/platform-addons -D params=packages/platform-addons/examples/params-flux.yaml
kcl run packages/platform-addons -D params=packages/platform-addons/examples/params-argo.yaml
kcl run packages/platform-addons -D params="$(yq -o json -I0 . params.yaml)"

just platform-addons                                              # examples/params-flux.yaml
kcl test ./...                                                    # in packages/platform-addons
```

`-D params=` takes the params object (what kcl-render passes the operator's
KclModule) or a path to a YAML file holding it. With neither, an empty client
renders: no items, no addons.

From the published package: `kcl run oci://docker.io/yurikrupnik/platform-addons -D params=…`
(nx release publishes every `lang:kcl` package to `docker.io/yurikrupnik/<name>`,
tagged `<version>`; the ClientPlatform's `spec.module.source` is
`oci://docker.io/yurikrupnik/platform-addons?tag=0.1.0`).
In code: `import platform_addons.lib as addons; addons.plan(addons.Params {**params})`.

## Inputs

`option("params")`:

| key | meaning |
| --- | --- |
| `client` | `<namespace>/<name>` of the ClientPlatform |
| `config` | the `ClientConfig` below; every `valuesFile` already resolved into `values` |
| `detected` | one row per (group, kind): `group` (`""` for core), `kind`, `versions`, `count`, `providers` (distinct `spec.provider` values), `sources` |
| `provided` | groups the client defines itself (CRDs, XRDs); never mapped |
| `previous` | addons state.json says are installed |

`ClientConfig`:

| key | default | meaning |
| --- | --- | --- |
| `cloud` | required | `gcp` / `aws` / `azure`: the only cloud whose Crossplane providers install |
| `delivery` | `flux` | `flux` or `argo` |
| `namespace` | `flux-system` | Where Flux objects go (Argo CD Applications always go to `argocd`) |
| `platformSource.flux` | `GitRepository/flux-system` in `flux-system` | Source of the platform paths (`api/<x>`, `platform/crossplane/...`) on Flux |
| `platformSource.argo` | `https://github.com/shluviza/gitops.git` @ `main` | The same on Argo CD |
| `crossplane.families` | `[]` | Families of `cloud` to install whatever is detected |
| `crossplane.extraClouds` | `[]` | More clouds whose providers may install when detected |
| `crossplane.vars` | `{}` | Flux `postBuild.substitute` / `flux-envsubst` plugin env for the provider and ProviderConfig paths |
| `addons.<name>` | | `enabled` (true forces on, false off), `remove` (sticky removal), `version`, `values`, `namespace`; a name outside the catalog is a custom addon with exactly one of `helm {repo, chart, version, releaseName}`, `kustomize {platformPath \| url, ref, path}`, `manifests {url, ref, path}`, plus `dependsOn` |

For a catalog addon, `version` and `values` reach its first Helm release (the
main chart; `istiod` for istio) or its manifests ref, deep-merged over the
catalog's values (config wins, lists replace). Other keys on a catalog name
are ignored.

Rejected by schema checks: an unknown `cloud` or `delivery`, a custom addon
with zero or several install types, a `requires`/`dependsOn` naming no addon,
a cycle in requires, a `valuesFile` that was not resolved, and a
`crossplane.families` entry that is not a family of `cloud`.

## Outputs

Top-level variables, not a YAML stream:

| variable | content |
| --- | --- |
| `items` | What the KclModule applies. Only kinds whose CRDs exist before any addon: Flux `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmRelease`, `Kustomization`, Argo CD `Application`, core `Namespace`/`ConfigMap` (enforced by a check). A Provider or ProviderConfig here would fail the KclModule's dry-run for the whole render |
| `addons` | Sorted by name: `{name, installed, required, reasons, dependsOn}` |
| `unmapped` | `group/Kind` of detected, non-builtin, non-provided groups no addon serves |
| `warnings` | Detection the plan ignores: another cloud's provider, an unknown `spec.provider`, a required addon the config removes, empty `crossplane.vars` |

`required` is needed by detection or by a transitive `requires` of what is.
`installed` is `(required or previous or enabled) and not (remove or enabled: false)`,
closed over `requires` (a removed dependency stays removed and warns).
`reasons`: `kyverno.io/ClusterPolicy`, `platform.shluviza.com/XCanary provider=flagger`,
`platform.shluviza.com/XDataLake cloud=gcp`, `requires:<addon>`, `previous`, `config`.

Every object carries `platform.shluviza.com/addon: <addon>` and
`app.kubernetes.io/managed-by: platform-addons`, and is named `<addon>` or
`<addon>-<unit>` (`istio-istiod`, `crossplane-functions`).

**Flux** (all in `config.namespace`): per Helm release a `HelmRepository`
(`type: oci` for `oci://`) and a `HelmRelease` (`helm.toolkit.fluxcd.io/v2`)
with `targetNamespace`, `install.createNamespace`, CRDs `CreateReplace`
(dapr: `Skip` on upgrade, as gitops), remediation retries 3 and inline
`values`. Per kustomize path or manifests directory a `Kustomization`
(`prune`, `wait`, `retryInterval: 1m`) on the platform source, or on its own
`GitRepository` / `OCIRepository` for a URL; crossplane paths get
`postBuild.substitute`. `dependsOn` only reaches the same kind: HelmReleases
wait on HelmReleases, Kustomizations on Kustomizations. Across kinds (the
`api-*` Kustomizations after the crossplane HelmRelease) ordering comes from
Flux retrying the dry-run until the CRDs exist.

**Argo CD**: one `Application` per Helm release or path in `argocd`, project
`default`, destination `https://kubernetes.default.svc` and the addon
namespace, `automated {prune, selfHeal}`, `CreateNamespace=true`,
`ServerSideApply=true`, the cascade finalizer, and
`argocd.argoproj.io/sync-wave` = dependency depth. Helm sources set
`helm.releaseName` and `helm.valuesObject`. An OCI chart repo loses its
`oci://` in `repoURL` and gets a credential-free repository Secret
`repo-<addon>[-<unit>]` (`enableOCI: "true"`), which Argo CD needs even for a
public registry; manifests set `directory.recurse`; substituting
platform paths use the `flux-envsubst` plugin
(vendor/gitops/argocd/install/cmp-flux-envsubst.yaml) with `crossplane.vars`
as env.

## Catalog

`lib/catalog.k`. Versions are gitops' (`vendor/gitops/platform/<op>/release.yaml`);
"platform rev" paths follow `platformSource`.

| addon | triggers | install | version | requires |
| --- | --- | --- | --- | --- |
| `kyverno` | `kyverno.io`, `wgpolicyk8s.io`, `*.kyverno.io` | helm `kyverno` | 3.9.1 | — |
| `gatekeeper` | `*.gatekeeper.sh` | helm `gatekeeper` | 3.23.1 | — |
| `flagger` | `flagger.app` | helm `flagger`, `loadtester` | 1.45.0, 0.39.0 | istio |
| `argo-rollouts` | `argoproj.io` Rollout, AnalysisTemplate, ClusterAnalysisTemplate, AnalysisRun, Experiment | helm `argo-rollouts` | 2.43.12 | — |
| `chaos-mesh` | `chaos-mesh.org` | helm `chaos-mesh` | 2.8.8 | cert-manager |
| `litmus` | `litmuschaos.io` | helm `litmus-core` | 3.31.1 | — |
| `k6` | `k6.io` | helm `k6-operator` | 4.7.0 | — |
| `testkube` | `testkube.io`, `*.testkube.io` | helm `testkube` | 2.15.3 | cnpg |
| `kafka` | `kafka.strimzi.io` | helm `strimzi-kafka-operator` | 1.3.1 | — |
| `nats` | `jetstream.nats.io` | helm `nats`, `nack` | 2.15.3, 0.36.0 | — |
| `cnpg` | `postgresql.cnpg.io` | helm `cloudnative-pg` | 0.29.1 | — |
| `cert-manager` | `cert-manager.io`, `acme.cert-manager.io` | helm `cert-manager` | v1.21.2 | — |
| `external-secrets` | `external-secrets.io`, `*.external-secrets.io` | helm `external-secrets` | 2.11.0 | — |
| `keda` | `keda.sh`, `eventing.keda.sh` | helm `keda` | 2.21.0 | — |
| `dapr` | `dapr.io` | helm `dapr` | 1.18.4 | — |
| `istio` | `networking`, `security`, `telemetry`, `extensions` `.istio.io` | helm `base`, `cert-manager-istio-csr`, `istiod`, `cni`, `ztunnel` | 1.30.5 (csr v0.18.0) | cert-manager |
| `tekton` | `tekton.dev`, `triggers.tekton.dev` | kustomize `./platform/tekton/pipelines` (Pipelines v1.16.0) | platform rev | — |
| `gateway-api` | `gateway.networking.k8s.io` | manifests `kubernetes-sigs/gateway-api` `./config/crd/standard` | v1.5.1 | — |
| `crossplane` | `pkg`, `apiextensions`, `ops`, `protection` `.crossplane.io` | helm `crossplane`, kustomize `./platform/crossplane/functions` | 2.4.0 | — |
| `crossplane-keycloak` | `keycloak.crossplane.io`, `*.keycloak.crossplane.io`, `*.keycloak.m.crossplane.io` | kustomize `providers/keycloak`, `config/keycloak` | platform rev | crossplane |
| `crossplane-<cloud>` | — (required by its families) | kustomize `providers/<cloud>/runtime`, `config/<cloud>` | platform rev | crossplane |
| `crossplane-<cloud>-<family>` | `<family>.<cloud>.m.upbound.io`, `<family>.<cloud>.upbound.io` (opentofu: `opentofu.m.upbound.io`, `opentofu.upbound.io`) | kustomize `providers/<cloud>/<family>` (+ `config/opentofu`) | platform rev | crossplane, crossplane-<cloud> |
| `api-xcanary` | XCanary | kustomize `./api/xcanary` | platform rev | crossplane; provider `flagger` → flagger, `argo-rollouts` → argo-rollouts |
| `api-xchaosexperiment` | XChaosExperiment | `./api/xchaosexperiment` | platform rev | crossplane; `chaos-mesh`, `litmus`, `both` |
| `api-xpolicy` | XPolicy | `./api/xpolicy` | platform rev | crossplane; `kyverno`, `gatekeeper`, `both` |
| `api-xloadtest` | XLoadTest | `./api/xloadtest` | platform rev | crossplane; `k6`, `testkube` |
| `api-xstream` | XStream | `./api/xstream` | platform rev | crossplane; `kafka`, `nats` |
| `api-xpostgres` | XPostgres | `./api/xpostgres` | platform rev | crossplane; `cnpg`, `cloudsql` → crossplane-gcp-sql + api-xpostgresinstance |
| `api-xpostgresinstance` | XPostgresInstance | `./api/xpostgresinstance` | platform rev | crossplane, crossplane-gcp-sql |
| `api-xdatalake` | XDataLake | `./api/xdatalake` | platform rev | crossplane; per cloud: gcp storage + opentofu, aws s3 + glue + iam, azure storage + managedidentity + authorization |
| `api-xproject` | XProject | `./api/xproject` | platform rev | crossplane, crossplane-gcp-cloudplatform |
| `api-xtenant` | XTenant | `./api/xtenant` | platform rev | crossplane, external-secrets |

Families: gcp `cloudplatform`, `storage`, `sql`, `opentofu`; aws `s3`, `glue`,
`iam`; azure `storage`, `managedidentity`, `authorization`. A family of a
cloud that is neither `cloud` nor in `extraClouds` never installs; detecting
it (or an XR needing it, e.g. XPostgres `cloudsql` off gcp, XProject off gcp)
is a warning. `config/<cloud>` waits for nothing outside its addon and no
family waits for it: its ClusterProviderConfig needs the CRD a family brings.

XTenant also composes `XCluster`, which gitops serves from no `api/` path;
those XTenants need it from elsewhere.

### Dropped from gitops

Mgmt-only lines, not carried into client installs:

| addon | dropped |
| --- | --- |
| all | HTTPRoutes on main-gateway (`route/`), Kyverno PolicyExceptions, `reconcile.fluxcd.io/watch` ConfigMap labels (values are inline) |
| kyverno | the `kyverno-policies` release (mgmt's Pod Security policy set) |
| gatekeeper | gatekeeper-policy-manager (UI, generated session Secret), `library/` ConstraintTemplates |
| flagger | `metricsServer: ${FLAGGER_METRICS_SERVER}` (chart default Prometheus address) |
| litmus | ChaosCenter release `litmus` (UI, MongoDB, `${LITMUS_HOSTNAME}`, generated admin Secrets) |
| testkube | MinIO credentials from Secret `testkube-minio` (`secrets.yaml`); chart defaults apply |
| kafka | the `shluviza` Kafka instance and kafka-ui |
| nats | `config.cluster.replicas: ${NATS_REPLICAS}` (chart default), the EVENTS/TODO/XSTREAM accounts and their ESO-generated passwords, NUI; NACK's URL with the `xstream` password (the chart's default URL applies; set `jetstream.nats.url` through values if it does not reach `nats.nats.svc:4222`) |
| istio | `global.platform: ${ISTIO_PLATFORM}` (set it to `gke` through values on GKE), istiod's `oauth2-proxy` extension provider (main-gateway SSO) |
| tekton | Pipelines-as-Code, `ci`, `flows`; gitops installs no Tekton Triggers, so `triggers.tekton.dev` objects get Pipelines only |
| external-secrets | the platform `ClusterSecretStore` |
| dapr | `namespace-defaults` and `pubsub` |

NACK keeps gitops' `namespaced: true` (it watches the `nats` namespace only),
gatekeeper its exempt-namespace list.

## Adding an addon

1. Add a row to `lib/catalog.k`: `name`, `namespace`, `triggers` (`group`,
   `suffix`, optional `kinds`), one or more `helm` / `kustomize` /
   `manifests` units (`id` for every unit after the first, `dependsOn` for
   order inside the addon), `requires`. Copy the version and values from
   `vendor/gitops/platform/<op>/` and drop mgmt-only lines.
2. For a platform XR, add `_api("XFoo", requires, providers, cloudRequires)`
   with the `spec.provider` enum of `api/xfoo/definition.yaml`.
3. Add the row to the table above and a test to `platform_addons_test.k`;
   `test_catalog_targets` checks every provider and cloud target exists.
