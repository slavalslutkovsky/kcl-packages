#!/usr/bin/env bash
# tools/configurations.sh — Crossplane Configuration packages for the
# Composition modules (every packages/<area>/<module>/ with an xrd/ dir).
#
# Each module ships one package per layer, so a cluster installs only the
# backends it uses and Crossplane's package manager installs exactly their
# Providers (instead of every backend's, as xrd/providers.yaml does):
#
#   configuration-<module>            xrd/crossplane.yaml
#       the XRD, plus the Functions its Compositions run (xrd/functions.yaml)
#   configuration-<module>-<backend>  <backend>/crossplane.yaml
#       one Composition, plus the base package, the Providers its KCL imports
#       and the configurations of any XR module it composes
#
#   configurations.sh list                      packages, versions, dependencies
#   configurations.sh sync  [module|all]        create the crossplane.yaml files and
#                                               add/refresh the dependencies kcl.mod,
#                                               registry.yaml and functions.yaml imply
#   configurations.sh check                     fail on drift (CI runs this)
#   configurations.sh bump  <package> [patch|minor|major]
#                                               version a package kcl.mod does not
#   configurations.sh build [filter] [opts]     stage + `crossplane xpkg build`
#   configurations.sh push  [filter] [opts]     build + `crossplane xpkg push`, with
#                                               every Configuration it depends on
#   configurations.sh closure <package> [--modules]
#                                               the package and its Configuration deps
#   configurations.sh runtime <module>          cluster prerequisites to apply BEFORE
#                                               installing: xrd/providers.yaml minus its
#                                               Providers (RBAC, DeploymentRuntimeConfigs)
#                                               plus an ImageConfig carrying each
#                                               Provider's runtimeConfigRef
#   configurations.sh providerconfigs <module>  the xrd/providerconfigs.yaml documents
#                                               whose kinds the current cluster serves
#   configurations.sh manifest [filter] [--registry R]
#                                               the pkg.crossplane.io Configuration objects
#
# `filter` is a module (its base and every backend), a package name
# (`postgres-gcp`), or "all"/empty.
#
# build/push options:
#   --registry R      registry the packages are published to and that their
#                     Configuration dependencies point at (default: nx.json
#                     release.registry, the one the KCL modules publish to)
#   --push-to P       where to push, when it differs from what the cluster pulls
#                     (local e2e: push localhost:5001, pull 172.18.0.100:80)
#   --kcl-registry K  rewrite each Composition's `oci://<registry>/` KCL source
#   --skip-tagged     skip packages whose git tag xpkg/configuration-<name>/<version>
#                     exists (already published)
#   --tag             create that git tag after each push
#
# Versions: a backend with a kcl.mod is versioned by it (nx release bumps it,
# and pins composition.yaml's source to the same version). The base package,
# and a backend whose Composition runs a non-KCL function, carry
# pkg.example.org/version plus pkg.example.org/digest; `check` fails when the
# content no longer matches the digest, `bump` moves both.
#
# Requires: bash >= 4, yq v4; build/push additionally the crossplane CLI.
set -euo pipefail

