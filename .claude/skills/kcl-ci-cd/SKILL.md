---
name: kcl-ci-cd
description: The CI and CD machinery of this workspace — inferred nx targets from kcl.mod, the lefthook pre-commit/pre-push gates, the affected-based GitHub Actions CI, and the nx release path that patch-bumps packages, rewrites Composition pins and pushes to OCI. Use when changing build/test/lint behaviour, workflows, the nx-kcl plugin, versions, or publishing.
when_to_use: Triggered by CI, pipeline, nx affected, nx release, publishing, versions, kcl.mod, composition pins, lefthook, git hooks, or GitHub Actions questions.
paths:
  - .github/workflows/**
  - tools/nx-kcl/**
  - nx.json
  - lefthook.yml
  - justfile
---

# CI / CD for the KCL packages

## Projects are inferred, never declared

There is **no `project.json` anywhere**. `tools/nx-kcl/src/index.ts` (registered in `nx.json` `plugins`) globs `**/kcl.mod`, names the project from the `name` field, tags it `lang:kcl` + `area:<segment after packages/>`, and synthesizes targets:

| target | runs | notes |
| --- | --- | --- |
| `build` | `kcl run {projectRoot}/main.k` | cached |
| `test` | `kcl test` in the package dir | cached |
| `lint` | `kcl lint` in the package dir | cached |
| `fmt` | `kcl fmt` | uncached |
| `add` / `remove` | `kcl mod add` / `nx-kcl:remove` | |
| `pkg` | `kcl mod pkg --target .` | dependsOn test, lint |
| `nx-release-publish` | `nx-kcl:publish` → `kcl mod push <registry>/<project>` | dependsOn test, lint; vendors path deps into a staging dir |
| `render` | `nx-kcl:render` | only when `composition.yaml` exists; uncached; needs docker |

`createDependencies` turns each `path = "…"` entry in a `kcl.mod` into a graph edge — registry deps create none. Projects under `packages/providers/**` get `targets = {}` (generated, lint dirty by construction), which is why every command excludes `tag:area:providers`.

Adding a package is therefore: create the directory with a `kcl.mod`. Nothing to register.

## Local gates (lefthook → just)

`lefthook.yml` never contains logic; every job calls a `just` recipe, so each failure reproduces by hand and exists in exactly one place.

- **pre-commit** (sequential, staged files only): `just fmt-files` (+ re-stage), `just lint-files`, `just yaml-check`, `just mod-check`, `just secrets-check`, `just graph-check`, `just typecheck`.
- **commit-msg**: `just commit-msg` — Conventional Commits, because `nx release` writes the changelogs from these subjects.
- **pre-push**: `just check` (`nx run-many -t build test lint --projects=tag:lang:kcl --exclude=tag:area:providers`) and `just typecheck`.

Install once per clone: `just hooks`. Run over the whole tree: `just hooks-run pre-commit`. The `.claude/hooks/kcl-gate.sh` and `manifest-gate.sh` hooks run the same checks per edited file, so a commit should never be the first time a failure appears.

## CI — `.github/workflows/ci.yml`

PRs and pushes to main: checkout with full history → `nrwl/nx-set-shas@v4` → pnpm 10 / node 24 → `pnpm install --frozen-lockfile` → install the KCL CLI → `pnpm exec nx affected -t build test lint`. No cluster, no Flux.

Reproduce exactly: `pnpm exec nx affected -t build test lint --base=<merge-base>`.

## CD — `.github/workflows/release.yml`

Push to main, `concurrency: release` with `cancel-in-progress: false` (a cancelled run can leave tags pushed with nothing published), refuses any ref other than `main`.

1. Affected base = the newest `*@*` tag, **not** the last workflow run — basing off the tag excludes the release commit the workflow itself pushed, so a re-run with no source change is a clean no-op.
2. Affected ∩ releasable (`tag:lang:kcl` minus `tag:area:providers`) → `nx release --specifier=patch --skip-publish`. Commit messages are not parsed; every affected releasable project gets a patch bump.
3. `git push --atomic --follow-tags origin HEAD:main` **before** publishing: a rejected git push costs nothing, a `kcl mod push` can never be undone.
4. `nx release publish --projects=<bumped>` → `oci://docker.io/<DOCKERHUB_USERNAME>/<pkg>:<version>`.

Auth detail that will bite anyone touching it: kpm looks the credential up under the literal host key `docker.io`, which neither `kcl registry login` nor `docker login` writes — the workflow writes `$KCL_PKG_PATH/.kpm/config/config.json` by hand.

## The version invariant

`tools/nx-kcl/src/release/version-actions.ts` writes **two** things per bump: `version` in `kcl.mod`, and the `?tag=<version>` pin in that package's `composition.yaml`. They must always match — a Composition pinned at an older tag runs older code than the directory it lives in. `just mod-check` only checks that the source *image* equals the package name; the tag/version equality is enforced by `.claude/hooks/manifest-gate.sh`.

Never hand-edit a version or a pin. Use `just release-dry` to preview, and let CI do the real bump.

## Publishing locally

Always to the kind registry, never to docker.io:

```bash
just registry                     # kind-registry container: push localhost:5001, pull 172.18.0.100:80
just publish-all                  # KCL_REGISTRY=localhost:5001 nx run-many -t nx-release-publish …
just e2e-publish <module>         # same, one module (--projects='<module>*')
just install-module <module>      # XRD + Compositions, sources sed'd to oci://kind-registry/
```

`.claude/hooks/guard-delivery.sh` denies a bare `kcl mod push` / `nx release` / `just release*` precisely because those reach the public registry.

## Workflows

`/ci-local` reproduces the CI gate on the affected set. `/release-preview` shows what the release workflow would bump and publish, without publishing.
