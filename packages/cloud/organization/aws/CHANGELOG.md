## 0.1.0 (2026-09-20)

- Initial release: Organization composition backed by AWS Organizations — the organizational-unit tree, the member accounts inside it, and one service control policy plus attachment per policy entry at the root or at an OU. Placement is a second pass: `parentId` and `targetId` carry no reference in the generated schemas, so a nested OU, an account and a folder-scoped attachment are emitted once the parent OU's id is observed, and `status.ready` reports whether the tree is complete.