((BASH_VERSINFO[0] >= 4)) || { echo "configurations.sh: needs bash >= 4" >&2; exit 1; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
registry_file="$root/packages/providers/registry.yaml"
canonical=$(yq -r '.release.registry' "$root/nx.json")
version_key="pkg.example.org/version"
digest_key="pkg.example.org/digest"
# v2 XRDs, and ImageConfig runtime for dependency-installed packages (v2.2).
crossplane_constraint=">=v2.2.0-0"
dep_api="pkg.crossplane.io/v1"

die() { echo "configurations.sh: $*" >&2; exit 1; }

# ── Index ────────────────────────────────────────────────────────────────────
declare -A PKG_DIR PKG_MOD PKG_BACKEND PKG_MODDIR
PKGS=()
MODULES=()

index_packages() {
    local xrd xdir mdir m comp bdir b
    for xrd in "$root"/packages/*/*/xrd/xrd.yaml; do
        xdir=$(dirname "$xrd")
        mdir=$(dirname "$xdir")
        m=$(basename "$mdir")
        [ -z "${PKG_DIR[$m]:-}" ] || die "module '$m' exists twice (${PKG_MODDIR[$m]#"$root"/} and ${mdir#"$root"/})"
        MODULES+=("$m")
        PKGS+=("$m")
        PKG_DIR[$m]=$xdir PKG_MOD[$m]=$m PKG_BACKEND[$m]="" PKG_MODDIR[$m]=$mdir
        for comp in "$mdir"/*/composition.yaml; do
            [ -f "$comp" ] || continue
            bdir=$(dirname "$comp")
            b=$(basename "$bdir")
            PKGS+=("$m-$b")
            PKG_DIR[$m-$b]=$bdir PKG_MOD[$m-$b]=$m PKG_BACKEND[$m-$b]=$b PKG_MODDIR[$m-$b]=$mdir
        done
    done
}

declare -A REG_REF REG_MODS
index_registry() {
    local name image tag install modules ref
    while IFS='|' read -r name image tag install modules; do
        case "$install" in
            none) ref="" ;;
            "") ref=${image:+$image:$tag} ;;
            *) ref=$install ;;
        esac
        REG_REF[$name]=$ref
        REG_MODS[$name]=",$modules,"
    done < <(yq -r '.providers[] | [.name, (.image // ""), (.tag // ""), (.install // ""), ((.modules // []) | join(","))] | join("|")' "$registry_file")
}

index_packages
index_registry

rel() { printf '%s' "${1#"$root"/}"; }
meta() { printf '%s/crossplane.yaml' "${PKG_DIR[$1]}"; }
is_base() { [ -z "${PKG_BACKEND[$1]}" ]; }
kcl_versioned() { ! is_base "$1" && [ -f "${PKG_DIR[$1]}/kcl.mod" ]; }
payload() { if is_base "$1"; then echo xrd.yaml; else echo composition.yaml; fi; }
pkg_ref() { printf '%s/configuration-%s' "$2" "$1"; } # name registry
pkg_of_ref() { # <registry>/configuration-<name> -> name, if it is one of ours
    local n=${1##*/configuration-}
    [ "$n" != "$1" ] && [ -n "${PKG_DIR[$n]:-}" ] && printf '%s' "$n"
}

version_of() {
    local f
    if kcl_versioned "$1"; then
        sed -n 's/^version = "\(.*\)"/\1/p' "${PKG_DIR[$1]}/kcl.mod" | head -1
    else
        f=$(meta "$1")
        if [ -f "$f" ]; then K=$version_key yq -r '.metadata.annotations[strenv(K)] // ""' "$f"; fi
    fi
}

sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-16; }

# What the package ships, minus the digest itself.
digest_of() {
    { cat "${PKG_DIR[$1]}/$(payload "$1")"; K=$digest_key yq 'del(.metadata.annotations[strenv(K)])' "$(meta "$1")"; } | sha
}

matches() { # filter name
    [ -z "$1" ] || [ "$1" = all ] || [ "$1" = "$2" ] || [ "$1" = "${PKG_MOD[$2]}" ]
}

# Sets SEL to the packages a filter matches. An array, not a `$(…)` stream:
# `die` in a command substitution would only end the subshell.
select_pkgs() {
    local n
    SEL=()
    for n in "${PKGS[@]}"; do
        matches "${1:-}" "$n" && SEL+=("$n")
    done
    [ "${#SEL[@]}" -gt 0 ] || die "no package matches '${1:-}'"
}

# ── Dependencies ─────────────────────────────────────────────────────────────
# One line per dependency: Kind|package|version.

declared() {
    local f
    f=$(meta "$1")
    [ -f "$f" ] || return 0
    yq -r '(.spec.dependsOn // [])[] | [(.kind // ""), (.package // ""), (.version // "")] | join("|")' "$f"
}

split_ref() { printf '%s|%s' "${1%:*}" "${1##*:}"; } # image:tag -> image|tag

