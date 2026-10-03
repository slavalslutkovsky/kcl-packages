#!/usr/bin/env bash
# PostToolUse(Write|Edit|MultiEdit): format and lint a touched .k file now,
# with the same two commands lefthook runs at commit time (`just fmt-files`,
# `just lint-files`) — so a KCL error surfaces inside the turn that caused it
# instead of at `git commit` or in CI's `nx affected -t build test lint`.
#
# Generated provider packages are skipped for the same reason the justfile and
# nx skip them: they lint dirty by construction (tag:area:providers).
#
# Exit 2 hands stderr back to Claude as a blocking error.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')
case "$file" in
    *.k) ;;
    *) exit 0 ;;
esac

root=${CLAUDE_PROJECT_DIR:-$PWD}
cd "$root" 2>/dev/null || exit 0
case "$file" in
    "$root"/*) rel=${file#"$root"/} ;;
    /*) exit 0 ;;
    *) rel=$file ;;
esac
case "$rel" in packages/providers/*) exit 0 ;; esac
[ -f "$rel" ] || exit 0
command -v kcl >/dev/null 2>&1 || exit 0

before=$(cksum <"$rel")
fmt_out=$(kcl fmt "$rel" 2>&1)
fmt_rc=$?
if [ "$fmt_rc" -ne 0 ]; then
    {
        echo "kcl fmt rejected $rel (it does not parse):"
        echo "$fmt_out"
    } >&2
    exit 2
fi
after=$(cksum <"$rel")

# Lint the package that owns the file, not the file: kcl lint resolves imports
# through kcl.mod. Same walk-up as `just lint-files`.
dir=$(dirname "$rel")
while [ "$dir" != "." ] && [ ! -f "$dir/kcl.mod" ]; do
    dir=$(dirname "$dir")
done
if [ -f "$dir/kcl.mod" ]; then
    if ! lint_out=$(cd "$dir" && kcl lint 2>&1); then
        {
            echo "kcl lint failed in $dir (lefthook runs the same check on commit):"
            echo "$lint_out"
        } >&2
        exit 2
    fi
fi

if [ "$before" != "$after" ]; then
    jq -nc --arg m "kcl fmt rewrote $rel after your edit (the pre-commit hook does the same and re-stages it). Your last read of this file is stale — re-read before editing it again." '{
        hookSpecificOutput: {
            hookEventName: "PostToolUse",
            additionalContext: $m
        }
    }'
fi

exit 0
