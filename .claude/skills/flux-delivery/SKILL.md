---
name: flux-delivery
description: How FluxCD is actually used in this repo — the Component XR that composes a Flux source plus a delivery object, the manager package that renders HelmRepository/HelmRelease pairs, the OCI artifact flow through the kind registry, and which Flux features are deliberately absent. Use when touching packages/platform/component, packages/manager, devkit.toml, or anything that reconciles into a cluster.
when_to_use: Triggered by Flux, GitOps, OCIRepository, GitRepository, HelmRepository, Kustomization, HelmRelease, reconcile, artifact push, devkit waves, or CD onto the kind clusters.
paths:
  - packages/platform/component/**
  - packages/manager/**
  - manifests/**
  - devkit.toml
---

# FluxCD in this workspace

Flux appears in exactly three roles, plus `packages/gitops`, whose `engine: flux | argocd` renders either a Flux `GitRepository` + `Kustomization` or an Argo CD `AppProject` + `Application` (schemas: `packages/providers/argocd`, argoproj/argo-cd v3.5.3), and the `GitOpsPlatform` XR (`packages/platform/gitopsplatform`), which installs the `flux2` or `argo-cd` chart through provider-helm once its database check passes or its fallback `PostgresInstance` is ready. That XR is the only Argo CD install in the repo; nothing else reconciles.

## A. Crossplane-composed Flux — the `Component` XR

`packages/platform/component/xrd/xrd.yaml` defines `components.platform.example.org` (`platform.example.org/v1alpha1`, Namespaced, `defaultCompositionRef: component-flux`). Composition `component-flux` runs `packages/platform/component/flux` through function-kcl and emits **exactly two objects** into the XR's namespace:

| composition-resource-name | object |
| --- | --- |
| `source` | `source.toolkit.fluxcd.io/v1` `OCIRepository` \| `GitRepository` \| `HelmRepository` |
| `delivery` | `kustomize.toolkit.fluxcd.io/v1` `Kustomization` \| `helm.toolkit.fluxcd.io/v2` `HelmRelease` |

`component.k` declares no schemas — one constant plus `_flag`, `_emit`, `render`, `_ready_condition`, `_is_ready`, `_condition_message`, `status`. Typed against the generated packages `flux-source`, `flux-kustomize`, `flux-helm` under `packages/providers/`.

Three combinations are rejected at render time (asserts, with the fix in the message):

1. `Kustomization` + `HelmRepository` — kustomize-controller has no such `sourceRef` kind.
2. `HelmRelease` fed by a `GitRepository`/`HelmRepository` without `spec.deliver.chart`.
3. `spec.source.insecure` on anything but an `OCIRepository`.

Behaviour worth knowing before editing `render`:

- OCI + `HelmRelease` ⇒ `chartRef: {kind: OCIRepository, name}` and `layerSelector.mediaType = application/vnd.cncf.helm.chart.content.v1.tar+gzip`; any other source ⇒ `chart.spec.sourceRef` and `chartRef: None`.
- `HelmRepository` with an `oci://` url gets `type: oci` automatically.
- `_emit` strips `None` fields and stamps `krm.kcl.dev/composition-resource-name`; composed objects carry **no namespace** (Crossplane places them).
- Defaults: source interval `1m`, delivery interval `5m`, timeout `5m`, `prune`/`wait` true, both remediation retry counts 3.
- `status` folds the two Ready conditions into `ready`, `sourceReady`, `deliveryReady`, `sourceRevision`, `appliedRevision` (`lastAppliedRevision` for a Kustomization, `history[0].chartVersion` for a HelmRelease), `message`.

## B. Declaratively rendered Flux — `packages/manager`

`packages/manager/lib.k` renders one `HelmRepository` + `HelmRelease` pair per `Dependency` from a values file into `flux-system`, ordered by `HelmRelease.spec.dependsOn`, labelled `platform.example.org/type: manager|application`. `schema Manager` carries `role: "manager" | "workload"`; the `workload` overlay (`values.workload.yaml`) drops the manager-only charts (crossplane).

Applied in two passes because the charts install the CRDs the later objects need — see `just e2e-manager-apply`: Namespaces + HelmRepository + HelmRelease first, `kubectl wait helmrelease --all --for=condition=Ready`, then everything.

## C. Bootstrap Flux — `packages/cloud/cluster/onprem`

Installs the `flux2` (2.19.0) and `flux2-sync` (1.15.0) charts into an adopted cluster through provider-helm `Release`s; `flux2-sync` is only rendered once `flux2` is deployed. Its values carry the `GitRepository` + `Kustomization` that point at an **external** fleet repo.

## The artifact path (what Flux actually pulls)

Two different OCI artifact kinds, do not confuse them:

- **KCL packages** — `oci://docker.io/yurikrupnik/<pkg>?tag=<version>` in every `composition.yaml`. Pulled by **function-kcl inside Crossplane**, never by Flux.
- **Rendered manifests** — `just component-push <name> <tag>` runs `kcl run packages/app -D values=manifests/apps/<name>.yaml > tmp/components/<name>/manifests.yaml` then `flux push artifact oci://localhost:5001/components/<name>:<tag> --path=… --source=kcl-packages --revision=<tag>`. This is the only `flux` CLI call in the repo, and the artifact a `Component`'s `OCIRepository` fetches from `oci://172.18.0.100:80/components/<name>`.

Registry addressing: push from the host at `localhost:5001`, pull from inside the cluster at `172.18.0.100:80` (container `kind-registry`, `just registry`). `docker.io/yurikrupnik` references are rewritten to the local registry in two places — `sed` in `just install-module`, and `KCLX_SOURCE_REWRITE` in `manifests/crossplane/functions.yaml`.

## Clusters

| cluster | created by | config |
| --- | --- | --- |
| `kind-kcl-e2e` | `devkit cluster create` / `just e2e-up` / `just up` | root `devkit.toml` — flux2 in wave 0, crossplane functions wave 2, XRDs/Compositions waves 2–5 |
| `kind-kcl-manager` | `just e2e-manager-up` | `manifests/manager/devkit.toml` — flux2 only; everything else arrives as manager HelmReleases |

## Deliberately absent — do not "restore" these

- No `flux bootstrap` of this repository, no `flux-system` kustomization tree, no `clusters/`, `environments/`, or overlay directories. The multi-environment axis here is the values overlay (`<stem>.<env>.yaml`, `-D env=<name>`) plus the `manager|workload` role.
- No `ImageRepository` / `ImagePolicy` / `ImageUpdateAutomation` / `Alert` / `Receiver`. Both devkit.toml files disable `imageAutomationController`, `imageReflectionController` and `notificationController` on the flux2 chart. Version bumps come from `nx release`, not from image automation.

## Commands

```bash
just component-push app1 v1        # values -> rendered manifests -> Flux OCI artifact
just e2e-component                 # kclx + artifact + component package + waves, waits on component/app1
just e2e-manager [manager|workload]  # manager cluster: flux2, HelmReleases, checks, status
just e2e-manager-status
kubectl -n default get component,ocirepository,kustomization,helmrelease
flux get all -A
```

## Workflows

`/flux-ship` runs the artifact → Component → reconcile path end to end and verifies both halves became Ready.