# The Functions xrd/functions.yaml installs (a base package's whole job).
functions_of() {
    local f ref
    f="${PKG_MODDIR[$1]}/xrd/functions.yaml"
    [ -f "$f" ] || return 0
    while read -r ref; do
        if [ -n "$ref" ] && [ "$ref" != "---" ]; then echo "Function|$(split_ref "$ref")"; fi
    done < <(yq -r 'select(.kind == "Function") | .spec.package' "$f")
}

# What a backend's kcl.mod implies: a provider schema package means that
# provider's install ref (registry.yaml), another module's xrd package means
# that module's configuration — the same backend's when it has one (an XR
# composed with compositionSelector provider=<backend>), else its base.
implied() {
    local n=$1 dir m b name path target other
    dir=${PKG_DIR[$n]} m=${PKG_MOD[$n]} b=${PKG_BACKEND[$n]}
    echo "Configuration|$(pkg_ref "$m" "$canonical")|>=$(version_of "$m")"
    [ -f "$dir/kcl.mod" ] || return 0
    while IFS='|' read -r name path; do
        target=$(cd "$dir/$path" 2>/dev/null && pwd -P) || continue
        case "$target" in
            "$root"/packages/providers/*)
                name=$(basename "$target")
                if [ -n "${REG_REF[$name]:-}" ]; then echo "Provider|$(split_ref "${REG_REF[$name]}")"; fi
                ;;
            */xrd)
                other=$(basename "$(dirname "$target")")
                if [ -z "${PKG_DIR[$other]:-}" ] || [ "$other" = "$m" ]; then continue; fi
                if [ -n "${PKG_DIR[$other-$b]:-}" ]; then other="$other-$b"; fi
                echo "Configuration|$(pkg_ref "$other" "$canonical")|>=$(version_of "$other")"
                ;;
        esac
    done < <(sed -n 's/^[[:space:]]*\([A-Za-z0-9_-]*\)[[:space:]]*=[[:space:]]*{.*path[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1|\2/p' "$dir/kcl.mod")
}

expected() { if is_base "$1"; then functions_of "$1"; else implied "$1"; fi; }

# ── sync ─────────────────────────────────────────────────────────────────────
header_base() {
    cat <<EOF
# Crossplane Configuration package configuration-$1: the $1 XRD and the
# Functions its Compositions run. Every backend is a package of its own
# (<backend>/crossplane.yaml) depending on this one, so installing a backend
# installs that backend's Providers and nothing else.
#
# Versioned here: \`tools/configurations.sh bump $1\` after any change to
# xrd.yaml or this file (\`check\` fails on a stale digest). Functions are kept
# in step with functions.yaml by \`tools/configurations.sh sync\`.
EOF
}

header_backend() {
    cat <<EOF
# Crossplane Configuration package configuration-$1:
# this backend's Composition and exactly what it needs — the module's base
# package (XRD + Functions), the Providers it composes against and the
# configurations of any XR it composes. Installing it installs those and
# nothing else.
#
# \`tools/configurations.sh sync\` adds what kcl.mod implies (provider schema
# packages, other modules' xrd packages). What it cannot see is added here by
# hand: an operator installed through provider-helm by
# xrd/providerconfigs.yaml, an XR composed by kind, every dependency of a
# Composition rendered by a non-KCL function. \`check\` keeps both in step
# with kcl.mod and packages/providers/registry.yaml.
EOF
    if kcl_versioned "$1"; then
        echo "# Version: kcl.mod (nx release), the same one composition.yaml pins."
    else
        echo "# Versioned here: \`tools/configurations.sh bump $1\` after any change."
    fi
}

create_meta() {
    local n=$1 f
    f=$(meta "$n")
    {
        if is_base "$n"; then header_base "$n"; else header_backend "$n"; fi
        cat <<EOF
apiVersion: meta.pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: $n
spec:
  crossplane:
    version: "$crossplane_constraint"
  dependsOn: []
EOF
    } >"$f"
    if ! kcl_versioned "$n"; then
        K=$version_key yq -i '.metadata.annotations[strenv(K)] = "0.1.0"' "$f"
    fi
    echo "  + $(rel "$f")"
}

