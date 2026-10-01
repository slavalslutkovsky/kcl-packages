# cluster-onprem

On-prem backend for the `KubernetesCluster` XR (`cloud.example.org/v1alpha1`).
Nothing is provisioned: the XR adopts an existing cluster through a kubeconfig
Secret next to the XR, and composes what runs on top of it — FluxCD,
Crossplane and a Flux GitOps entrypoint — as pinned Helm releases. Typed
against the `helm` schema package (`packages/providers/helm`); every `Release`
goes through a per-XR `ProviderConfig` built from the kubeconfig, so it lands in
the adopted cluster, not the management cluster. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/cluster-onprem` through the `cluster-onprem`
Composition (label `provider: onprem`).

## Composed resources

All are `helm.m.crossplane.io/v1beta1`. Each `Release` has external-name =
its release name, `wait: true`, `waitTimeout: 10m`.

| resource | when | notes |
| --- | --- | --- |
| `ProviderConfig` `providerconfig` | always | named after the XR; credentials from Secret `kubeconfigSecret`, key `kubeconfig`, in the XR's namespace; annotated `krm.kcl.dev/ready: "True"` |
| `Release` `flux2` | `bootstrap.flux.enabled` (default `true`) | fluxcd-community `flux2` chart into `flux-system` |
| `Release` `flux2-sync` | `bootstrap.sync` set **and** the `flux2` Release observed `deployed` | `flux2-sync` chart into `flux-system`: a `GitRepository` + `Kustomization` (`prune: true`, `wait: true`) |
| `Release` `crossplane` | `bootstrap.crossplane.enabled` (default `true`) | `crossplane` chart from `https://charts.crossplane.io/stable` into `crossplane-system` |

Chart versions are pinned in `cluster.k`; `bootstrap.flux.version` and
`bootstrap.crossplane.version` override them. The `flux2-sync` chart version
has no override.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | site label; only used in `status.id` (`<region>/<xr>`) |
| `kubeconfigSecret` | `ProviderConfig.spec.credentials.secretRef.name` (required) |
| `bootstrap.flux.enabled` / `.version` | `flux2` Release on/off and chart version |
| `bootstrap.crossplane.enabled` / `.version` | `crossplane` Release on/off and chart version |
| `bootstrap.sync.url` | `gitRepository.spec.url` |
| `bootstrap.sync.tag` / `.branch` | `gitRepository.spec.ref`: `tag` if set, else `branch` (default `main`) |
| `bootstrap.sync.secretRef` | `gitRepository.spec.secretRef.name` (a Secret in the adopted cluster's `flux-system`) |
| `bootstrap.sync.path` | `kustomization.spec.path` (default `./`) |
| `bootstrap.sync.interval` | both `interval`s (default `5m`) |
| `deletionPolicy` | `Orphan` → Releases get `managementPolicies: [Observe, Create, Update, LateInitialize]`, keeping what was installed |

Ignored: `nodeCount`, `nodeSize`, `tags`. The render fails without
`kubeconfigSecret`; when `version`, `autoscaling`, `machineType`, `spot`,
`network` or `resourceGroup` is set; and when `bootstrap.sync` is set with
`bootstrap.flux.enabled: false`.

Status written back: `provider: onprem`, `ready` (every requested Release
observed `deployed`), `name` (XR name), `kubeconfigSecret` (the spec value),
`id` (`<region>/<xr>`). No `endpoint`, `version` or `cloud-url`.

## Usage

Without `option("params")`, `main.k` renders a built-in example: site `dc1`,
`example-kubeconfig`, a sync to `https://github.com/example/fleet`. With no
observed state, that renders the `ProviderConfig`, `flux2` and `crossplane`.

```bash
kcl run packages/cloud/cluster/onprem

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/cluster/onprem \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/cluster/xrd/examples/cluster-onprem.yaml)}"

# second pass: flux2 observed deployed, so flux2-sync is rendered too
kcl run packages/cloud/cluster/onprem \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/cluster/xrd/examples/cluster-onprem.yaml), \"ocds\": {\"flux2\": {\"Resource\": {\"status\": {\"atProvider\": {\"state\": \"deployed\"}}}}}}"
```

The output has `items` (the managed resources, then the `KubernetesCluster`
carrying status) next to the module's public constants (chart repositories,
versions, namespaces, `kubeconfig_key`).

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/cluster-onprem.yaml`:

```bash
pnpm exec nx run cluster-onprem:render
```

On a cluster: `just install-module cluster`, or `just e2e cluster` end to end.
Needs `provider-helm` (v1.x, for the namespaced `helm.m.crossplane.io` CRDs)
from [`../xrd/providers.yaml`](../xrd/providers.yaml), and the kubeconfig
Secret in the XR's namespace before the XR is applied.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `cluster.k` | Pinned charts, `render(oxr, ocds)`, `status(oxr, ocds)`, `deployed` |
| `cluster_test.k` | ProviderConfig, releases, version overrides, opt-outs, sync gating and values, deletion policy, status |
| `composition.yaml` | `cluster-onprem` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run cluster-onprem:test     # kcl test
pnpm exec nx run cluster-onprem:lint     # kcl lint
pnpm exec nx run cluster-onprem:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
