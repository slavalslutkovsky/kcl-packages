## 0.1.1 (2026-11-25)

### 🚀 Features

- **platform-addons:** add package mapping client detection to addons ([d14670b](https://github.com/slavalslutkovsky/kcl-packages/commit/d14670b))

### ❤️ Thank You

- yurikrupnik @yurikrupnik

## 0.1.0 (2026-11-25)

### 🚀 Features

- **platform-addons:** new package. Maps a client's detected API groups and kinds to platform addons (Helm charts, kustomize paths, plain manifests, per-cloud Crossplane provider families, the `platform.shluviza.com` XR APIs) and emits them as Flux or Argo CD install objects, with `addons`, `unmapped` and `warnings` for the ClientPlatform controller. Catalog versions and values follow gitops' `platform/` releases.