cmd_sync() {
    local filter=${1:-all} n f kind pkg ver have created
    select_pkgs "$filter"
    for n in "${SEL[@]}"; do
        f=$(meta "$n")
        created=0
        if [ ! -f "$f" ]; then create_meta "$n"; created=1; fi
        while IFS='|' read -r kind pkg ver; do
            have=$(declared "$n" | awk -F'|' -v k="$kind" -v p="$pkg" '$1 == k && $2 == p { print $3 }')
            if [ -z "$have" ]; then
                K=$kind P=$pkg V=$ver A=$dep_api yq -i \
                    '.spec.dependsOn += [{"apiVersion": strenv(A), "kind": strenv(K), "package": strenv(P), "version": strenv(V)}]' "$f"
                echo "  $n: + $kind $pkg $ver"
            elif [ "$kind" != Configuration ] && [ "$have" != "$ver" ]; then
                # Providers and Functions follow registry.yaml / functions.yaml.
                # A Configuration constraint is a floor, left as written.
                K=$kind P=$pkg V=$ver yq -i \
                    '(.spec.dependsOn[] | select(.kind == strenv(K) and .package == strenv(P))).version = strenv(V)' "$f"
                echo "  $n: ~ $kind $pkg $have -> $ver"
            fi
        done < <(expected "$n")
        if [ "$created" = 1 ] && ! kcl_versioned "$n"; then
            K=$digest_key D=$(digest_of "$n") yq -i '.metadata.annotations[strenv(K)] = strenv(D)' "$f"
        fi
    done
}

# ── bump ─────────────────────────────────────────────────────────────────────
cmd_bump() {
    local n=${1:-} level=${2:-patch} f cur next major minor patch
    [ -n "$n" ] && [ -n "${PKG_DIR[$n]:-}" ] || die "usage: bump <package> [patch|minor|major]"
    kcl_versioned "$n" && die "$n is versioned by $(rel "${PKG_DIR[$n]}")/kcl.mod (nx release bumps it)"
    f=$(meta "$n")
    [ -f "$f" ] || die "$(rel "$f") does not exist — run sync first"
    cur=$(version_of "$n")
    IFS=. read -r major minor patch <<<"${cur:-0.0.0}"
    case "$level" in
        patch) next="$major.$minor.$((patch + 1))" ;;
        minor) next="$major.$((minor + 1)).0" ;;
        major) next="$((major + 1)).0.0" ;;
        *) die "bump level must be patch, minor or major" ;;
    esac
    K=$version_key V=$next yq -i '.metadata.annotations[strenv(K)] = strenv(V)' "$f"
    K=$digest_key D=$(digest_of "$n") yq -i '.metadata.annotations[strenv(K)] = strenv(D)' "$f"
    echo "$n ${cur:-none} -> $next"
}

# ── check ────────────────────────────────────────────────────────────────────
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

