#!/usr/bin/env bash
# PreToolUse(Bash): block the two irreversible delivery mistakes this workspace
# can make, and nothing else.
#
#   1. Publishing a package version to the PUBLIC registry from a laptop.
#      `kcl mod push` can never re-push a version (see the comment block in
#      .github/workflows/release.yml), and versioning + publishing belong to
#      that workflow. Local publishing is fine when it targets the kind
#      registry: `just publish-all`, `just e2e-publish <module>`, or an
#      explicit KCL_REGISTRY=localhost:5001.
#
#   2. Mutating whatever cluster kubectl currently points at. Every CD recipe
#      here targets kind-kcl-e2e (root devkit.toml), kind-kcl-manager
#      (manifests/manager/devkit.toml) or the developer cluster kind-kcl-cncf /
#      k3d-kcl-cncf (manifests/cncf/devkit.toml, `just cncf-up`). Cluster
#      lifecycle commands (devkit cluster create, just up/e2e*/cncf-up) are NOT
#      guarded: they create and select their own context.
#
# Exit 0 with no output = no decision; the normal permission flow applies.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

deny() {
    jq -nc --arg r "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

has() { printf '%s' "$cmd" | grep -Eq "$1"; }

# Start of a command word: line start, a shell separator, whitespace, or the
# tail of a path (`node_modules/.bin/nx`, `/opt/homebrew/bin/flux`).
W='(^|[;&|(]|[[:space:]]|/)'

# A dry run reaches nothing.
has '(^|[[:space:]])--dry-run([[:space:]=]|$)' && exit 0

# ── 1. irreversible OCI publish ──────────────────────────────────────────────
publishes=0
has "${W}kcl[[:space:]]+mod[[:space:]]+push" && publishes=1
has "${W}nx[[:space:]]+release[[:space:]]+publish" && publishes=1
has 'nx-release-publish' && publishes=1
has "${W}nx[[:space:]]+release([[:space:]]|$)" && publishes=1
has "${W}just[[:space:]]+release([[:space:]]|$)" && publishes=1
has "${W}just[[:space:]]+release-(first|publish)([[:space:]]|$)" && publishes=1

if [ "$publishes" = 1 ]; then
    # Recipes that set KCL_REGISTRY to the kind registry themselves.
    if has "${W}just[[:space:]]+(publish-all|e2e-publish|e2e|e2e-kclx|e2e-component|up|workload)([[:space:]]|$)"; then
        exit 0
    fi
    if has 'KCL_REGISTRY=(oci://)?(localhost|127\.0\.0\.1|kind-registry|172\.18\.0\.100)'; then
        exit 0
    fi
    deny "This publishes KCL packages to the public registry (nx.json release.registry = docker.io/yurikrupnik), and \`kcl mod push\` can never re-push a version once it lands. Releasing is .github/workflows/release.yml's job: it patch-bumps the affected releasable projects, rewrites each composition.yaml pin, pushes the tags, then publishes. Locally use \`just release-dry\` to preview, or publish to the kind registry with \`just publish-all\` / \`just e2e-publish <module>\` (both export KCL_REGISTRY=localhost:5001). Override deliberately with an explicit KCL_REGISTRY=localhost:5001 prefix."
fi

# ── 2. cluster mutation against a non-kind context ───────────────────────────
mutates=0
has "${W}kubectl[[:space:]]+(apply|create|delete|patch|replace|edit|scale|annotate|label|rollout|drain|cordon|uncordon|taint)([[:space:]]|$)" && mutates=1
has "${W}helm[[:space:]]+(install|upgrade|uninstall|rollback)([[:space:]]|$)" && mutates=1
has "${W}flux[[:space:]]+(bootstrap|install|uninstall|create|delete|reconcile|suspend|resume)([[:space:]]|$)" && mutates=1
has "${W}just[[:space:]]+(install-all|install-module|install-functions|e2e-apply|e2e-providers|e2e-providerconfigs|cncf-apply)([[:space:]]|$)" && mutates=1

[ "$mutates" = 1 ] || exit 0

# An explicit local context in the command wins over the ambient one.
if has '\-\-context[[:space:]=]+(kind-|k3d-kcl-cncf)'; then exit 0; fi
if has '\-\-context[[:space:]=]'; then
    deny "This mutates a cluster through an explicit --context that is not one of this repo's local clusters (kind-kcl-e2e, kind-kcl-manager, kind-kcl-cncf, k3d-kcl-cncf). Nothing here is written to run against a shared cluster: \`just install-all\` rewrites Composition sources to the in-cluster registry at 172.18.0.100:80, and \`just e2e-providers\` installs Crossplane providers cluster-wide."
fi

command -v kubectl >/dev/null 2>&1 || exit 0
ctx=$(kubectl config current-context 2>/dev/null)
[ -n "$ctx" ] || exit 0
case "$ctx" in
    kind-*) exit 0 ;;
    k3d-kcl-cncf) exit 0 ;;
esac

deny "kubectl's current context is '$ctx', which is not one of this repo's local clusters. Every CD path here assumes kind-kcl-e2e (root devkit.toml, created by \`devkit cluster create\` / \`just e2e-up\`), kind-kcl-manager (manifests/manager/devkit.toml, \`just e2e-manager-up\`) or the developer cluster kind-kcl-cncf / k3d-kcl-cncf (manifests/cncf/devkit.toml, \`just cncf-up kind|k3d\`): \`just install-all\` rewrites Composition sources to oci://kind-registry/, and the providers and Crossplane Functions it applies are cluster-scoped. Switch first (\`kubectl config use-context kind-kcl-e2e\`) or create the cluster, then re-run."
