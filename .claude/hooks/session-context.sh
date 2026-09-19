#!/usr/bin/env bash
# SessionStart: state the delivery target, because every CD command in this
# repo acts on "whatever kubectl points at right now" and that is invisible in
# the transcript otherwise.
#
# Deliberately local-only: kubeconfig read, `docker ps`, `git`. No API-server
# call, so a dead or unreachable cluster cannot stall session startup.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
root=${CLAUDE_PROJECT_DIR:-$PWD}
cd "$root" 2>/dev/null || exit 0

lines=""
add() {
    lines="${lines}$1
"
}

if command -v kubectl >/dev/null 2>&1; then
    ctx=$(kubectl config current-context 2>/dev/null)
    case "${ctx:-}" in
        kind-kcl-e2e) add "kube-context: $ctx (this repo's e2e cluster, root devkit.toml)" ;;
        kind-kcl-manager) add "kube-context: $ctx (manager cluster, manifests/manager/devkit.toml)" ;;
        kind-kcl-cncf|k3d-kcl-cncf) add "kube-context: $ctx (cncf developer cluster, manifests/cncf, \`just cncf-up\`)" ;;
        kind-*) add "kube-context: $ctx (a kind cluster, but not kcl-e2e/kcl-manager/kcl-cncf)" ;;
        "") add "kube-context: none selected" ;;
        *) add "kube-context: $ctx — NOT a local cluster. .claude/hooks/guard-delivery.sh blocks kubectl/helm/flux mutations and \`just install-*\` / \`just cncf-apply\` until this points at kind-kcl-e2e, kind-kcl-manager, kind-kcl-cncf or k3d-kcl-cncf." ;;
    esac
fi

if command -v docker >/dev/null 2>&1; then
    clusters=$(docker ps --filter 'label=io.x-k8s.kind.role=control-plane' --format '{{.Names}}' 2>/dev/null | sed 's/-control-plane$//' | paste -sd, -)
    [ -n "${clusters:-}" ] && add "kind clusters up: $clusters"
    if [ -n "$(docker ps -q -f name=^kind-registry$ 2>/dev/null)" ]; then
        add "local registry: kind-registry up (push localhost:5001, in-cluster 172.18.0.100:80)"
    else
        add "local registry: down — \`just registry\` starts it; \`just publish-all\` and \`just component-push\` need it"
    fi
fi

if command -v git >/dev/null 2>&1; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ -n "${branch:-}" ] && add "git branch: $branch"
    tag=$(git tag -l '*@*' --sort=-creatordate 2>/dev/null | head -n 1)
    [ -n "${tag:-}" ] && add "latest release tag: $tag (release.yml diffs \`nx affected\` against this)"
fi

[ -n "$lines" ] || exit 0

jq -nc --arg m "Delivery state for kcl-packages:
$lines" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $m
    }
}'