cmd_check() {
    local fail=0 n f kind pkg ver want target floor have xrd_api comp_api name
    err() { echo "  ✗ $*" >&2; fail=1; }

    echo "── crossplane.yaml ↔ kcl.mod, registry.yaml, functions.yaml ─"
    for n in "${PKGS[@]}"; do
        f=$(meta "$n")
        if [ ! -f "$f" ]; then
            err "$n: $(rel "$f") missing — run 'tools/configurations.sh sync ${PKG_MOD[$n]}'"
            continue
        fi
        name=$(yq -r '.kind + "|" + .metadata.name' "$f")
        [ "$name" = "Configuration|$n" ] || err "$n: $(rel "$f") is '$name', want a Configuration named $n"

        ver=$(version_of "$n")
        if [ -z "$ver" ]; then
            err "$n: no version — run 'tools/configurations.sh bump $n'"
        elif ! kcl_versioned "$n"; then
            have=$(K=$digest_key yq -r '.metadata.annotations[strenv(K)] // ""' "$f")
            [ "$have" = "$(digest_of "$n")" ] ||
                err "$n: changed since $ver was stamped — run 'tools/configurations.sh bump $n'"
        fi

        while IFS='|' read -r kind pkg want; do
            have=$(declared "$n" | awk -F'|' -v k="$kind" -v p="$pkg" '$1 == k && $2 == p { print $3 }')
            if [ -z "$have" ]; then
                err "$n: missing $kind $pkg $want — run 'tools/configurations.sh sync $n'"
            elif [ "$kind" != Configuration ] && [ "$have" != "$want" ]; then
                err "$n: $kind $pkg pinned $have, expected $want — run 'tools/configurations.sh sync $n'"
            fi
        done < <(expected "$n")

        while IFS='|' read -r kind pkg have; do
            # Crossplane resolves dependencies by semver; `latest` never resolves.
            if [ "$kind" != Configuration ] && ! [[ $have =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                err "$n: $kind $pkg version '$have' is not a semver tag"
            fi
            case "$kind" in
                Provider)
                    is_base "$n" && { err "$n: a base package installs no Providers ($pkg)"; continue; }
                    target=""
                    for name in "${!REG_REF[@]}"; do
                        [ "${REG_REF[$name]}" = "$pkg:$have" ] && [[ ${REG_MODS[$name]} == *",${PKG_MOD[$n]},"* ]] && target=$name
                    done
                    [ -n "$target" ] || err "$n: Provider $pkg:$have is not a registry.yaml install ref for module ${PKG_MOD[$n]}"
                    ;;
                Configuration)
                    target=$(pkg_of_ref "$pkg") || true
                    if [ -z "$target" ] || [ "$pkg" != "$(pkg_ref "$target" "$canonical")" ]; then
                        err "$n: Configuration $pkg is not one of this repo's packages under $canonical"
                        continue
                    fi
                    floor=${have#>=}
                    if [ "$floor" = "$have" ] || [ -z "$floor" ]; then
                        err "$n: Configuration $target constraint '$have' must be '>=<version>'"
                    elif ! version_le "$floor" "$(version_of "$target")"; then
                        err "$n: requires $target $have, but $target is $(version_of "$target")"
                    fi
                    ;;
                Function)
                    # Not `grep -q`: it exits on the first match, and the
                    # writer's SIGPIPE then fails the pipeline under pipefail.
                    functions_of "${PKG_MOD[$n]}" | grep -Fx "Function|$pkg|$have" >/dev/null ||
                        err "$n: Function $pkg:$have is not in xrd/functions.yaml"
                    ;;
                *) err "$n: dependency '$kind $pkg' — use apiVersion/kind/package/version entries" ;;
            esac
        done < <(declared "$n")

        if ! is_base "$n"; then
            xrd_api=$(yq -r '.spec.group + "|" + .spec.names.kind' "${PKG_MODDIR[$n]}/xrd/xrd.yaml")
            comp_api=$(yq -r '(.spec.compositeTypeRef.apiVersion | sub("/.*$"; "")) + "|" + .spec.compositeTypeRef.kind' "${PKG_DIR[$n]}/composition.yaml")
            [ "$xrd_api" = "$comp_api" ] || err "$n: composition.yaml composes $comp_api, the XRD defines $xrd_api"
        fi
    done

    if [ "$fail" = 1 ]; then
        echo "configurations: DRIFT (see above)" >&2
        return 1
    fi
    echo "configurations: ok (${#PKGS[@]} packages)"
}

# ── list / closure ───────────────────────────────────────────────────────────
cmd_list() {
    local n kind pkg ver deps
    select_pkgs "${1:-}"
    {
        printf 'PACKAGE\tVERSION\tDEPENDS ON\n'
        for n in "${SEL[@]}"; do
            deps=""
            while IFS='|' read -r kind pkg ver; do
                case "$kind" in
                    Configuration) deps+="${pkg##*/configuration-}$ver " ;;
                    *) deps+="${pkg##*/}:$ver " ;;
                esac
            done < <(declared "$n")
            printf 'configuration-%s\t%s\t%s\n' "$n" "$(version_of "$n" || true)" "${deps:--}"
        done
    } | column -t -s $'\t'
}

