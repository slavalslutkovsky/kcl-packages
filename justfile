# justfile — generate and manage KCL packages via the nx-kcl generators.
#
# Providers (schema packages under packages/providers/) are GENERATED from
# Crossplane provider CRDs and consumed by the cloud Compositions via relative
# path. They are internal: tagged `area:providers`, and that tag keeps them out
# of `release` (nx.json) and out of `just check` — the same mechanism, reused.
# Add a new one with `just provider …`; you never hand-edit them.
#
# Requires: just, pnpm, kcl; docker + yq for `--image` extraction.

nx := "pnpm exec nx"

# List available commands
default:
    @just --list

# ─── Generate providers (schema packages) ─────────────────────────────────────

#   just provider <name> <image> [service] [scope=namespaced]
#   e.g. just provider gcp-storage ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0 storage
# Generate a provider schema package from a Crossplane provider OCI image (docker + yq).
provider name image service="" scope="namespaced":
    {{nx}} g nx-kcl:import-crd {{name}} --image={{image}} --apiScope={{scope}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-repo <name> <owner/repo> [ref=main] [service]
# Generate a provider schema package from a Crossplane provider GitHub repo (pinned ref).
provider-repo name repo ref="main" service="":
    {{nx}} g nx-kcl:import-crd {{name}} --repo={{repo}} --ref={{ref}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-local <name> <dir> [service]
# Generate a provider schema package from a local directory of CRD YAMLs.
provider-local name dir service="":
    {{nx}} g nx-kcl:import-crd {{name}} --from={{dir}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

# Bootstrap/refresh the storage providers used by the bucket Composition.
seed-providers:
    {{nx}} g nx-kcl:import-crd aws-s3       --image=ghcr.io/crossplane-contrib/provider-aws-s3:v2.6.0       --apiScope=namespaced --no-interactive
    {{nx}} g nx-kcl:import-crd gcp-storage   --image=ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0   --apiScope=namespaced --no-interactive
    {{nx}} g nx-kcl:import-crd azure-storage --image=ghcr.io/crossplane-contrib/provider-azure-storage:v2.6.0 --apiScope=namespaced --no-interactive

# ─── Generate compositions (XRD + per-provider function-kcl modules) ──────────

#   just composition <name> [providers=aws,gcp,azure,rustfs]
#   e.g. just composition bucket   |   just composition bucket aws,gcp
# Scaffold a Crossplane v2 XRD + one function-kcl Composition package per provider.
composition name providers="aws,gcp,azure,rustfs":
    {{nx}} g nx-kcl:composition {{name}} --providers={{providers}} --no-interactive

# ─── Validate ─────────────────────────────────────────────────────────────────

# Build + test + lint the apps (compositions + cluster); providers are skipped.
check:
    {{nx}} run-many -t build test lint --projects=tag:lang:kcl --exclude=tag:area:providers

# Format all hand-written KCL packages with `kcl fmt` (providers are generated, skipped).
fmt:
    {{nx}} run-many -t fmt --projects=tag:lang:kcl

# Lint the generated provider schemas directly with kcl (they carry no nx targets).
lint-providers:
    for d in packages/providers/*/; do echo "== $d ==" && (cd "$d" && kcl lint); done

# ─── Release ──────────────────────────────────────────────────────────────────

# Version, changelog, tag, publish (providers excluded via nx.json).
release:
    {{nx}} release --yes

#   just release-first 0.1.0
# First-ever release when no git tags exist yet.
release-first version:
    {{nx}} release {{version}} --first-release --yes

# ─── Inspect ──────────────────────────────────────────────────────────────────

# List all KCL projects.
projects:
    {{nx}} show projects --projects=tag:lang:kcl

# List the publishable set (everything except providers).
publishable:
    {{nx}} show projects --projects=tag:lang:kcl --exclude=tag:area:providers
