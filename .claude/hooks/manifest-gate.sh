#!/usr/bin/env bash
# PostToolUse(Write|Edit|MultiEdit): validate a touched manifest the way the
# pre-commit hook does, plus the one invariant nothing else checks.
#
#   *.yaml|*.yml            `yq e true`          (lefthook: yaml-syntax)
#   any tracked file        `just secrets-check` (lefthook: secrets)
#   composition.yaml|kcl.mod `just mod-check`    (lefthook: package-integrity)
#   composition.yaml|kcl.mod  package version == the Composition's ?tag= pin
#
# The last one is not in mod-check: mod-check only asserts the source IMAGE is
# this package. `nx release` (tools/nx-kcl/src/release/version-actions.ts)
# writes kcl.mod `version` and the composition `?tag=` together, so a hand edit
# to either one alone points a live Composition at a package version that is
# not the code in this directory.
#
# Exit 2 hands stderr back to Claude as a blocking error.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
[ -n "$file" ] || exit 0

root=${CLAUDE_PROJECT_DIR:-$PWD}
cd "$root" 2>/dev/null || exit 0
case "$file" in
    "$root"/*) rel=${file#"$root"/} ;;
    /*) exit 0 ;;
    *) rel=$file ;;
esac
[ -f "$rel" ] || exit 0

base=$(basename "$rel")
case "$rel" in
    *.yaml | *.yml) is_yaml=1 ;;
    *) is_yaml=0 ;;
esac
case "$base" in
    composition.yaml | kcl.mod) is_pkg=1 ;;
    *) is_pkg=0 ;;
esac
[ "$is_yaml" = 1 ] || [ "$is_pkg" = 1 ] || exit 0

fail=0
report=""
note() {
    report="${report}$1
"
    fail=1
}

# 1. Parses at all (multi-doc aware, same command as `just yaml-check`).
if [ "$is_yaml" = 1 ] && command -v yq >/dev/null 2>&1; then
    if ! out=$(yq e 'true' "$rel" 2>&1 >/dev/null); then
        note "YAML does not parse ($rel):
$out"
    fi
fi

# 2. No credentials. Three clouds' worth of them are one edit away.
if command -v just >/dev/null 2>&1; then
    if ! out=$(just secrets-check "$rel" 2>&1); then
        note "secrets-check refused $rel:
$out"
    fi
fi

# 3+4. Package invariants, only when a package file moved.
if [ "$is_pkg" = 1 ]; then
    if command -v just >/dev/null 2>&1; then
        if ! out=$(just mod-check 2>&1); then
            note "mod-check failed (duplicate kcl.mod name, unresolvable path dep, or a Composition source that is not its own package):
$out"
        fi
    fi

    dir=$(dirname "$rel")
    if command -v yq >/dev/null 2>&1 && [ -f "$dir/composition.yaml" ] && [ -f "$dir/kcl.mod" ]; then
        version=$(sed -n 's/^version = "\(.*\)"/\1/p' "$dir/kcl.mod" | head -1)
        source=$(yq -r '.spec.pipeline[].input.spec.source // ""' "$dir/composition.yaml" 2>/dev/null | grep -v '^$' | head -1)
        if [ -n "$version" ] && [ -n "$source" ]; then
            case "$source" in
                *\?tag=*) pin=${source##*\?tag=} ;;
                *) pin="" ;;
            esac
            if [ -z "$pin" ]; then
                note "$dir/composition.yaml pins no version: source '$source' has no ?tag=. Every Composition in this repo pins one, and \`nx release\` rewrites it to the package version on each bump."
            elif [ "$pin" != "$version" ]; then
                note "$dir: kcl.mod version is $version but composition.yaml pulls ?tag=$pin. These two are written together by nx release (tools/nx-kcl/src/release/version-actions.ts); a Composition pinned at $pin does not run the code in this directory. Revert the hand edit and let \`nx release\`/\`just release\` move both, or set both to the same value."
            fi
        fi
    fi
fi

if [ "$fail" -ne 0 ]; then
    printf '%s' "$report" >&2
    exit 2
fi
exit 0
