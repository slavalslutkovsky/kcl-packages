---
name: flux-ship
description: Deliver an app through Flux on the kind cluster — render its manifests, push them as an OCI artifact, reconcile them through a Component XR, and verify the source and delivery objects actually became Ready.
argument-hint: "[app-name] [tag]"
arguments: app tag
disable-model-invocation: true
allowed-tools:
  - Read
  - Bash(just registry)
  - Bash(just component-push:*)
  - Bash(just e2e-publish:*)
  - Bash(just install-module:*)
  - Bash(just install-functions)
  - Bash(just e2e-component)
  - Bash(kubectl get:*)
  - Bash(kubectl describe:*)
  - Bash(kubectl wait:*)
  - Bash(kubectl config current-context)
  - Bash(flux get:*)
  - Bash(kcl run:*)
---

# Deliver through Flux

App: `$app` (default `app1`, values at `manifests/apps/$app.yaml`) · tag: `$tag` (default `v1`).

Read the `flux-delivery` skill first: the source/delivery kind matrix and the three render-time asserts decide whether the `Component` XR is even valid.

## Preflight

!`kubectl config current-context 2>/dev/null; docker ps -q -f name=^kind-registry$ >/dev/null 2>&1 && echo "kind-registry: up" || echo "kind-registry: down"; kubectl get crd ocirepositories.source.toolkit.fluxcd.io --request-timeout=3s >/dev/null 2>&1 && echo "flux CRDs: present" || echo "flux CRDs: absent or unreachable (flux2 chart is devkit wave 0)"`

Context must be `kind-kcl-e2e`. Flux CRDs come from the `flux2` chart in `devkit.toml` wave 0 — if they are absent, the cluster was never brought up with `devkit cluster deps`.

## Steps

1. **Render check.** `kcl run packages/app -D values=manifests/apps/$app.yaml -q` — this is the exact content that becomes the artifact. Fix render errors here, not after pushing.

2. **Push the artifact.** `just component-push $app $tag` → `flux push artifact oci://localhost:5001/components/$app:$tag --source=kcl-packages --revision=$tag`. The artifact is immutable per tag in practice; bump `$tag` rather than re-pushing when the content changed.

3. **Composition available?** The `Component` Composition pulls `component-flux` from the registry: `just e2e-publish component`, then `just install-module component` if the XRD/Composition are not applied yet (`just install-functions` first on a fresh cluster).

4. **Apply the Component XR.** Use `packages/platform/component/xrd/examples/component-flux.yaml` as the shape:

   ```yaml
   spec:
     source:
       kind: OCIRepository
       url: oci://172.18.0.100:80/components/$app   # in-cluster address, not localhost
       ref: {tag: $tag}
       insecure: true                                # plain-HTTP local registry; OCIRepository only
       interval: 1m
     deliver:
       kind: Kustomization
       targetNamespace: <ns>
   ```

   For a Helm chart instead: `source.kind: OCIRepository` + `deliver.kind: HelmRelease` (chartRef path, no `chart` needed), or a `HelmRepository` source **with** `deliver.chart` set — a `Kustomization` can never read a `HelmRepository`.

5. **Wait on the XR, not on apply:**

   ```bash
   kubectl -n <ns> wait --for=condition=Ready component/$app --timeout=5m
   ```

   `just e2e-component` does steps 1–5 end to end for `app1` on a fresh cluster.

6. **Verify both halves and the workload:**

   ```bash
   kubectl -n <ns> get component,ocirepository,kustomization,helmrelease
   flux get all -A
   kubectl -n <ns> get deploy,svc
   ```

   Report `status.sourceReady`, `status.deliveryReady`, `status.sourceRevision`, `status.appliedRevision` and the workload objects that actually appeared. On failure, read `status.message` from the XR and the Ready condition of whichever of the two objects is false — the XR status folds both, so name which one blocked.

Do not treat a Ready `OCIRepository` as delivery: the artifact being fetched says nothing about the Kustomization applying.
