## 0.1.1 (2026-10-01)

### 🚀 Features

- add oci kms, workflow and residency packages, talos/k3s cluster runners, provider READMEs ([e6c7fb2](https://github.com/slavalslutkovsky/kcl-packages/commit/e6c7fb2))
- **landing:** add comprehensive unit tests for AWS and Azure landing pages ([e7bafe6](https://github.com/slavalslutkovsky/kcl-packages/commit/e7bafe6))

### ❤️ Thank You

- yurikrupnik @yurikrupnik

## 0.1.0 (2026-09-20)

- Initial release: Organization composition backed by Azure — the management-group tree (nested by reference, each group's name pinned as its external-name), one ManagementGroupPolicyAssignment per policy with `enforce`/`dryRun` mapped onto the assignment's enforcement mode, and RoleAssignments scoped to the root or to a management group. Subscriptions, audit logging, folder deletion protection, policy value lists, inheritance/reset and IAM conditions are refused with a message naming the alternative.
