# component-flux

The only backend for the `Component` XR (`platform.example.org/v1alpha1`,
Composition `component-flux`, the XRD's `defaultCompositionRef`). No cloud
account, no Crossplane provider, no managed resource: typed against the
[flux-source](../../../providers/flux-source/),
[flux-kustomize](../../../providers/flux-kustomize/) and
[flux-helm](../../../providers/flux-helm/) schema packages, it composes two
Flux objects in the XR's namespace — a source and the Kustomization or
HelmRelease that applies it — and leaves pull, diff and prune to the Flux
controllers. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/component-flux`.

## Composed resources

Both objects are named after the XR, so a sibling's `spec.dependsOn` can name
it.

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `OCIRepository` (`source.toolkit.fluxcd.io/v1`) | `source` | `source.kind: OCIRepository` (default) | `layerSelector` `application/vnd.cncf.helm.chart.content.v1.tar+gzip` / `copy` when delivered by a HelmRelease |
| `GitRepository` (`source.toolkit.fluxcd.io/v1`) | `source` | `source.kind: GitRepository` | |
| `HelmRepository` (`source.toolkit.fluxcd.io/v1`) | `source` | `source.kind: HelmRepository` | `type: oci` when `url` starts with `oci://` |
| `Kustomization` (`kustomize.toolkit.fluxcd.io/v1`) | `delivery` | `deliver.kind: Kustomization` (default) | `sourceRef` to the source above |
| `HelmRelease` (`helm.toolkit.fluxcd.io/v2`) | `delivery` | `deliver.kind: HelmRelease` | `chartRef` to an OCIRepository, else `chart.spec` from a Helm/Git source; install and upgrade remediation retries 3 |

Rejected combinations (render fails with an assert):

- `deliver.kind: Kustomization` with `source.kind: HelmRepository`;
- `deliver.kind: HelmRelease` from a Git or Helm source without `deliver.chart`;
- `source.insecure` on anything but an OCIRepository.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `source.url` | source `url` (required) |
| `source.ref.{tag,semver,digest}` | OCIRepository `ref`, only keys set |
| `source.ref.{branch,tag,semver}` | GitRepository `ref`, only keys set; HelmRepository ignores `ref` |
| `source.interval` | source `interval`, default `1m` |
| `source.insecure` | OCIRepository `insecure` |
| `source.secretRef` | source `secretRef.name` (an existing Secret) |
| `deliver.path` | Kustomization `path`, default `./` |
| `deliver.prune`, `deliver.wait` | Kustomization; default `true` each |
| `deliver.timeout` | `timeout` on either kind, default `5m` |
| `deliver.chart`, `deliver.version` | HelmRelease `chart.spec` for Helm/Git sources |
| `deliver.values` | HelmRelease `values`, verbatim |
| `deliver.targetNamespace` | `targetNamespace` on either kind |
| `interval` | delivery `interval`, default `5m` |
| `dependsOn` | delivery `dependsOn[].name` |
| `suspend` | delivery `suspend: true` |
| `serviceAccountName` | delivery `serviceAccountName` (impersonation) |

Status written back: `ready` (both objects `Ready=True`), `sourceReady`,
`deliveryReady`, `sourceRevision` (source `status.artifact.revision`),
`appliedRevision` (Kustomization `lastAppliedRevision`, or the HelmRelease's
newest history `chartVersion`), and `message` (the Ready message of the
source if it is not ready, else of the delivery).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` (`app1`, an OCIRepository
from the local kind registry delivered as a Kustomization):

```bash
kcl run packages/platform/component/flux
```

Pass a real XR the way function-kcl does:

```bash
kcl run packages/platform/component/flux \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/component/xrd/examples/component-podinfo-helm.yaml)}"
```

`pnpm exec nx run component-flux:render` (or `just render component-flux`)
renders `composition.yaml` through function-kcl against
`component-flux.yaml`; needs docker.

In a cluster (needs docker/kind): `just e2e-component` brings up the kclx
cluster, pushes `manifests/apps/app1.yaml` rendered by `packages/app` as a Flux
artifact (`just component-push`), publishes this package and waits for
`component/app1` to be Ready. `just e2e component` runs the generic module
flow; `just install-module component` applies only the XRD and the
Composition, repointed at the local registry. Crossplane needs the
ClusterRole in [`../xrd/providers.yaml`](../xrd/providers.yaml) to compose
Flux kinds.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `component.k` | `render` (source + delivery) and `status` |
| `component_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run component-flux:test     # kcl test
pnpm exec nx run component-flux:lint     # kcl lint
pnpm exec nx run component-flux:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
