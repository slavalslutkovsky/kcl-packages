---
name: release-preview
description: Preview what the release workflow would publish — which projects patch-bump, which Composition pins move, and whether any package version and its composition ?tag= have drifted apart. Never publishes.
disable-model-invocation: true
allowed-tools:
  - Read
  - Bash(just release-dry)
  - Bash(just publishable)
  - Bash(node_modules/.bin/nx show:*)
  - Bash(git tag:*)
  - Bash(git log:*)
  - Bash(yq:*)
  - Bash(sed:*)
  - Bash(find:*)
---

# Preview the release

Publishing is `.github/workflows/release.yml`'s job. This skill only inspects; `.claude/hooks/guard-delivery.sh` denies anything that would reach `docker.io/yurikrupnik`.

## Current release state

!`git tag -l '*@*' --sort=-creatordate | head -5; echo "--- releasable ---"; node_modules/.bin/nx show projects --projects=tag:lang:kcl --exclude=tag:area:providers 2>/dev/null | tr '\n' ' '`

## Steps

1. **Reproduce the workflow's affected base.** Release diffs against the newest `*@*` tag, not the last CI run:

   ```bash
   LATEST=$(git tag -l '*@*' --sort=-creatordate | head -n 1)
   node_modules/.bin/nx show projects --affected --base="$LATEST" --projects=tag:lang:kcl --exclude=tag:area:providers --json
   ```

   That list is exactly what would get a patch bump. Commit messages play no part.

2. **Dry-run the version pass:** `just release-dry` (`nx release --specifier=patch --dry-run`). Read the diff it prints: each project should show a `kcl.mod` version bump **and** the matching `?tag=` rewrite in its `composition.yaml` (`tools/nx-kcl/src/release/version-actions.ts` writes both), plus a CHANGELOG entry.

3. **Audit the pin invariant across the tree** — a hand edit to either side is invisible until a Composition pulls the wrong code:

   ```bash
   for c in $(find packages -name composition.yaml -not -path '*/node_modules/*'); do
     d=$(dirname "$c")
     v=$(sed -n 's/^version = "\(.*\)"/\1/p' "$d/kcl.mod")
     s=$(yq -r '.spec.pipeline[].input.spec.source // ""' "$c" | grep -v '^$' | head -1)
     [ "${s##*tag=}" = "$v" ] || echo "MISMATCH $c pkg=$v pin=${s##*tag=}"
   done
   ```

   Any output is a bug to fix before release, not after.

4. **Report**: the projects that would bump with their current → next version, the Composition pins that move with them, any mismatch found in step 3, and — if the affected set is empty — that a release run right now would be a clean no-op.

Do not run `nx release`, `nx release publish`, `just release`, or `kcl mod push`. To exercise publishing, use the kind registry: `just publish-all`.
