#!/usr/bin/env bash
# tools/providers.sh — read/act on the provider registry
# (packages/providers/registry.yaml), the single source of truth for every
# cloud provider this repo supports.
#
#   providers.sh list  [filter]   table of registered providers
#   providers.sh seed  [target]   (re)generate schema packages via nx-kcl
#   providers.sh check            fail on drift between registry, generated
#                                 packages and the xrd/providers.yaml manifests
#
# `filter`/`target` match a provider name, a cloud (aws|gcp|azure|kubernetes)
# or a module (bucket, redis, …); "all"/empty means everything.
#
# Requires: yq v4. `seed` additionally needs node_modules (nx) plus docker for
# image-sourced rows. The justfile wraps this (`just providers|seed|
# providers-check`); CI calls `check` directly.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
registry="$root/packages/providers/registry.yaml"
nx="$root/node_modules/.bin/nx"

# One `|`-separated line per provider, every optional field defaulted, so the
# callers below never have to touch yq again. Not tabs: tab is an IFS
# whitespace character, so bash `read` would collapse the runs of empty fields
# every repo-sourced row has and silently shift the columns.
rows() {
    yq -r '.providers[] | [
        .name, .cloud, (.service // ""),
        (.image // ""), (.tag // ""),
        (.repo // ""), (.ref // ""), (.crdPath // ""),
        (.scope // "namespaced"),
        (.install // ""),
        ((.modules // []) | join(","))
    ] | join("|")' "$registry"
}

# Package ref a row installs into the cluster: explicit `install`, else
# <image>:<tag>. Empty for rows that install nothing ("none").
install_ref() { # image tag install
    case "$3" in
        none) printf '' ;;
        '') [ -n "$1" ] && printf '%s:%s' "$1" "$2" ;;
        *) printf '%s' "$3" ;;
    esac
}

# Where the CRDs were generated from — image:tag or repo@ref.
source_ref() { # image tag repo ref
    if [ -n "$1" ]; then printf '%s:%s' "$1" "$2"; else printf '%s@%s' "$3" "$4"; fi
}

matches() { # filter name cloud modules
    [ -z "$1" ] || [ "$1" = all ] && return 0
    [ "$1" = "$2" ] || [ "$1" = "$3" ] && return 0
    case ",$4," in *",$1,"*) return 0 ;; esac
    return 1
}

cmd_list() {
    local filter=${1:-} src inst
    {
        printf 'NAME\tCLOUD\tSOURCE\tINSTALL\tMODULES\n'
        while IFS='|' read -r name cloud service image tag repo ref crdPath scope install modules; do
            matches "$filter" "$name" "$cloud" "$modules" || continue
            src=$(source_ref "$image" "$tag" "$repo" "$ref")
            inst=$(install_ref "$image" "$tag" "$install")
            printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$cloud" "$src" "${inst:--}" "${modules:--}"
        done < <(rows)
    } | column -t -s $'\t'
}

cmd_seed() {
    local target=${1:-all} found=0
    while IFS='|' read -r name cloud service image tag repo ref crdPath scope install modules; do
        matches "$target" "$name" "$cloud" "$modules" || continue
        found=1
        echo "== $name ($(source_ref "$image" "$tag" "$repo" "$ref"))"
        local args=("$name" --directory=packages/providers "--apiScope=$scope" --no-interactive)
        [ -n "$service" ] && args+=("--service=$service")
        if [ -n "$image" ]; then
            args+=("--image=$image:$tag")
        else
            args+=("--repo=$repo" "--ref=$ref" "--crdPath=$crdPath")
        fi
        (cd "$root" && "$nx" g nx-kcl:import-crd "${args[@]}")
    done < <(rows)
    [ "$found" = 1 ] || { echo "providers.sh: nothing in the registry matches '$target'" >&2; exit 1; }
}

cmd_check() {
    local fail=0
    err() { echo "  ✗ $*" >&2; fail=1; }

    echo "── registry ↔ packages/providers ──────────────────────────"
    local registered=()
    while IFS='|' read -r name cloud service image tag repo ref crdPath scope install modules; do
        registered+=("$name")
        local main="$root/packages/providers/$name/main.k"
        local src
        src=$(source_ref "$image" "$tag" "$repo" "$ref")
        if [ ! -f "$main" ]; then
            err "$name: no schema package — run 'just seed $name'"
            continue
        fi
        # The generator stamps `# Source: <image>:<tag>` / `<repo>@<ref>` into main.k.
        grep -q -- "$src" "$main" || err "$name: generated from $(sed -n 's/^# Source: //p' "$main" | head -1), registry says $src"
    done < <(rows)

    for dir in "$root"/packages/providers/*/; do
        local name
        name=$(basename "$dir")
        printf '%s\n' "${registered[@]}" | grep -qx "$name" ||
            err "$name: schema package has no row in packages/providers/registry.yaml"
    done

    echo "── registry ↔ cloud/*/xrd/providers.yaml ──────────────────"
    # Every install ref the registry claims a module needs must be in that
    # module's providers.yaml, and vice versa. `comm` needs sorted input, and
    # the empty set must stay empty (printf on "" would emit a blank line).
    local module want installed
    for f in "$root"/packages/cloud/*/xrd/providers.yaml; do
        module=$(basename "$(dirname "$(dirname "$f")")")
        want=$(while IFS='|' read -r name cloud service image tag repo ref crdPath scope install modules; do
            case ",$modules," in
                *",$module,"*) install_ref "$image" "$tag" "$install" | grep . || true ;;
            esac
        done < <(rows) | sort -u)
        installed=$(yq -r 'select(.kind == "Provider") | .spec.package' "$f" | sort -u)
        while read -r missing; do
            [ -n "$missing" ] && err "$module: registry expects $missing, missing from xrd/providers.yaml" || true
        done <<<"$(comm -23 <(printf '%s' "$want") <(printf '%s' "$installed"))"
        while read -r extra; do
            [ -n "$extra" ] && err "$module: xrd/providers.yaml installs $extra, not in the registry for this module" || true
        done <<<"$(comm -13 <(printf '%s' "$want") <(printf '%s' "$installed"))"
    done

    if [ "$fail" = 1 ]; then
        echo "provider registry: DRIFT (see above)" >&2
        return 1
    fi
    echo "provider registry: ok"
}

case "${1:-list}" in
    list) cmd_list "${2:-}" ;;
    seed) cmd_seed "${2:-all}" ;;
    check) cmd_check ;;
    *)
        echo "usage: providers.sh [list|seed|check] [filter]" >&2
        exit 2
        ;;
esac
