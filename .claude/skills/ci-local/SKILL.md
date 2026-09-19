---
name: ci-local
description: Run the exact gate CI runs, on the affected projects only, and fix what it reports — nx affected build/test/lint plus the pre-commit checks lefthook would run.
argument-hint: "[base-ref]"
arguments: base
disable-model-invocation: true
allowed-tools:
  - Read
  - Edit
  - Bash(node_modules/.bin/nx:*)
  - Bash(just check)
  - Bash(just fmt-check)
  - Bash(just mod-check)
  - Bash(just yaml-check:*)
  - Bash(just secrets-check:*)
  - Bash(just graph-check)
  - Bash(just typecheck)
  - Bash(just hooks-run:*)
  - Bash(git status:*)
  - Bash(git diff:*)
  - Bash(git merge-base:*)
---

# Reproduce CI locally

Base ref: `$base` (default: the merge base with `origin/main`).

## Working tree

!`git status --porcelain | head -40; echo "---"; git merge-base HEAD origin/main 2>/dev/null || echo "no origin/main"`

## Steps

1. **Affected set.** Resolve the base, then list what CI would touch:

   ```bash
   node_modules/.bin/nx show projects --affected --base=<base> --projects=tag:lang:kcl --exclude=tag:area:providers
   ```

   An empty set means CI has nothing to do — say so instead of running the whole tree.

2. **The CI command itself** (`.github/workflows/ci.yml` runs exactly this, with `nx-set-shas` supplying the base):

   ```bash
   node_modules/.bin/nx affected -t build test lint --base=<base>
   ```

   Whole-tree equivalent when the affected computation is untrustworthy (new files, rebased branch): `just check`.

3. **The pre-commit invariants CI does not run** — these fail at commit time instead, so check them now:

   ```bash
   just fmt-check      # hand-written KCL that kcl fmt would rewrite
   just mod-check      # unique kcl.mod names, resolvable path deps, Composition source == package
   just graph-check    # docs/install-graph.md vs devkit.toml + manager values
   just typecheck      # tools/*.ts
   ```

   Or all of them over the tree at once: `just hooks-run pre-commit`.

4. **Fix, do not narrow.** For each failure, change the source. Never delete a test, loosen an assertion, or exclude a project to make the gate pass. `kcl lint` failures in `packages/providers/**` are impossible by construction (those projects have no targets); if you see one, the exclusion broke.

5. **Report**: the affected project list, which targets ran, and each failure with the file and the fix applied. If everything was a cache hit, say that — a wall of `[existing outputs match the cache]` is not evidence that the change was exercised. Re-run the specific project with `--skip-nx-cache` when the change needs real proof.
