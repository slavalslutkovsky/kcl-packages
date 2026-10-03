## 0.1.1 (2026-10-01)

### 🚀 Features

- add oci kms, workflow and residency packages, talos/k3s cluster runners, provider READMEs ([e6c7fb2](https://github.com/slavalslutkovsky/kcl-packages/commit/e6c7fb2))
- **landing:** add comprehensive unit tests for AWS and Azure landing pages ([e7bafe6](https://github.com/slavalslutkovsky/kcl-packages/commit/e7bafe6))

### ❤️ Thank You

- yurikrupnik

## 0.1.0 (2026-09-19)

Initial onprem backend for the LandingPage XR: one provider-helm Release of the pinned nginx chart that serves the XR's content from a ConfigMap, exposed in-cluster by a ClusterIP Service and — when a domain is set — by a cert-manager-annotated Ingress.