# Sets CLOS to the packages and, transitively, every Configuration they
# depend on.
closure() {
    local -A seen=()
    local queue=("$@") n kind pkg ver dep
    CLOS=()
    while [ "${#queue[@]}" -gt 0 ]; do
        n=${queue[0]}
        queue=("${queue[@]:1}")
        [ -z "${seen[$n]:-}" ] || continue
        [ -n "${PKG_DIR[$n]:-}" ] || die "unknown package '$n'"
        seen[$n]=1
        CLOS+=("$n")
        while IFS='|' read -r kind pkg ver; do
            [ "$kind" = Configuration ] || continue
            dep=$(pkg_of_ref "$pkg") && queue+=("$dep")
        done < <(declared "$n")
    done
}

cmd_closure() {
    local n
    [ -n "${1:-}" ] || die "usage: closure <package> [--modules]"
    closure "$1"
    if [ "${2:-}" = --modules ]; then
        for n in "${CLOS[@]}"; do echo "${PKG_MOD[$n]}"; done | awk '!seen[$0]++'
    else
        printf '%s\n' "${CLOS[@]}"
    fi
}

# ── build / push ─────────────────────────────────────────────────────────────
parse_opts() {
    FILTER="" REGISTRY=$canonical PUSH_TO="" KCL_REG="" SKIP_TAGGED=0 TAG=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --registry) REGISTRY=$2; shift ;;
            --push-to) PUSH_TO=$2; shift ;;
            --kcl-registry) KCL_REG=$2; shift ;;
            --skip-tagged) SKIP_TAGGED=1 ;;
            --tag) TAG=1 ;;
            -*) die "unknown option $1" ;;
            *) FILTER=$1 ;;
        esac
        shift
    done
    PUSH_TO=${PUSH_TO:-$REGISTRY}
}

out_dir="$root/tmp/xpkg/configurations"

build_one() {
    local n=$1 s="$out_dir/$1" file="$out_dir/$1.xpkg"
    rm -rf "$s" "$file"
    mkdir -p "$s"
    C="^${canonical//./\\.}/configuration-" R="$REGISTRY/configuration-" yq \
        '(.spec.dependsOn[] | select(.kind == "Configuration") | .package) |= sub(strenv(C); strenv(R))' \
        "$(meta "$n")" >"$s/crossplane.yaml"
    if [ -n "$KCL_REG" ]; then
        sed "s#oci://$canonical/#oci://$KCL_REG/#" "${PKG_DIR[$n]}/$(payload "$n")" >"$s/$(payload "$n")"
    else
        cp "${PKG_DIR[$n]}/$(payload "$n")" "$s/"
    fi
    # --examples-root defaults to ./examples relative to the CWD, not the
    # package root; point it at a directory that does not exist.
    crossplane xpkg build --package-root="$s" --examples-root="$s/examples" --package-file="$file" >&2
    echo "$file"
}

cmd_build() {
    local n file
    parse_opts "$@"
    select_pkgs "$FILTER"
    for n in "${SEL[@]}"; do
        file=$(build_one "$n")
        echo "built $(rel "$file") ($(version_of "$n"))"
    done
}

cmd_push() {
    local n ver tag file
    parse_opts "$@"
    select_pkgs "$FILTER"
    # A single package or module brings every Configuration it depends on:
    # pushing it alone would leave the cluster unable to resolve them.
    closure "${SEL[@]}"
    for n in "${CLOS[@]}"; do
        ver=$(version_of "$n")
        [ -n "$ver" ] || die "$n has no version — run 'tools/configurations.sh bump $n'"
        tag="xpkg/configuration-$n/$ver"
        if [ "$SKIP_TAGGED" = 1 ] && git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            continue
        fi
        file=$(build_one "$n")
        crossplane xpkg push -f "$file" "$(pkg_ref "$n" "$PUSH_TO"):$ver"
        echo "pushed $(pkg_ref "$n" "$PUSH_TO"):$ver"
        if [ "$TAG" = 1 ]; then git -C "$root" tag "$tag"; fi
    done
}

