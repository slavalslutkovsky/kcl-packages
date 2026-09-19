#!/usr/bin/env bash
# bench-pm.sh — bun vs pnpm vs nub installing this repo's dependency tree.
#
# Each manager gets its own sandbox under a temp dir: a copy of the workspace
# manifests (package.json, pnpm-workspace.yaml, pnpm-lock.yaml, tools/*/package.json)
# plus a private content store and cache, so nothing touches ~/.bun, the pnpm
# store, or ~/.local/share/nub, and no lockfile is written back into the repo.
#
# Three scenarios, timed with hyperfine (`--prepare` resets state before every run):
#   cold   empty store + cache, no node_modules      -> network + extract + link
#   warm   populated store, node_modules removed     -> link only (the CI-cache /
#                                                       branch-switch case)
#   noop   everything present                        -> lockfile check only
#
# Every manager runs with --frozen-lockfile against ITS OWN lockfile (bun writes
# bun.lock on the untimed seed install; pnpm and nub both read pnpm-lock.yaml) and
# --ignore-scripts, so puppeteer's Chromium download and nx/swc postinstalls do not
# dominate the number: this measures the install engine, not the tree's scripts.
#
# Usage:  tools/bench-pm.sh                     # all three, 5 runs each
#         RUNS=10 PMS="pnpm nub" tools/bench-pm.sh
# Writes tools/bench/out/pm-{cold,warm,noop}.{json,md} and a combined pm.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/tools/bench/out"
RUNS=${RUNS:-5}
WARMUP=${WARMUP:-1}
read -ra PMS <<<"${PMS:-bun pnpm nub}"
# All three change behaviour under CI=… (nub drops its shared virtual store, pnpm
# and bun switch output/defaults). Measure the developer-machine path.
unset CI

for bin in hyperfine "${PMS[@]}"; do
    command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 2; }
done

WORK=$(mktemp -d -t bench-pm)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# Manifest files, relative to ROOT, that define the install. bun rewrites
# pnpm-workspace.yaml into package.json `workspaces` on migration and both nub and
# pnpm read the pnpm files as-is, so one file set seeds every sandbox.
MANIFESTS=(package.json pnpm-workspace.yaml pnpm-lock.yaml)
for f in "$ROOT"/tools/*/package.json; do MANIFESTS+=("${f#"$ROOT/"}"); done
[[ -f "$ROOT/.npmrc" ]] && MANIFESTS+=(.npmrc)

# Per-manager: install flags, and the env that pins its store + cache into the
# sandbox (pnpm 11 reads pnpm_config_*, not npm_config_*, for its own settings).
# --trust-lockfile on pnpm: pnpm 11's default trustPolicy=no-downgrade rejects
# this repo's committed lockfile outright (see the nx note in the justfile), so
# without it pnpm never reaches the install engine we are timing.
FLAGS="install --frozen-lockfile --ignore-scripts"
pm_flags() {
    case $1 in
        pnpm) echo "$FLAGS --trust-lockfile" ;;
        *)    echo "$FLAGS" ;;
    esac
}
pm_env() {
    local pm=$1 dir=$2
    case $pm in
        bun)  echo "BUN_INSTALL_CACHE_DIR=$dir/cache" ;;
        pnpm) echo "pnpm_config_store_dir=$dir/store pnpm_config_cache_dir=$dir/cache" ;;
        nub)  echo "npm_config_store_dir=$dir/store NUB_CACHE_DIR=$dir/cache" ;;
        *)    echo "unknown package manager: $pm" >&2; exit 2 ;;
    esac
}

echo "== seeding sandboxes under $WORK" >&2
for pm in "${PMS[@]}"; do
    dir="$WORK/$pm"
    mkdir -p "$dir/repo" "$dir/store" "$dir/cache"
    (cd "$ROOT" && tar cf - "${MANIFESTS[@]}") | tar xf - -C "$dir/repo"
    # Untimed: resolves once, writes the manager's own lockfile, fills the store.
    seed="cd '$dir/repo' && env $(pm_env "$pm" "$dir") $pm $(pm_flags "$pm" | sed 's/ --frozen-lockfile//')"
    bash -c "$seed" >/dev/null 2>&1 || { echo "seed install failed for $pm:" >&2; bash -c "$seed"; exit 1; }
    echo "   $pm $("$pm" --version 2>/dev/null | tail -1) ok" >&2
    # If the env was ignored the cold scenario silently measures the global store.
    # bun has only a cache; pnpm's cache holds packuments, which a frozen install
    # never fetches, so its store is the tell.
    populated=$([[ $pm == bun ]] && echo cache || echo store)
    [[ -n "$(ls -A "$dir/$populated")" ]] || { echo "$pm ignored its $populated override; nothing under $dir/$populated" >&2; exit 1; }
done

# One hyperfine call per scenario; each command is `cd sandbox && env ... pm install`,
# with a matching --prepare that resets exactly the state that scenario measures.
run_scenario() {
    local name=$1 reset=$2
    local args=(--warmup "$WARMUP" --runs "$RUNS" --export-json "$OUT/pm-$name.json" --export-markdown "$OUT/pm-$name.md")
    for pm in "${PMS[@]}"; do
        local dir="$WORK/$pm"
        args+=(--prepare "cd '$dir' && $reset")
        args+=(-n "$pm" "cd '$dir/repo' && env $(pm_env "$pm" "$dir") $pm $(pm_flags "$pm")")
    done
    echo "== $name" >&2
    hyperfine "${args[@]}"
}

run_scenario cold "rm -rf repo/node_modules store cache && mkdir store cache"
run_scenario warm "rm -rf repo/node_modules"
run_scenario noop "true"

{
    echo "# Package manager install benchmark"
    echo
    echo "$(date -u +%Y-%m-%dT%H:%MZ) · $(uname -m) $(uname -s) · node $(node --version) · $RUNS runs, $WARMUP warmup"
    for pm in "${PMS[@]}"; do echo "- $pm $("$pm" --version 2>/dev/null | tail -1)"; done
    echo
    echo "Flags: \`$FLAGS\` (+ \`--trust-lockfile\` for pnpm). Lockfile: bun.lock migrated from pnpm-lock.yaml (bun), pnpm-lock.yaml (pnpm, nub). CI unset."
    for s in cold warm noop; do
        echo; echo "## $s"; echo
        cat "$OUT/pm-$s.md"
    done
} >"$OUT/pm.md"
echo "== wrote $OUT/pm.md" >&2
