## 0.1.1 (2026-10-01)

### 🚀 Features

- add oci kms, workflow and residency packages, talos/k3s cluster runners, provider READMEs ([e6c7fb2](https://github.com/slavalslutkovsky/kcl-packages/commit/e6c7fb2))
- **landing:** add comprehensive unit tests for AWS and Azure landing pages ([e7bafe6](https://github.com/slavalslutkovsky/kcl-packages/commit/e7bafe6))

### ❤️ Thank You

- yurikrupnik

## 0.1.0 (2026-09-20)

- Initial release: Organization composition backed by AWS Organizations — the organizational-unit tree, the member accounts inside it, and one service control policy plus attachment per policy entry at the root or at an OU. Placement is a second pass: `parentId` and `targetId` carry no reference in the generated schemas, so a nested OU, an account and a folder-scoped attachment are emitted once the parent OU's id is observed, and `status.ready` reports whether the tree is complete.