# ── cluster-side helpers ─────────────────────────────────────────────────────
module_dir() {
    if [ -z "${1:-}" ] || [ -z "${PKG_DIR[$1]:-}" ] || ! is_base "$1"; then die "unknown module '${1:-}'"; fi
    printf '%s' "${PKG_MODDIR[$1]}"
}

# Documents of a multi-document file, one compact JSON per line.
docs() { yq -o=json -I=0 "select(.kind != null) | $2" "$1"; }

cmd_runtime() {
    local f doc first=1 name image cfg
    f="$(module_dir "${1:-}")/xrd/providers.yaml"
    [ -f "$f" ] || return 0
    emit() { [ "$first" = 1 ] || echo "---"; first=0; yq -P '.' <<<"$1"; }
    while read -r doc; do emit "$doc"; done < <(docs "$f" 'select(.kind != "Provider")')
    # A dependency-installed Provider has no runtimeConfigRef of its own; an
    # ImageConfig gives it the one xrd/providers.yaml sets (Crossplane >= 2.2).
    # Apply this before the Configuration: an ImageConfig created later is
    # only picked up on the revision's next reconcile.
    while IFS='|' read -r name image cfg; do
        # yq prints an empty line (and a `---`) for every document select drops.
        if [ -z "$name" ] || [ "$name" = --- ]; then continue; fi
        emit "$(N=$name I=${image%:*} C=$cfg yq -n -o=json -I=0 '{
            "apiVersion": "pkg.crossplane.io/v1beta1", "kind": "ImageConfig",
            "metadata": {"name": strenv(N)},
            "spec": {"matchImages": [{"type": "Prefix", "prefix": strenv(I)}], "runtime": {"configRef": {"name": strenv(C)}}}}')"
    done < <(yq -r 'select(.kind == "Provider" and .spec.runtimeConfigRef.name != null) | [.metadata.name, .spec.package, .spec.runtimeConfigRef.name] | join("|")' "$f")
}

cmd_providerconfigs() {
    local f doc av kind first=1
    f="$(module_dir "${1:-}")/xrd/providerconfigs.yaml"
    [ -f "$f" ] || return 0
    while read -r doc; do
        av=$(yq -r '.apiVersion' <<<"$doc")
        kind=$(yq -r '.kind' <<<"$doc")
        kubectl explain "$kind" --api-version="$av" >/dev/null 2>&1 || {
            echo "skip $kind ($av): not served — its provider is not installed" >&2
            continue
        }
        [ "$first" = 1 ] || echo "---"
        first=0
        yq -P '.' <<<"$doc"
    done < <(docs "$f" '.')
}

cmd_manifest() {
    local n first=1
    parse_opts "$@"
    select_pkgs "$FILTER"
    for n in "${SEL[@]}"; do
        [ "$first" = 1 ] || echo "---"
        first=0
        cat <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: configuration-$n
spec:
  package: $(pkg_ref "$n" "$REGISTRY"):$(version_of "$n")
EOF
    done
}

cmd=${1:-list}
shift || true
case "$cmd" in
    list) cmd_list "${1:-}" ;;
    sync) cmd_sync "${1:-all}" ;;
    check) cmd_check ;;
    bump) cmd_bump "$@" ;;
    build) cmd_build "$@" ;;
    push) cmd_push "$@" ;;
    closure) cmd_closure "$@" ;;
    runtime) cmd_runtime "$@" ;;
    providerconfigs) cmd_providerconfigs "$@" ;;
    manifest) cmd_manifest "$@" ;;
    *)
        echo "usage: configurations.sh [list|sync|check|bump|build|push|closure|runtime|providerconfigs|manifest]" >&2
        exit 2
        ;;
esac
