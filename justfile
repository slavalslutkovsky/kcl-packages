# justfile — generate and manage KCL packages via the nx-kcl generators.
#
# Providers (schema packages under packages/providers/) are GENERATED from
# Crossplane provider CRDs and consumed by the cloud Compositions via relative
# path. They are internal: tagged `area:providers`, and that tag keeps them out
# of `release` (nx.json) and out of `just check` — the same mechanism, reused.
# Add a new one with `just provider …`; you never hand-edit them.
#
# Requires: just, pnpm, kcl; docker + yq for `--image` extraction.

# Call the installed binary directly rather than `pnpm exec nx`: pnpm 11 runs a
# verify-deps-before-run check on every `exec`, and a lockfile that trips its
# supply-chain policy then fails the command before nx is ever reached.
nx := "node_modules/.bin/nx"

# List available commands
default:
    @just --list

# ─── Generate providers (schema packages) ─────────────────────────────────────

#   just provider <name> <image> [service] [scope=namespaced]
#   e.g. just provider gcp-storage ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0 storage
# Generate a provider schema package from a Crossplane provider OCI image (docker + yq).
provider name image service="" scope="namespaced":
    {{nx}} g nx-kcl:import-crd {{name}} --directory=packages/providers --image={{image}} --apiScope={{scope}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-repo <name> <owner/repo> [ref=main] [service] [crdPath=package/crds]
# Generate a provider schema package from a Crossplane provider GitHub repo (pinned ref).
provider-repo name repo ref="main" service="" crdPath="package/crds":
    {{nx}} g nx-kcl:import-crd {{name}} --directory=packages/providers --repo={{repo}} --ref={{ref}} --crdPath={{crdPath}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-local <name> <dir> [service]
# Generate a provider schema package from a local directory of CRD YAMLs.
provider-local name dir service="":
    {{nx}} g nx-kcl:import-crd {{name}} --directory=packages/providers --from={{dir}} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

# Bootstrap/refresh the storage providers used by the bucket Composition.
seed-providers:
    just provider aws-s3        ghcr.io/crossplane-contrib/provider-aws-s3:v2.6.0        s3
    just provider gcp-storage   ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0   storage
    just provider azure-storage ghcr.io/crossplane-contrib/provider-azure-storage:v2.6.0 storage

# `helm` backs the in-cluster (valkey) backend; its CRDs live under
# helm.m.crossplane.io, so the version must be v1.x — v0.21 ships
# cluster-scoped CRDs only.
# Bootstrap/refresh the cache providers used by the redis Composition.
seed-redis-providers:
    just provider aws-elasticache ghcr.io/crossplane-contrib/provider-aws-elasticache:v2.6.0 elasticache
    just provider gcp-redis       ghcr.io/crossplane-contrib/provider-gcp-redis:v2.6.0       redis
    just provider helm            ghcr.io/crossplane-contrib/provider-helm:v1.3.0            helm

# The cnpg schema package is generated from the CloudNativePG operator's CRD
# (not a Crossplane provider image) — keep the ref in step with the chart
# version pinned in packages/cloud/postgres/xrd/providerconfigs.yaml.
# Bootstrap/refresh the database providers used by the postgres Composition.
seed-postgres-providers:
    just provider aws-rds                ghcr.io/crossplane-contrib/provider-aws-rds:v2.6.0                rds
    just provider gcp-sql                ghcr.io/crossplane-contrib/provider-gcp-sql:v2.6.0                sql
    just provider azure-dbforpostgresql  ghcr.io/crossplane-contrib/provider-azure-dbforpostgresql:v2.6.0  dbforpostgresql
    just provider-repo cnpg cloudnative-pg/cloudnative-pg v1.27.1 postgresql config/crd/bases

# GCP has no standalone iam provider: service accounts and IAM members live in
# cloudplatform. Azure splits the identity (managedidentity) from its role
# assignments (authorization), so the iam Composition needs both.
# Bootstrap/refresh the identity providers used by the iam Composition.
seed-iam-providers:
    just provider aws-iam               ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0               iam
    just provider gcp-cloudplatform     ghcr.io/crossplane-contrib/provider-gcp-cloudplatform:v2.6.0     cloudplatform
    just provider azure-managedidentity ghcr.io/crossplane-contrib/provider-azure-managedidentity:v2.6.0 managedidentity
    just provider azure-authorization   ghcr.io/crossplane-contrib/provider-azure-authorization:v2.6.0   authorization

# The cluster Composition also composes IAM roles on AWS (EKS cannot exist
# without them), so it shares the aws-iam schema package with `seed-iam-providers`.
# Bootstrap/refresh the Kubernetes providers used by the cluster Composition.
seed-cluster-providers:
    just provider aws-eks                ghcr.io/crossplane-contrib/provider-aws-eks:v2.6.0                eks
    just provider aws-iam                ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0                iam
    just provider gcp-container          ghcr.io/crossplane-contrib/provider-gcp-container:v2.6.0          container
    just provider azure-containerservice ghcr.io/crossplane-contrib/provider-azure-containerservice:v2.6.0 containerservice

# Azure splits the VM (compute) from its NIC and public IP (network), so the
# vm Composition needs both azure providers.
# Bootstrap/refresh the machine providers used by the vm Composition.
seed-vm-providers:
    just provider aws-ec2       ghcr.io/crossplane-contrib/provider-aws-ec2:v2.6.0       ec2
    just provider gcp-compute   ghcr.io/crossplane-contrib/provider-gcp-compute:v2.6.0   compute
    just provider azure-compute ghcr.io/crossplane-contrib/provider-azure-compute:v2.6.0 compute
    just provider azure-network ghcr.io/crossplane-contrib/provider-azure-network:v2.6.0 network

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

# ─── Render locally (no cluster) ──────────────────────────────────────────────
#
# `just render bucket-gcp` shows what the Composition composes, straight from the
# working tree — no publish, no Kind cluster. Needs docker + the crossplane CLI.
# It serves the workspace to a local function-kcl container and keeps it running
# between renders (`just render-stop` to stop it).

#   just render bucket-gcp   |   just render bucket-rustfs --example=bucket-aws
# Render one Composition against its example XR.
render project *args:
    {{nx}} run {{project}}:render {{args}}

# Render every Composition. Fails for any that has no example XR of its own.
render-all:
    {{nx}} run-many -t render

# Stop the reusable function-kcl container.
render-stop:
    -docker rm -f nx-kcl-render

# ─── End-to-end on a real cluster ─────────────────────────────────────────────
#
# `just e2e bucket` (or `just e2e redis`) does the whole thing: Kind cluster via
# devkit, Crossplane, a local OCI registry, publish, install, apply examples.
#
# Why the registry is served on port 80 and not 5000: function-kcl resolves
# `spec.source` through krm-kcl, which does `SplitN(src, ":", 2)` to peel off a
# `:tag` — so ANY port in the source URL is parsed as the tag and the pull dies
# with `repository '<host>' not found`. A port-less host is mandatory.
# The same container is published on the host at :5001 for pushing, because
# macOS Control Center (AirPlay Receiver) already owns port 5000.

registry_host := "kind-registry"          # in-cluster name (docker `kind` network), port 80
registry_push := "localhost:5001"         # host-side address for `kcl mod push`
crossplane_version := "2.3.4"

# Full flow: cluster, crossplane, registry, publish, install, providers, examples.
# Providers must land before the XRs: the composed managed resources are
# instances of CRDs the providers install, and Crossplane cannot even
# rest-map them until then.
e2e module="bucket": e2e-up (e2e-publish module) (e2e-install module) (e2e-providers module) (e2e-providerconfigs module) (e2e-apply module)
    @just e2e-status

# Kind cluster (devkit) + local registry + Crossplane + function runtime config.
e2e-up: e2e-registry
    devkit cluster create
    helm repo add crossplane-stable https://charts.crossplane.io/stable
    helm upgrade --install crossplane crossplane-stable/crossplane \
        --version {{crossplane_version}} -n crossplane-system --create-namespace --wait --timeout 10m

# Start the local OCI registry: `kind-registry` (port 80) in-cluster, :5001 on the host.
e2e-registry:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "$(docker ps -q -f name=^{{registry_host}}$)" ]; then
        docker rm -f {{registry_host}} >/dev/null 2>&1 || true
        docker run -d --restart=always --name {{registry_host}} \
            -e REGISTRY_HTTP_ADDR=0.0.0.0:80 -p 127.0.0.1:5001:80 registry:2 >/dev/null
    fi
    # Idempotent: the network only exists once `kind` has created it.
    docker network connect kind {{registry_host}} 2>/dev/null || true
    curl -fsS http://{{registry_push}}/v2/_catalog >/dev/null && echo "registry ok"

# The vendored provider schemas still `import k8s`, so the function pod resolves
# `k8s = "1.32.4"` at render time. Mirroring it locally (and pointing KPM_REG /
# KPM_REPO at the mirror, see e2e-install) keeps the run hermetic — and dodges
# ghcr.io's anonymous-token exchange, which breaks under OCI_REG_PLAIN_HTTP=on.
# Publish the module's packages plus the `k8s` schema they depend on.
e2e-publish module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(ls -d ~/.kcl/kpm/k8s_1.32.4 2>/dev/null || true)
    if [ -z "$src" ]; then kcl mod pull oci://ghcr.io/kcl-lang/k8s --tag 1.32.4; src=~/.kcl/kpm/k8s_1.32.4; fi
    tmp=$(mktemp -d) && cp -R "$src"/. "$tmp/" && (cd "$tmp" && kcl mod push --force oci://{{registry_push}}/kcl-lang/k8s) && rm -rf "$tmp"
    # `--projects` takes a name glob, so no project-list plumbing is needed
    # (and `nx show projects --json` prefixes a Node deprecation warning that
    # breaks `jq`, while `grep` closing the pipe early makes nx die on EPIPE).
    KCL_REGISTRY={{registry_push}} {{nx}} run-many -t nx-release-publish \
        --projects='{{module}}-*' --skip-nx-cache

# XRD + Functions + function runtime config + Compositions repointed at the local registry.
e2e-install module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl apply -f packages/cloud/{{module}}/xrd/functions.yaml
    kubectl apply -f packages/cloud/{{module}}/xrd/xrd.yaml
    # OCI_REG_PLAIN_HTTP must be exactly "on"/"off" — kpm hard-errors on "true"
    # and the error is sticky for the life of the process.
    kubectl apply -f - <<'YAML'
    apiVersion: pkg.crossplane.io/v1beta1
    kind: DeploymentRuntimeConfig
    metadata:
      name: function-kcl-local-oci
    spec:
      deploymentTemplate:
        spec:
          selector: {}
          template:
            spec:
              containers:
                # Must be `package-runtime`; any other name adds a sidecar instead.
                - name: package-runtime
                  env:
                    - {name: OCI_REG_PLAIN_HTTP, value: "on"}
                    - {name: KPM_REG, value: kind-registry}
                    - {name: KPM_REPO, value: kcl-lang}
    YAML
    kubectl patch function.pkg.crossplane.io function-kcl --type=merge \
        -p '{"spec":{"runtimeConfigRef":{"apiVersion":"pkg.crossplane.io/v1beta1","kind":"DeploymentRuntimeConfig","name":"function-kcl-local-oci"}}}'
    kubectl wait --for=condition=Healthy function.pkg.crossplane.io --all --timeout=600s
    for f in packages/cloud/{{module}}/*/composition.yaml; do
        sed 's#oci://docker.io/yurikrupnik/#oci://{{registry_host}}/#' "$f"; echo "---"
    done | kubectl apply -f -

# Install the Crossplane providers the module's Compositions render against.
e2e-providers module="bucket":
    kubectl apply -f packages/cloud/{{module}}/xrd/providers.yaml
    kubectl wait --for=condition=Healthy provider.pkg.crossplane.io --all --timeout=900s

# Apply the module's ProviderConfigs, if it ships any. Separate from
# e2e-providers because these are instances of CRDs those providers install,
# so they cannot be applied in the same pass.
e2e-providerconfigs module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    f=packages/cloud/{{module}}/xrd/providerconfigs.yaml
    [ -f "$f" ] && kubectl apply -f "$f" || echo "no providerconfigs for {{module}}"

# Apply every example XR for the module.
e2e-apply module="bucket":
    kubectl apply -f packages/cloud/{{module}}/xrd/examples/

# Composites, their composed managed resources, and any render errors.
e2e-status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "── composites ─────────────────────────────────────────────"
    kubectl get composite -A 2>/dev/null || true
    echo "── composed managed resources ─────────────────────────────"
    kubectl get managed -o custom-columns=KIND:.kind,NAME:.metadata.name,SYNCED:'.status.conditions[?(@.type=="Synced")].status',READY:'.status.conditions[?(@.type=="Ready")].status' 2>/dev/null || true
    echo "── render errors (if any) ─────────────────────────────────"
    kubectl get composite -A -o json 2>/dev/null \
        | jq -r '.items[]|select(.status.conditions[]?|select(.type=="Synced" and .status=="False"))|"\(.kind)/\(.metadata.name): \(.status.conditions[]|select(.type=="Synced")|.message)"' || true

# Delete the Kind cluster and the local registry.
e2e-down:
    -devkit cluster delete kcl-e2e
    -docker rm -f {{registry_host}}

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
