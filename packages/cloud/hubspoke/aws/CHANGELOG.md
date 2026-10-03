## 0.1.1 (2026-10-01)

### 🚀 Features

- add oci kms, workflow and residency packages, talos/k3s cluster runners, provider READMEs ([e6c7fb2](https://github.com/slavalslutkovsky/kcl-packages/commit/e6c7fb2))
- **landing:** add comprehensive unit tests for AWS and Azure landing pages ([e7bafe6](https://github.com/slavalslutkovsky/kcl-packages/commit/e7bafe6))

### ❤️ Thank You

- yurikrupnik @yurikrupnik

## 0.1.0 (2026-09-19)

Initial AWS backend for the NetworkHub XR: a Transit Gateway with one VPC attachment per existing spoke VPC, an optional summary route toward the gateway in each spoke's own route tables, and — in the isolated topology — a shared and an isolated Transit Gateway route table whose associations and propagations keep workload spokes from reaching one another.
