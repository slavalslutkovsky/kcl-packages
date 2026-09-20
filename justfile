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
tsc := "node_modules/.bin/tsc"

# Bundles docs/ into one HTML/PDF (`just docs`). Pinned, and fetched on demand
# by `pnpm dlx` rather than installed: see the Docs section below.
monodocs := "pnpm dlx monodocs@0.11.0"

# List available commands
default:
    @just --list

task-1:
    task --taskfile https://raw.githubusercontent.com/go-task/task/main/website/src/public/Taskfile.yml hello -y
uop:
    kind create cluster --config kind.yaml --image kindest/node:v1.31.4
lol:
    kcl run packages/app -D values=manifests/apps/app1.yaml
    kcl run packages/app -D values=manifests/apps/app1.yaml
    nx release version patch --dry-run --first-release
gets:
    kubectl get --raw /api/v1/pods --v=6 | jless

# ─── Render locally with the kcl CLI ─────────────────────────────────────────
#   just app <values.yaml> [env]        one app release (packages/app)
#   just manager [values.yaml] [env]    the cluster manager (packages/manager):
#                                       Flux-delivered charts, cert-manager
#                                       issuers, cluster-scope chaos. The values'
#                                       `role` picks the cluster kind: `manager`
#                                       renders every chart, `workload` only the
#                                       `application` ones — e.g.
#                                       `just manager <values> workload` with a
#                                       `<stem>.workload.yaml` overlay
#   just manager-phase <type> [values.yaml] [env]
#                                       split one render by chart type via the
#                                       label platform.example.org/type
#   just cncf [values.yaml] [env]       the local developer cluster
#                                       (packages/cncf): ingress-nginx,
#                                       cert-manager, a self-signed → local CA
#                                       chain and the wildcard certificate
#                                       ingress-nginx serves by default. `env`
#                                       k3d / openshift picks the
#                                       values.<env>.yaml overlay
#   just gitops [values.yaml] [env]     the self-hosted forge and the repo the
#                                       cluster reconciles from
#                                       (packages/gitops): tenant Entitlement,
#                                       Forge, its Repositories, and the Flux
#                                       GitRepository + Kustomization. `env`
#                                       forge picks the values.forge.yaml
#                                       overlay, which repoints Flux at the
#                                       forge's own copy of the repo
#   just fleet [values.yaml] [env]      the app of apps (packages/fleet): one
#                                       Component XR per app, a platform layer
#                                       every team app waits for, and one
#                                       Namespace per team. Split a render by
#                                       layer with
#                                       `kubectl apply -l platform.example.org/layer=platform`
#   just entitlements [values.yaml]     who has paid for what
#                                       (packages/platform/entitlement)
#   just bucket-import <state> [ns] [mode]
#                                       Bucket XRs that ADOPT the buckets a
#                                       Terraform or Pulumi state already
#                                       manages (packages/cloud/bucket/import);
#                                       docs/bucket-import.md
#   just catalog <values.yaml> [env]    the Backstage entities of one app
#                                       release (packages/app): a Component and
#                                       its APIs
#   just manager-catalog [values.yaml] [env]
#                                       the Backstage entities of one cluster
#                                       (packages/manager): the cluster itself
#                                       and one per chaos Workflow
# All but the last two print a manifest stream: pipe into `kubectl apply -f -`.
# The two catalog recipes print Backstage entities, which are NOT Kubernetes
# objects — redirect them to a catalog-info.yaml the portal reads, never into
# kubectl (docs/backstage.md). `env` picks the <stem>.<env>.yaml overlay next
# to the values file.
app values env="":
    kcl run packages/app -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

manager values="packages/manager/examples/values.yaml" env="":
    kcl run packages/manager -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

cncf values="packages/cncf/examples/values.yaml" env="":
    kcl run packages/cncf -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

gitops values="packages/gitops/examples/values.yaml" env="":
    kcl run packages/gitops -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

fleet values="packages/fleet/examples/values.yaml" env="":
    kcl run packages/fleet -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

# The portal side of the same values files: entities, not manifests. Piping
# either of these into `kubectl apply` is a mistake — backstage.io/v1alpha1 is
# not a Kubernetes API. See docs/backstage.md.
catalog values env="":
    kcl run packages/app -D values={{ values }} -D catalog=true {{ if env != "" { "-D env=" + env } else { "" } }} -q

manager-catalog values="packages/manager/examples/values.yaml" env="":
    kcl run packages/manager -D values={{ values }} -D catalog=true {{ if env != "" { "-D env=" + env } else { "" } }} -q

# One type of the manager's charts out of a render, by the label the `type`
# field becomes. `role` in the values is the normal way to pick what a cluster
# gets; this is for splitting a stream that already has both.
manager-phase type values="packages/manager/examples/values.yaml" env="":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ type }}" in manager|application) ;; *) echo "type must be manager or application, got '{{ type }}'" >&2; exit 2 ;; esac
    just manager {{ values }} {{ env }} | yq 'select(.metadata.labels["platform.example.org/type"] == "{{ type }}")'

# Cluster-scoped, one per tenant namespace, and normally written by whatever
# owns billing — this renders them from a tenant list instead, so a demo or a
# test cluster can have them in version control. `known_features` in
# packages/platform/entitlement/lib.k makes a typo'd feature key a build
# failure rather than a tenant who paid and got a fatal render.
# Render the paid-feature records the gated Compositions read.
entitlements values="":
    kcl run packages/platform/entitlement {{ if values != "" { "-D values=" + values } else { "" } }} -q

# ─── Move buckets out of Terraform / Pulumi ───────────────────────────────────
#   just bucket-import terraform.tfstate                 one XR per bucket, observe mode
#   just bucket-import <(terraform show -json) prod      remote backends: no state file on disk
#   just bucket-import <(pulumi stack export) prod manage
#   just bucket-import-report state.json                 what was found, dropped, skipped
#
# `state` is a raw terraform.tfstate, a `terraform show -json`, or a `pulumi
# stack export` — told apart by shape. Every XR pins the real cloud name under
# spec.import.existingName and defaults to mode=observe + deletionPolicy=Orphan,
# so applying the output changes nothing in the cloud and can delete nothing:
# Crossplane only starts reading. Flip to `manage` (here, or by editing the
# XR) once status agrees with the spec, then `terraform state rm` / `pulumi
# state delete` the address the XR carries. docs/bucket-import.md is the walk.
# Process substitution (`<(...)`) works: the path is read once, up front.
bucket-import state namespace="default" mode="observe":
    kcl run packages/cloud/bucket/import -D state="$(realpath {{ state }})" -D namespace={{ namespace }} -D mode={{ mode }} -q

# A REPORT, not a manifest — no apiVersion, never pipe it into kubectl.
bucket-import-report state:
    kcl run packages/cloud/bucket/import -D state="$(realpath {{ state }})" -D report=true -q

# ─── Price the portable size ladders ──────────────────────────────────────────
#   just price [values.yaml] [env]   what an estate costs on aws / gcp / azure
#   just price-refresh [cloud...]    re-fetch the rate card from the vendor APIs
#   just price-check                 fail if the committed card has drifted
#
# `size: medium` is one word that means m5.large, e2-standard-2 or
# Standard_D2s_v5 depending on a compositionSelector label, and those are not
# the same monthly bill. `price` reads the ladders out of the backend packages
# themselves (packages/platform/pricing takes them as path dependencies), so a
# ladder change cannot silently desync from its price — it fails the build.
#
# The output is a REPORT, not a manifest: no apiVersion, never pipe it into
# kubectl. docs/pricing.md says what the card covers and what it does not.
price values="packages/platform/pricing/examples/values.yaml" env="":
    kcl run packages/platform/pricing -D values={{ values }} {{ if env != "" { "-D env=" + env } else { "" } }} -q

# Rewrite packages/platform/pricing/rates.k from the public pricing APIs, one
# block per cloud. azure needs no credentials; aws needs AWS_ACCESS_KEY_ID +
# AWS_SECRET_ACCESS_KEY (GetProducts is free); gcp needs GOOGLE_API_KEY, which
# this repo deliberately does not hold — it fails naming the variable rather
# than writing a guess. With no argument it tries all three.
#   just price-refresh azure          GOOGLE_API_KEY=... just price-refresh gcp
price-refresh *clouds:
    node tools/pricing/src/refresh-rates.ts {{ clouds }}

# Fail if a committed rate no longer matches the vendor, or if a block is past
# its 90-day as_of contract. Not a pre-commit hook: it is a network call to
# three vendors, and a rate card going stale is a Monday problem, not a
# reason to block a commit.
price-check *clouds:
    node tools/pricing/src/refresh-rates.ts {{ clouds }} --check

# ─── Local platform (devkit) ──────────────────────────────────────────────────
#
# `just up` is the whole local platform in one command:
#   1. devkit up  — Kind cluster + the add-ons its flags ask for (istio, core,
#      gitops, observability, flux) and the [[deps]] in devkit.toml (Crossplane).
#   2. the local OCI registry the Compositions are published to, joined to the
#      `kind` docker network (which is why it comes AFTER the cluster).
#   3. this repo: every package built/tested, published to that registry, and
#      every module's Crossplane layer (Functions, XRDs, Compositions) installed
#      and repointed at it.
#
# Crossplane PROVIDERS are not installed here: the cloud ones need real
# credentials and each one is a pod. They are opt-in per module — `just workload
# <module> <backend>` pulls in exactly the ones that module renders against.
#
# `flags` goes straight to `devkit up`, so its escape hatches are available:
# --skip-secrets (no vals/.env), --skip-dbs, --skip-tilt, --dry-run, -w N.

#   just up   |   just up "--istio --flux --skip-tilt"   |   just up --dry-run
# Cluster + add-ons + registry + every module's XRDs and Compositions.
up *flags="--istio --core --gitops --observability --flux": check
    devkit up {{ flags }}
    @just registry
    @just publish-all
    @just install-all
    @just status

#   just workload registry zot   |   just workload bucket aws
# Providers must land before the XR: the composed managed resources are
# instances of CRDs the providers install, and Crossplane cannot even rest-map
# them until then.
# Create one workload (an XR) on the running platform: install that module's
# providers and ProviderConfigs, then apply its <module>-<backend> example.
workload module backend: install-functions (install-module module) (e2e-providers module) (e2e-providerconfigs module)
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl apply -f "$(just module-dir {{ module }})/xrd/examples/{{ module }}-{{ backend }}.yaml"
    just status

#   just down   |   just down --keep-cluster
# Tear the platform down: devkit's cluster and add-ons, plus the local registry.
down *flags:
    #!/usr/bin/env bash
    set -uo pipefail
    devkit down {{ flags }} || true
    # The registry is only reachable from a cluster on the `kind` docker
    # network, so it outlives a --keep-cluster teardown and nothing else.
    case " {{ flags }} " in
        *" --keep-cluster "*) echo "kept {{ registry_host }}" ;;
        *) docker rm -f {{ registry_host }} >/dev/null 2>&1 || true ;;
    esac

# Modules live one level below an AREA: packages/cloud/<module> for the portable
# cloud capabilities, packages/platform/<module> for the wrappers that compose
# them. Everything downstream (install, providers, examples) resolves the
# directory through here rather than hard-coding an area.
# Print the directory of one module.
module-dir module:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in packages/*/{{ module }}/xrd; do
        [ -d "$d" ] || continue
        dirname "$d"
        exit 0
    done
    echo "no module '{{ module }}' under packages/*/ (needs an xrd/ dir)" >&2
    exit 1

# Every module: one per packages/*/<module>/xrd.
modules:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in packages/*/*/xrd; do basename "$(dirname "$d")"; done

# The backends of one module: the Composition packages beside its xrd/.
backends module:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in "$(just module-dir {{ module }})"/*/; do
        [ -f "$d/composition.yaml" ] && basename "$d" || true
    done

# Cluster, Crossplane packages, XRDs and every composite.
status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "── nodes ──────────────────────────────────────────────────"
    kubectl get nodes -o wide 2>/dev/null || true
    echo "── crossplane packages ────────────────────────────────────"
    kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io 2>/dev/null || true
    echo "── xrds ───────────────────────────────────────────────────"
    # Compositions of every module are noisy at this level; the composite view
    # (and any render error) is what you actually watch.
    kubectl get xrd 2>/dev/null || true
    just e2e-status

# ─── Generate providers (schema packages) ─────────────────────────────────────

#   just provider <name> <image> [service] [scope=namespaced]
#   e.g. just provider gcp-storage ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0 storage
# Generate a provider schema package from a Crossplane provider OCI image (docker + yq).
provider name image service="" scope="namespaced":
    {{ nx }} g nx-kcl:import-crd {{ name }} --directory=packages/providers --image={{ image }} --apiScope={{ scope }} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-repo <name> <owner/repo> [ref=main] [service] [crdPath=package/crds]
# Generate a provider schema package from a Crossplane provider GitHub repo (pinned ref).
provider-repo name repo ref="main" service="" crdPath="package/crds":
    {{ nx }} g nx-kcl:import-crd {{ name }} --directory=packages/providers --repo={{ repo }} --ref={{ ref }} --crdPath={{ crdPath }} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

#   just provider-local <name> <dir> [service]
# Generate a provider schema package from a local directory of CRD YAMLs.
provider-local name dir service="":
    {{ nx }} g nx-kcl:import-crd {{ name }} --directory=packages/providers --from={{ dir }} {{ if service != "" { "--service=" + service } else { "" } }} --no-interactive

# ─── XRD schema packages (typed child XRs) ────────────────────────────────────
#
# A module's xrd/ dir can also be a KCL package — `<module>-xrd` — holding the
# schemas `kcl import` derives from its own xrd.yaml. A composite of composites
# (platform/inbox) imports them by path to build its child XRs against the same
# contract the cluster enforces, and that path dependency is the edge the Nx
# graph shows. kcl import only knows CRDs, so the XRD is first shaped into the
# CRD Crossplane itself would serve for it: kind/apiVersion renamed, one
# storage version, and `spec.crossplane` (composition selection) added, which
# Crossplane injects into every v2 XR schema and is what a composer sets.
# models/ is generated — never hand-edit it; re-run after changing the XRD.

#   just xrd-schema <module>        e.g. just xrd-schema bucket
# Generate (or refresh) packages/*/<module>/xrd as the `<module>-xrd` schema package.
xrd-schema module:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(just module-dir {{ module }})/xrd"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    yq '
      .apiVersion = "apiextensions.k8s.io/v1" | .kind = "CustomResourceDefinition"
      | .spec.versions[] |= (.storage = true | del(.referenceable) | del(.additionalPrinterColumns))
      | .spec.versions[].schema.openAPIV3Schema.properties.spec.properties.crossplane = {
          "type": "object",
          "description": "Crossplane composition selection, injected into every v2 XR by Crossplane itself; a composer sets compositionSelector or compositionRef to pick the backend.",
          "properties": {
            "compositionRef": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
            "compositionRevisionRef": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
            "compositionRevisionSelector": {"type": "object", "properties": {"matchLabels": {"type": "object", "additionalProperties": {"type": "string"}}}, "required": ["matchLabels"]},
            "compositionSelector": {"type": "object", "properties": {"matchLabels": {"type": "object", "additionalProperties": {"type": "string"}}}, "required": ["matchLabels"]},
            "compositionUpdatePolicy": {"type": "string", "enum": ["Automatic", "Manual"]}
          }
        }
    ' "$dir/xrd.yaml" > "$tmp/{{ module }}.yaml"
    if [ ! -f "$dir/kcl.mod" ]; then
        printf '[package]\nname = "%s-xrd"\nedition = "v0.12.3"\nversion = "0.1.0"\n' "{{ module }}" > "$dir/kcl.mod"
        # Pinned like the provider packages (import-crd generator): ObjectMeta comes from k8s.
        (cd "$dir" && kcl mod add k8s:1.32.4 >/dev/null)
        cat > "$dir/main.k" <<EOF
    # {{ module }}-xrd — KCL schemas of the {{ module }} XRD, generated from ./xrd.yaml
    # via \`just xrd-schema {{ module }}\` (kcl import -m crd). Import the composite type:
    #   import {{ module }}_xrd.models.v1alpha1.<group>_v1alpha1_<kind> as <alias>
    # Regenerate after every change to xrd.yaml; models/ is not hand-edited.
    _generated = "see ./models for schemas"
    EOF
    fi
    rm -rf "$dir/models"
    (cd "$dir" && kcl import -m crd -f "$tmp/{{ module }}.yaml" >/dev/null)
    # kcl import writes a nested models/kcl.mod, which would be a spurious Nx project.
    rm -f "$dir/models/kcl.mod" "$dir/models/kcl.mod.lock"
    # Unlike packages/providers/**, xrd/ is in the pre-commit fmt/lint scope; ship
    # the formatted form so the kcl-fmt hook has nothing to rewrite.
    (cd "$dir/models" && kcl fmt ./... >/dev/null)
    echo "generated $dir/models"

# Bootstrap/refresh the storage providers used by the bucket Composition.
seed-providers:
    just provider aws-s3        ghcr.io/crossplane-contrib/provider-aws-s3:v2.6.0        s3
    just provider gcp-storage   ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0   storage
    just provider azure-storage ghcr.io/crossplane-contrib/provider-azure-storage:v2.6.0 storage

# A static page on a custom domain is three services per cloud, not one: the
# object store, the CDN that is the only place TLS can terminate, and (on AWS)
# the certificate authority CloudFront will accept. The storage families come
# from `just seed-providers`; these are the edge ones.
# Bootstrap/refresh the edge providers used by the landing Composition.
seed-landing-providers:
    just provider aws-cloudfront ghcr.io/crossplane-contrib/provider-aws-cloudfront:v2.6.0 cloudfront
    just provider aws-acm        ghcr.io/crossplane-contrib/provider-aws-acm:v2.6.0        acm
    just provider gcp-compute    ghcr.io/crossplane-contrib/provider-gcp-compute:v2.6.0    compute
    just provider azure-cdn      ghcr.io/crossplane-contrib/provider-azure-cdn:v2.6.0      cdn
    just provider helm           ghcr.io/crossplane-contrib/provider-helm:v1.3.0           helm

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
# Bootstrap/refresh the identity providers used by the iam and
# workload-identity Compositions (both render against the same four).
seed-iam-providers:
    just provider aws-iam               ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0               iam
    just provider gcp-cloudplatform     ghcr.io/crossplane-contrib/provider-gcp-cloudplatform:v2.6.0     cloudplatform
    just provider azure-managedidentity ghcr.io/crossplane-contrib/provider-azure-managedidentity:v2.6.0 managedidentity
    just provider azure-authorization   ghcr.io/crossplane-contrib/provider-azure-authorization:v2.6.0   authorization

# One family per cloud per concern. GCP: Folder/Project/ProjectService and the
# org- and folder-level IAM kinds are cloudplatform (shared with
# `seed-iam-providers`), Org Policy v2 has a family of its own. AWS: the whole
# hierarchy — OU, Account, SCP, attachment — is one Organizations family.
# Azure: management groups come from `management`, while the policy assignment
# and the role assignment come from `authorization` (also shared with
# `seed-iam-providers`). Azure subscriptions are NOT here: azurerm_subscription
# lives in the upstream `azure` family, which crossplane-contrib does not
# publish at v2.x.
# Bootstrap/refresh the hierarchy providers used by the organization Compositions.
seed-organization-providers:
    just provider gcp-cloudplatform    ghcr.io/crossplane-contrib/provider-gcp-cloudplatform:v2.6.0    cloudplatform
    just provider gcp-orgpolicy        ghcr.io/crossplane-contrib/provider-gcp-orgpolicy:v2.6.0        orgpolicy
    just provider aws-organizations    ghcr.io/crossplane-contrib/provider-aws-organizations:v2.6.0    organizations
    just provider azure-management     ghcr.io/crossplane-contrib/provider-azure-management:v2.6.0     management
    just provider azure-authorization  ghcr.io/crossplane-contrib/provider-azure-authorization:v2.6.0  authorization

# The cluster Composition also composes IAM roles on AWS (EKS cannot exist
# without them), so it shares the aws-iam schema package with `seed-iam-providers`.
# The onprem backend adopts an existing cluster and installs Flux/Crossplane
# into it through provider-helm, reusing the helm schema package pinned by
# `seed-redis-providers`.
# Bootstrap/refresh the Kubernetes providers used by the cluster Composition.
seed-cluster-providers:
    just provider aws-eks                ghcr.io/crossplane-contrib/provider-aws-eks:v2.6.0                eks
    just provider aws-iam                ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0                iam
    just provider gcp-container          ghcr.io/crossplane-contrib/provider-gcp-container:v2.6.0          container
    just provider azure-containerservice ghcr.io/crossplane-contrib/provider-azure-containerservice:v2.6.0 containerservice
    just provider helm                   ghcr.io/crossplane-contrib/provider-helm:v1.3.0                   helm

# Azure splits the VM (compute) from its NIC and public IP (network), so the
# vm Composition needs both azure providers. The self-hosted (kubevirt)
# backend needs no Crossplane provider at all — it composes kubevirt.io/v1
# VirtualMachines directly — but it does need their schemas, and those are
# catalog-sourced: KubeVirt and CDI build their CRDs in Go inside their
# operators, so no repo path or release asset holds the YAML. Only
# registry.yaml knows which catalog schemas to rebuild, hence the
# registry-driven line (see packages/providers/registry.yaml, `kubevirt`).
# Bootstrap/refresh the machine providers used by the vm Composition.
seed-vm-providers:
    just provider aws-ec2       ghcr.io/crossplane-contrib/provider-aws-ec2:v2.6.0       ec2
    just provider gcp-compute   ghcr.io/crossplane-contrib/provider-gcp-compute:v2.6.0   compute
    just provider azure-compute ghcr.io/crossplane-contrib/provider-azure-compute:v2.6.0 compute
    just provider azure-network ghcr.io/crossplane-contrib/provider-azure-network:v2.6.0 network
    tools/providers.sh seed kubevirt

# Velero is an operator, like cnpg: the backup Composition composes
# velero.io/v1 Schedule / BackupStorageLocation directly and provider-helm
# (seeded with the redis providers) installs the chart. Keep the ref in step
# with the chart version pinned in backup/xrd/providerconfigs.yaml.
# Bootstrap/refresh the schema package used by the backup Composition.
seed-backup-providers:
    just provider-repo velero vmware-tanzu/velero v1.18.2 velero config/crd/v1/bases

# Neither of these is a Crossplane provider: the application Composition
# composes gateway.networking.k8s.io/v1 HTTPRoute and networking.istio.io/v1
# VirtualService / DestinationRule directly, so only their schemas are needed.
# Gateway API is generated from the standard channel alone (the experimental
# kinds are not composed). Istio generates every CRD into ONE multi-doc file,
# so `crdPath` is the directory that holds it and `service: crd-all` selects
# crd-all.gen.yaml over the profile-*.yaml siblings. Keep both refs in step
# with packages/providers/registry.yaml.
# Bootstrap/refresh the routing schema packages used by the application Composition.
seed-application-providers:
    just provider-repo gateway-api kubernetes-sigs/gateway-api v1.4.0 gateway config/crd/standard
    just provider-repo istio       istio/istio                 1.28.1 crd-all manifests/charts/base/files

# The network Composition is the odd one out: it also publishes the RDS and
# ElastiCache subnet groups its private subnets exist for (a PostgresInstance or
# RedisInstance attaches to those), so the aws backend renders against three
# schema packages. It shares aws-ec2 with `seed-vm-providers`, aws-rds with
# `seed-postgres-providers` and aws-elasticache with `seed-redis-providers`.
# There is no in-cluster backend: a Kubernetes cluster already has a network.
# Bootstrap/refresh the network providers used by the network Composition.
seed-network-providers:
    just provider aws-ec2         ghcr.io/crossplane-contrib/provider-aws-ec2:v2.6.0         ec2
    just provider aws-rds         ghcr.io/crossplane-contrib/provider-aws-rds:v2.6.0         rds
    just provider aws-elasticache ghcr.io/crossplane-contrib/provider-aws-elasticache:v2.6.0 elasticache
    just provider gcp-compute     ghcr.io/crossplane-contrib/provider-gcp-compute:v2.6.0     compute

# Each cloud files its hub under a different service, so there is no shared
# family here: the Transit Gateway is ec2 (shared with `seed-network-providers`
# and `seed-vm-providers`), Virtual WAN is azure network (shared with
# `seed-vm-providers`), and GCP has a service of its own. Network Connectivity
# Center is the only GCP fabric that makes spoke-to-spoke traffic transitive,
# which is why gcp-compute's VPC peering is NOT what the hubspoke backend uses.
# Bootstrap/refresh the transit providers used by the hubspoke Composition.
seed-hubspoke-providers:
    just provider aws-ec2                   ghcr.io/crossplane-contrib/provider-aws-ec2:v2.6.0                   ec2
    just provider azure-network             ghcr.io/crossplane-contrib/provider-azure-network:v2.6.0             network
    just provider gcp-networkconnectivity   ghcr.io/crossplane-contrib/provider-gcp-networkconnectivity:v2.6.0   networkconnectivity

# Lambda needs an execution role, so the serverless Composition shares the
# aws-iam schema package with `seed-iam-providers`. The knative schema package
# comes from the Knative Serving repo (an operator CR, like cnpg) — keep the
# ref in step with the Knative version installed on self-hosted clusters. The
# CRD list is explicit because the other files in that dir are git symlinks
# into vendor/ (unreadable via raw.githubusercontent) or internal API groups.
# Bootstrap/refresh the runtime providers used by the serverless Composition.
seed-serverless-providers:
    just provider aws-lambda         ghcr.io/crossplane-contrib/provider-aws-lambda:v2.6.0         lambda
    -just provider aws-iam           ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0            iam
    just provider gcp-cloudrun       ghcr.io/crossplane-contrib/provider-gcp-cloudrun:v2.6.0       cloudrun
    just provider azure-containerapp ghcr.io/crossplane-contrib/provider-azure-containerapp:v2.6.0 containerapp
    just provider-repo knative knative/serving knative-v1.23.0 service,configuration,revision,route,domain-mapping config/core/300-resources

# GCP has no native email service (Google points at SendGrid/Mailgun), and
# upjet-azure implements only azurerm_communication_service — not the Email
# service or its domains — so email is aws + in-cluster only for now. The
# in-cluster (stalwart) backend reuses the helm schema package pinned by
# `seed-redis-providers`.
# Bootstrap/refresh the identity providers used by the email Composition.
seed-email-providers:
    just provider aws-sesv2 ghcr.io/crossplane-contrib/provider-aws-sesv2:v2.6.0 sesv2
    just provider helm      ghcr.io/crossplane-contrib/provider-helm:v1.3.0      helm

# DNS is a global service on both clouds, but upjet still routes AWS calls
# through a region, so the XRD keeps `region` required. There is no in-cluster
# backend: a zone you cannot delegate to from a registrar is not a DNS zone.
# Bootstrap/refresh the zone providers used by the dns Composition.
seed-dns-providers:
    just provider aws-route53 ghcr.io/crossplane-contrib/provider-aws-route53:v2.6.0 route53
    just provider gcp-dns     ghcr.io/crossplane-contrib/provider-gcp-dns:v2.6.0     dns

# The nats-jetstream schema package is generated from the NACK controller's
# CRDs (an operator CR, like cnpg) — its deploy/crds.yml is one multi-doc file,
# so it goes through provider-local rather than provider-repo. Keep the ref in
# step with the nack chart pinned in packages/cloud/queue/xrd/providerconfigs.yaml
# (chart 0.35.0 = app v0.24.0).
# Bootstrap/refresh the messaging providers used by the queue Composition.
seed-queue-providers:
    just provider aws-sqs    ghcr.io/crossplane-contrib/provider-aws-sqs:v2.6.0    sqs
    just provider gcp-pubsub ghcr.io/crossplane-contrib/provider-gcp-pubsub:v2.6.0 pubsub
    mkdir -p tmp && curl -fsSL https://raw.githubusercontent.com/nats-io/nack/v0.24.0/deploy/crds.yml -o tmp/nack-crds.yml
    just provider-local nats-jetstream tmp/nack-crds.yml

# provider-gcp-apigee ships no APIProxy resource, so the gcp Composition
# composes the runtime slice a proxy needs (Environment, Envgroup + attachment,
# TargetServer) and the proxy bundle is deployed out of band; GCP API Gateway is
# google-beta-only, so upjet-gcp never generated it.
# Bootstrap/refresh the gateway providers used by the apigateway Composition.
seed-apigateway-providers:
    just provider aws-apigatewayv2     ghcr.io/crossplane-contrib/provider-aws-apigatewayv2:v2.6.0     apigatewayv2
    just provider azure-apimanagement  ghcr.io/crossplane-contrib/provider-azure-apimanagement:v2.6.0  apimanagement
    just provider gcp-apigee           ghcr.io/crossplane-contrib/provider-gcp-apigee:v2.6.0           apigee

# GCP's Artifact Registry ships in the `artifact` provider family, whose CRD
# group is artifact.gcp.m.upbound.io (kind RegistryRepository) — there is no
# provider-gcp-artifactregistry image. The in-cluster (zot) backend needs no
# registry provider of its own: it installs the zot chart through the helm
# schema package pinned by `seed-redis-providers`.
# Bootstrap/refresh the registry providers used by the registry Composition.
seed-registry-providers:
    just provider aws-ecr                  ghcr.io/crossplane-contrib/provider-aws-ecr:v2.6.0                  ecr
    just provider gcp-artifact             ghcr.io/crossplane-contrib/provider-gcp-artifact:v2.6.0             artifact
    just provider azure-containerregistry  ghcr.io/crossplane-contrib/provider-azure-containerregistry:v2.6.0  containerregistry

# The self-hosted (openbao) backend keys live in an OpenBao transit engine, and
# the only Crossplane provider for that API is upbound/provider-vault — hence
# xpkg.upbound.io rather than ghcr.io, and v4.x, the first line that ships the
# namespaced *.vault.m.upbound.io CRDs. Its `vault`+`transit` families give the
# Mount and SecretBackendKey the Composition renders; `kcl import` buckets
# their v1alpha1 schemas under models/unknown/.
# Bootstrap/refresh the key-management providers used by the kms Composition.
seed-kms-providers:
    just provider aws-kms        ghcr.io/crossplane-contrib/provider-aws-kms:v2.6.0        kms
    just provider gcp-kms        ghcr.io/crossplane-contrib/provider-gcp-kms:v2.6.0        kms
    just provider azure-keyvault ghcr.io/crossplane-contrib/provider-azure-keyvault:v2.6.0 keyvault
    just provider vault          xpkg.upbound.io/upbound/provider-vault:v4.0.3             vault,transit

# ─── Generate compositions (XRD + per-provider function-kcl modules) ──────────

#   just composition <name> [providers=aws,gcp,azure,rustfs]
#   e.g. just composition bucket   |   just composition bucket aws,gcp
# Scaffold a Crossplane v2 XRD + one function-kcl Composition package per provider.
composition name providers="aws,gcp,azure,rustfs":
    {{ nx }} g nx-kcl:composition {{ name }} --providers={{ providers }} --no-interactive

# ─── Validate ─────────────────────────────────────────────────────────────────

# Build + test + lint the apps (compositions + cluster); providers are skipped.
check:
    {{ nx }} run-many -t build test lint --projects=tag:lang:kcl --exclude=tag:area:providers

# Format all hand-written KCL packages with `kcl fmt` (providers are generated, skipped).
fmt:
    {{ nx }} run-many -t fmt --projects=tag:lang:kcl

# Lint the generated provider schemas directly with kcl (they carry no nx targets).
#lint-providers:
#    for d in packages/providers/*/;
#    do echo "== $d ==" && (cd "$d" && kcl lint);
#    done

# ─── Git hooks (lefthook) ─────────────────────────────────────────────────────
#
# lefthook.yml only ever calls recipes from this file, so every check a hook
# runs is reproducible by hand — `just mod-check`, `just fmt-check`, … — and
# there is one place to change what a check means.
#
# pre-commit is staged-file scoped and stays under a couple of seconds; it runs
# sequentially because `fmt-files` rewrites the same files `lint-files` reads.
# pre-push runs `just check` — the same build/test/lint CI runs, nx-cached, so
# a re-push with nothing new is a handful of cache hits.
#
# Escape hatches: `LEFTHOOK=0 git commit …` skips every hook, `git commit -n`
# skips pre-commit and commit-msg.

# Install the hooks into .git/hooks. Run once per clone.
hooks:
    lefthook install

#   just hooks-run pre-commit   |   just hooks-run pre-push
# pre-commit formats in place here, exactly as it would on a commit.
# Run a hook's jobs over the whole tree, without committing or pushing.
hooks-run hook="pre-commit":
    lefthook run {{ hook }} --all-files

# Format the given KCL files in place; the pre-commit hook re-stages what it rewrites.
fmt-files +files:
    kcl fmt {{ files }}
    nx affected -t fmt,test,build,lint

# `find`, not `git ls-files`: a package generated but not yet added counts too.
# Report hand-written KCL that needs formatting, without rewriting it.
fmt-check:
    #!/usr/bin/env bash
    set -euo pipefail
    files=$(find packages -name '*.k' -not -path 'packages/providers/*')
    [ -n "$files" ] || exit 0
    kcl fmt --dry-run $files

# Providers are generated from CRDs and lint dirty by construction — skipped,
# the same exclusion `check` makes with `--exclude=tag:area:providers`.
# With no arguments: every hand-written package in the tree.
# Lint the packages owning the given files (walks up to the nearest kcl.mod).
lint-files *files:
    #!/usr/bin/env bash
    set -euo pipefail
    files="{{ files }}"
    [ -n "$files" ] || files=$(git ls-files --cached --others --exclude-standard -- '*.k')
    dirs=$(for f in $files; do
        d=$(dirname "$f")
        while [ "$d" != "." ] && [ ! -f "$d/kcl.mod" ]; do d=$(dirname "$d"); done
        [ -f "$d/kcl.mod" ] && echo "$d" || true
    done | sort -u)
    for d in $dirs; do
        case "$d" in packages/providers/*) continue ;; esac
        echo "── kcl lint $d"
        (cd "$d" && kcl lint)
    done

# Catches the broken indentation that would otherwise only surface as a failed
# `kubectl apply` halfway through `just up`.
# With no arguments: every YAML in the tree that git would track.
# Parse the given YAML files, multi-doc aware.
yaml-check *files:
    #!/usr/bin/env bash
    set -euo pipefail
    files="{{ files }}"
    [ -n "$files" ] || files=$(git ls-files --cached --others --exclude-standard -- '*.yaml' '*.yml')
    for f in $files; do
        [ -f "$f" ] || continue
        yq e 'true' "$f" >/dev/null
    done

# Workspace invariants that nothing else enforces:
#   1. kcl.mod names are unique — nx derives the project name from that field,
#      so a duplicate silently collapses two projects into one.
#   2. every `path = "…"` dependency resolves to a real package — the cloud
#      Compositions consume the provider schemas this way, and a stale path
#      only fails much later, inside `kcl run`.
#   3. a Composition's `source:` image matches its own package name — that line
#      is rewritten by `nx release`, and a hand-edit here points a live
#      Composition at somebody else's package.
# Check the workspace invariants nothing else enforces.
mod-check:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    dupes=$(find packages -name kcl.mod -not -path '*/node_modules/*' \
        -exec sed -n 's/^name = "\(.*\)"/\1/p' {} + | sort | uniq -d)
    if [ -n "$dupes" ]; then
        echo "duplicate kcl.mod package names:"; echo "$dupes" | sed 's/^/  /'; fail=1
    fi
    while IFS= read -r mod; do
        dir=$(dirname "$mod")
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            [ -f "$dir/$p/kcl.mod" ] || { echo "$mod: path dependency not found: $p"; fail=1; }
        done < <(grep -o 'path = "[^"]*"' "$mod" | sed 's/path = "//;s/"//')
    done < <(find packages -name kcl.mod -not -path '*/node_modules/*')
    while IFS= read -r comp; do
        dir=$(dirname "$comp")
        # Compositions rendered by a non-KCL function ship no package.
        [ -f "$dir/kcl.mod" ] || continue
        name=$(sed -n 's/^name = "\(.*\)"/\1/p' "$dir/kcl.mod")
        src=$(yq -r '.spec.pipeline[].input.spec.source // ""' "$comp" | grep -v '^$' | head -1)
        [ -z "$src" ] && continue
        pkg=${src##*/}; pkg=${pkg%%\?*}
        [ "$pkg" = "$name" ] || { echo "$comp: source '$src' is not package '$name'"; fail=1; }
    done < <(find packages -name composition.yaml -not -path '*/node_modules/*')
    [ $fail -eq 0 ] && echo "packages ok"
    exit $fail

# `.vals.yaml` and values/ are fine by design: they hold vals REFERENCES
# (ref+…), never values, so nothing here should ever match them.
# With no arguments: every file in the tree that git would track.
# Refuse credential files and obvious secret material in the given files.
secrets-check *files:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    files="{{ files }}"
    [ -n "$files" ] || files=$(git ls-files --cached --others --exclude-standard)
    for f in $files; do
        [ -f "$f" ] || continue
        # Generated from public CRDs, and the AWS descriptions they carry
        # quote AWS's own example access-key id.
        case "$f" in packages/providers/*) continue ;; esac
        case "$(basename "$f")" in
            .env|.env.*|*.pem|*.p12|*.pfx|id_rsa|id_ed25519|kubeconfig|*.kubeconfig)
                echo "$f: credential file — add it to .gitignore instead"; fail=1; continue ;;
        esac
        # The quote is spliced in so this recipe does not match itself.
        q='"'
        if grep -qE "BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|${q}private_key${q}:|aws_secret_access_key[[:space:]]*=" "$f"; then
            echo "$f: looks like it contains a secret"; fail=1
        fi
    done
    exit $fail

# Type-check the TypeScript in tools/ (the nx-kcl plugin, the bench harness, the
# install graph, the rate-card refresher, the Backstage catalog emitter).
typecheck:
    {{ tsc }} --noEmit -p tools/nx-kcl/tsconfig.json
    {{ tsc }} --noEmit -p tools/bench/tsconfig.json
    {{ tsc }} --noEmit -p tools/catalog/tsconfig.json
    {{ tsc }} --noEmit -p tools/graph/tsconfig.json
    {{ tsc }} --noEmit -p tools/pricing/tsconfig.json

# Redraw docs/install-graph.md from devkit.toml [[deps]] and the manager values:
# the wave ladder `devkit cluster deps` runs, and the HelmRelease dependsOn DAG
# Flux keeps. Code dependencies between KCL packages are a different graph —
# `nx graph` draws those from kcl.mod path deps.
graph:
    node tools/graph/src/install-graph.ts

# Fail if docs/install-graph.md no longer matches its sources (pre-commit).
graph-check:
    node tools/graph/src/install-graph.ts --check

# catalog/crossplane.yaml gets an entity per XRD, Composition, example XR and
# generated provider schema package; docs/crossplane-graph.md gets who composes
# whom, how often each XR kind is used, and the refactor findings that fall out
# of it. The entities are consumed by an EXTERNAL Backstage — nothing in this
# repo runs one, so catalog/crossplane.yaml is the whole integration surface.
# Rebuild the Backstage view of the Crossplane estate from packages/**.
crossplane-catalog:
    node tools/catalog/src/catalog.ts

# Fail if catalog/crossplane.yaml or docs/crossplane-graph.md drifted from packages/** (pre-commit).
crossplane-catalog-check:
    node tools/catalog/src/catalog.ts --check

# Speaks MCP over stdio: it is launched BY an MCP client, which owns both ends
# of the pipe — a bare `just mcp` just sits there waiting for a JSON-RPC frame
# on stdin.
# Serve the same scan over MCP, so an agent can query the estate instead of grepping it.
mcp:
    node tools/catalog/src/mcp.ts

# Merge, revert and fixup!/squash! subjects are git's own wording, so they pass
# through untouched.
# `nx release` writes the package changelogs from these.
# Check a commit message file against Conventional Commits.
commit-msg file:
    #!/usr/bin/env bash
    set -euo pipefail
    subject=$(head -1 "{{ file }}")
    pattern='^((build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-zA-Z0-9._/-]+\))?!?: .+|Merge |Revert |fixup!|squash!)'
    if ! printf '%s' "$subject" | grep -qE "$pattern"; then
        echo "commit message is not a Conventional Commit:"
        echo "  $subject"
        echo
        echo "expected: <type>(<scope>)?: <description>"
        echo "types:    build chore ci docs feat fix perf refactor revert style test"
        echo "example:  feat(bucket): add azure backend"
        exit 1
    fi

# ─── Docs (monodocs) ──────────────────────────────────────────────────────────
#
# docs/*.md is a set of files to read in a repo; `just docs` is the same set as
# ONE file to hand to someone — dist/docs.html carries the sidebar, the search
# index, the Shiki highlighting and the mermaid runtime inline, so it opens off
# a USB stick with no server. monodocs.config.yml at the root is the whole
# configuration; the sidebar is derived from the tree, so a new docs/<topic>.md
# needs no edit anywhere.
#
# monodocs runs through `pnpm dlx` on a pinned version rather than as a root
# devDependency: the lockfile currently trips pnpm 12's supply-chain policy, so
# `pnpm add` and `pnpm install` both fail before any binary is reached (the same
# reason `nx` is called by path at the top of this file).

# One self-contained dist/docs.html out of docs/*.md.
docs:
    {{ monodocs }} build

# Needs a real Chromium — monodocs finds one on Linux and Windows, and macOS has
# to be told where it is (PUPPETEER_EXECUTABLE_PATH, defaulted here to Chrome).
# The same document as dist/docs.pdf: bookmarks, and mermaid rasterised.
docs-pdf:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$OSTYPE" == darwin* && -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]]; then
        chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if [[ ! -x "$chrome" ]]; then
            echo "no Chromium found: install Google Chrome, or set PUPPETEER_EXECUTABLE_PATH" >&2
            exit 1
        fi
        export PUPPETEER_EXECUTABLE_PATH="$chrome"
    fi
    {{ monodocs }} build --format pdf -o ./dist/docs.pdf

# Live preview on http://127.0.0.1:4173 while editing docs/.
docs-serve port="4173":
    {{ monodocs }} serve --port {{ port }} --open

# Fail on a broken cross-file link, a missing image or a page with no title.
docs-check:
    {{ monodocs }} validate

# ─── Render locally (no cluster) ──────────────────────────────────────────────
#
# `just render bucket-gcp` shows what the Composition composes, straight from the
# working tree — no publish, no Kind cluster. Needs docker + the crossplane CLI.
# It serves the workspace to a local function-kcl container and keeps it running
# between renders (`just render-stop` to stop it).

#   just render bucket-gcp   |   just render bucket-rustfs --example=bucket-aws
# Render one Composition against its example XR.
render project *args:
    {{ nx }} run {{ project }}:render {{ args }}

# Render every Composition. Fails for any that has no example XR of its own.
render-all:
    {{ nx }} run-many -t render

# Stop the reusable function-kcl container.
render-stop:
    -docker rm -f nx-kcl-render

# ─── kclx (Rust CLI + composition function) ───────────────────────────────────
#
# `rust/` holds one KCL renderer with two front ends: the `kclx` CLI and a
# Crossplane composition function serving the same `kcl-render` engine. Local
# renders therefore cannot drift from what the cluster composes.

#   just kclx packages/cloud/bucket/gcp --oxr packages/cloud/bucket/xrd/examples/bucket-gcp.yaml -n
# Render a KCL package (path, inline source, or oci://<repo>?tag=<v>) to YAML.
kclx source *args:
    cargo run --manifest-path rust/Cargo.toml --release -q -p kclx -- render {{ source }} {{ args }}

# The Function it backs needs the annotation
# render.crossplane.io/runtime: Development.
# Serve the composition function on :9443 for `crossplane render`.
kclx-serve *args:
    cargo run --manifest-path rust/Cargo.toml --release -q -p kclx -- function --insecure {{ args }}

# --locked: kcl-lang/lib depends on kcl-lang/kcl by *branch*, so an unlocked
# resolve silently follows upstream main (see rust/Dockerfile).
# Lint + test the Rust workspace: what CI and the pre-push hook run.
kclx-test:
    cd rust && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked

# Build the function runtime image. The tag is the one the local cluster's
# DeploymentRuntimeConfig expects (manifests/crossplane/functions.yaml);
# --provenance=false keeps buildx from producing an index containerd refuses
# to run after `kind load`.
kclx-image tag="function-kclx-runtime:dev":
    docker build --provenance=false -t {{ tag }} rust

# Install the Rust composition function into the Kind cluster: runtime image
# side-loaded onto the nodes, and the (metadata-only) package pushed to the
# local registry, from where Crossplane fetches it as
# 172.18.0.100:80/function-kclx:v0.1.0 — see manifests/crossplane/functions.yaml
# for why that reference is an RFC1918 IP:port. `devkit cluster deps` applies
# the Function object itself (wave 2).
kclx-install version="v0.1.0": kclx-image registry
    #!/usr/bin/env bash
    set -euo pipefail
    kind load docker-image --name {{ cluster }} function-kclx-runtime:dev
    mkdir -p tmp/xpkg && rm -f tmp/xpkg/function-kclx.xpkg
    crossplane xpkg build --package-root=rust/package \
        --package-file=tmp/xpkg/function-kclx.xpkg
    # Pushed through localhost:5001: the CLI reaches the registry on the host,
    # and go-containerregistry speaks plain HTTP to `localhost:`.
    crossplane xpkg push -f tmp/xpkg/function-kclx.xpkg \
        {{ registry_push }}/function-kclx:{{ version }}
    # The pod keeps the image it started with (imagePullPolicy: IfNotPresent on
    # a fixed tag), so a rebuild only reaches Crossplane after a restart. A
    # no-op before wave 2 has ever run.
    kubectl -n crossplane-system delete pod \
        -l pkg.crossplane.io/function=function-kcl --ignore-not-found
    echo "function-kclx {{ version }} installed"

# ─── function-package-registry (Python composition function) ──────────────────
#
# `python/function-package-registry/` is the only Python in this repo: a
# crossplane function-sdk-python function that renders the PackageRegistry XRD
# (packages/cloud/package-registry) onto one of five backends. It ships no KCL
# package, so nx knows nothing about it and these recipes are the whole gate.

# The Python counterpart of `just provider`: pydantic models for every managed
# resource the function composes, generated from the CRDs of the SAME pinned
# provider images the KCL schema packages come from
# (packages/providers/registry.yaml). Extraction mirrors nx-kcl's import-crd
# generator — `docker create` + `docker export` + yq — so the two toolchains
# can never read different CRDs for the same tag.
#
# The models inherit function/models/base.py's `extra="forbid"`, which is why
# they exist: a field typo is then a ValidationError in `just pkgreg-test`
# rather than a key the API server prunes at apply time.
# Regenerate python/function-package-registry/function/models/** (docker + yq).
pkgreg-models:
    #!/usr/bin/env bash
    set -euo pipefail
    root=python/function-package-registry
    out="$root/function/models"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    # image|package dir|group|version|Kind:module[,Kind:module…]
    specs=(
        "ghcr.io/crossplane-contrib/provider-aws-ecr:v2.6.0|aws_ecr|ecr.aws.m.upbound.io|v1beta1|Repository:repository,LifecyclePolicy:lifecycle_policy,RepositoryPolicy:repository_policy"
        "ghcr.io/crossplane-contrib/provider-aws-codeartifact:v2.6.0|aws_codeartifact|codeartifact.aws.m.upbound.io|v1beta1|Domain:domain,Repository:repository"
        "ghcr.io/crossplane-contrib/provider-gcp-artifact:v2.6.0|gcp_artifact|artifact.gcp.m.upbound.io|v1beta1|RegistryRepository:registry_repository,RegistryRepositoryIAMMember:registry_repository_iam_member"
        "ghcr.io/crossplane-contrib/provider-azure-containerregistry:v2.6.0|azure_containerregistry|containerregistry.azure.m.upbound.io|v1beta1|Registry:registry"
        "ghcr.io/crossplane-contrib/provider-helm:v1.3.0|helm|helm.m.crossplane.io|v1beta1|Release:release"
    )
    for spec in "${specs[@]}"; do
        IFS='|' read -r image pkg group version kinds <<< "$spec"
        echo "── $pkg ← $image"
        # The xpkg image carries every CRD in one /package.yaml stream.
        cid=$(docker create "$image")
        docker export "$cid" | tar -xf - -C "$tmp" package.yaml
        docker rm "$cid" >/dev/null
        mv "$tmp/package.yaml" "$tmp/$pkg.yaml"
        mkdir -p "$out/$pkg"
        cat > "$out/$pkg/__init__.py" <<PY
    """Generated models for $group (from $image)."""
    PY
        IFS=',' read -ra entries <<< "$kinds"
        for entry in "${entries[@]}"; do
            kind=${entry%%:*}; module=${entry##*:}
            # One JSON Schema per CRD version: the CRD document itself is not
            # one, but .spec.versions[].schema.openAPIV3Schema is.
            yq -o=json "select(.kind == \"CustomResourceDefinition\" and .spec.group == \"$group\" and .spec.names.kind == \"$kind\") | .spec.versions[] | select(.name == \"$version\") | .schema.openAPIV3Schema" \
                "$tmp/$pkg.yaml" > "$tmp/$module.json"
            [ -s "$tmp/$module.json" ] || { echo "no $group/$version $kind in $image"; exit 1; }
            (cd "$root" && hatch run models:datamodel-codegen \
                --input "$tmp/$module.json" \
                --input-file-type jsonschema \
                --output-model-type pydantic_v2.BaseModel \
                --base-class function.models.base.Resource \
                --class-name "$kind" \
                --enum-field-as-literal all \
                --use-annotated \
                --target-python-version 3.11 \
                --formatters ruff-format \
                --disable-timestamp \
                --custom-file-header "# Generated by \`just pkgreg-models\` from $image ($group/$version $kind). Do not edit." \
                --output "function/models/$pkg/$module.py")
            echo "   $group/$version $kind -> $out/$pkg/$module.py"
        done
    done

# Lint + test the Python function: what CI and the pre-push hook run.
pkgreg-test:
    cd python/function-package-registry && hatch fmt --check && hatch test

# The Function it backs needs the annotation
# render.crossplane.io/runtime: Development, which pkgreg-render adds.
# Serve the composition function on :9443 for `crossplane render`.
pkgreg-serve:
    cd python/function-package-registry && hatch run development

#   just pkgreg-render forgejo --include-context
# The nx `render` target is bound to function-kcl and to a KCL `source:` line,
# so it cannot render these Compositions — hence a recipe of its own.
# Render one example against a locally served function (needs `just pkgreg-serve`).
pkgreg-render backend="gcp" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp/pkgreg
    yq '(select(.metadata.name == "function-package-registry") | .metadata.annotations["render.crossplane.io/runtime"]) = "Development"' \
        packages/cloud/package-registry/xrd/functions.yaml > tmp/pkgreg/functions.yaml
    crossplane render \
        packages/cloud/package-registry/xrd/examples/package-registry-{{ backend }}.yaml \
        packages/cloud/package-registry/{{ backend }}/composition.yaml \
        tmp/pkgreg/functions.yaml --include-function-results {{ args }}

# Build the function runtime image. The tag is the one the local cluster's
# DeploymentRuntimeConfig expects (manifests/crossplane/functions.yaml);
# --provenance=false keeps buildx from producing an index containerd refuses
# to run after `kind load`.
pkgreg-image tag="function-package-registry-runtime:dev":
    docker build --provenance=false -t {{ tag }} python/function-package-registry

# Install the Python composition function into the Kind cluster: runtime image
# side-loaded onto the nodes, and the (metadata-only) package pushed to the
# local registry, from where Crossplane fetches it as
# 172.18.0.100:80/function-package-registry:v0.1.0 — see
# manifests/crossplane/functions.yaml for why that reference is an RFC1918
# IP:port. `devkit cluster deps` applies the Function object itself (wave 2).
pkgreg-install version="v0.1.0": pkgreg-image registry
    #!/usr/bin/env bash
    set -euo pipefail
    kind load docker-image --name {{ cluster }} function-package-registry-runtime:dev
    mkdir -p tmp/xpkg && rm -f tmp/xpkg/function-package-registry.xpkg
    crossplane xpkg build --package-root=python/function-package-registry/package \
        --package-file=tmp/xpkg/function-package-registry.xpkg
    # Pushed through localhost:5001: the CLI reaches the registry on the host,
    # and go-containerregistry speaks plain HTTP to `localhost:`.
    crossplane xpkg push -f tmp/xpkg/function-package-registry.xpkg \
        {{ registry_push }}/function-package-registry:{{ version }}
    # The pod keeps the image it started with (imagePullPolicy: IfNotPresent on
    # a fixed tag), so a rebuild only reaches Crossplane after a restart. A
    # no-op before wave 2 has ever run.
    kubectl -n crossplane-system delete pod \
        -l pkg.crossplane.io/function=function-package-registry --ignore-not-found
    echo "function-package-registry {{ version }} installed"

# ─── KclModule operator (kube-rs) ─────────────────────────────────────────────
#
# The same `kclx` binary and the same `kcl_render::Engine`, wearing three more
# hats: a controller that renders a KclModule and applies what it produced, a
# REST API over those modules, and a CLI for them. rust/README.md ("Operator")
# has the reconcile contract.

#   just kclx-operator --namespace default
# Run the controller against the current kubecontext.
kclx-operator *args:
    cargo run --manifest-path rust/Cargo.toml --release -q -p kclx -- operator run {{ args }}

#   just kclx-api --addr 127.0.0.1:8099
# Serve the KclModule REST API against the current kubecontext.
kclx-api *args:
    cargo run --manifest-path rust/Cargo.toml --release -q -p kclx -- api {{ args }}

# The CRD is derived, never hand-edited: `kube-derive` builds it from
# KclModuleSpec, so a field added in Rust and not regenerated here is a schema
# the API server prunes on write.
# Regenerate manifests/kclx-operator/crd.yaml from the Rust types.
kclx-crd:
    cargo run --manifest-path rust/Cargo.toml --release -q -p kclx -- operator crd \
        > manifests/kclx-operator/crd.yaml
    @echo "wrote manifests/kclx-operator/crd.yaml"

# The image is the one the composition function uses; the rollout restart is
# explicit for the same reason as kclx-install (a pod keeps the image it
# started with).
# Install the operator and the REST API into the Kind cluster.
kclx-operator-install: kclx-image
    #!/usr/bin/env bash
    set -euo pipefail
    kind load docker-image --name {{ cluster }} function-kclx-runtime:dev
    kubectl apply -f manifests/kclx-operator/crd.yaml
    kubectl apply -f manifests/kclx-operator/rbac.yaml
    kubectl apply -f manifests/kclx-operator/deployment.yaml
    kubectl -n kclx-system rollout restart deploy/kclx-operator deploy/kclx-api
    kubectl -n kclx-system rollout status deploy/kclx-operator --timeout=120s
    kubectl -n kclx-system rollout status deploy/kclx-api --timeout=120s

# ─── Benchmark: function-kcl vs kclx vs function-python ───────────────────────
#
# The three composition-function runtimes render the SAME Compositions
# (packages/cloud/bucket/aws and packages/platform/appstack/stack) over gRPC
# RunFunction, plus a Python port of the bucket Composition
# (tools/bench/scripts/bucket_aws.py). Latency is measured on the RPC — no
# `crossplane render`, no YAML parsing, no process spawn in the sample — and the
# desired state of every runtime is diffed against upstream function-kcl, so a
# behavioural divergence fails the run rather than hiding behind a fast number.

#   just bench --iterations 50 --only kcl,kclx --scenario bucket-aws
# Benchmark the runtimes; writes tools/bench/out/{results.json,report.html}.
bench *args: kclx-image
    node tools/bench/src/main.ts {{ args }}

# Screenshots it to tools/bench/out/report.png as the visual artefact.
# Assert the benchmark report's tables against the measured data in Chromium.
bench-verify *args:
    node tools/bench/src/verify.ts {{ args }}

# Time `bun`, `pnpm`, and `nub` installing this repo's tree (cold store / warm
# store / no-op) with hyperfine in throwaway sandboxes; writes tools/bench/out/pm.md.
#   just bench-pm            RUNS=10 PMS="pnpm nub" just bench-pm
bench-pm:
    tools/bench-pm.sh

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

registry_host := "kind-registry" # in-cluster name (docker `kind` network), port 80
registry_push := "localhost:5001" # host-side address for `kcl mod push`
# Pinned address of that same container on the docker `kind` network. Crossplane
# fetches the function package from here, and it has to be an RFC1918 IP:port:
# go-containerregistry only speaks plain HTTP to RFC1918 / *.localhost / loopback
# hosts, and the CEL rule on `spec.package` insists on a dot in the authority,
# which rejects both `localhost:5001` and `kind-registry:80`.
registry_ip := "172.18.0.100"
cluster := "kcl-e2e" # keep in step with devkit.toml [cluster] name

# Full flow: cluster, crossplane, registry, publish, install, providers, examples.
# Providers must land before the XRs: the composed managed resources are
# instances of CRDs the providers install, and Crossplane cannot even
# rest-map them until then.
e2e module="bucket": e2e-up (e2e-publish module) (e2e-install module) (e2e-providers module) (e2e-providerconfigs module) (e2e-apply module)
    @just e2e-status

#   just e2e-kclx
# The same end-to-end run, but composed by OUR function: the Rust `kclx`
# binary, installed as the `function-kcl` Function every Composition
# references. devkit owns the cluster and everything applied to it (charts,
# functions, XRD, providers, Compositions, example composites — devkit.toml
# waves 0-5); this recipe owns the builds devkit cannot do.
#
# Fixed to the `bucket` module, because that is the module devkit.toml declares
# rows for. Add rows there to cover another one.
e2e-kclx: kclx-test
    #!/usr/bin/env bash
    set -euo pipefail
    just registry                 # registry up (the kind network may not exist yet)
    devkit cluster create
    just registry                 # now pin it on the network kind just created
    just kclx-install             # image -> nodes, package -> registry
    just e2e-publish bucket       # the KCL packages the Compositions pull
    # Waves 2-5 apply the Crossplane stack and the example composites. Manifest
    # rows do not wait, so the last wave can lose a race with the composite CRD
    # the XRD creates; deps is idempotent, so just run it again.
    devkit cluster deps || devkit cluster deps
    just e2e-status

#   just component-push app1 v1
# kustomize-controller synthesises a kustomization.yaml when the artifact has
# none, so a bare manifest stream is enough. Pushed via {{ registry_push }}
# (host side); the cluster pulls the same blob from {{ registry_ip }}:80, which
# is why the example XR sets `insecure: true`.
# Render an app values file and push it to the local registry as a Flux artifact.
component-push name="app1" tag="v1": registry
    #!/usr/bin/env bash
    set -euo pipefail
    dir="tmp/components/{{ name }}"
    mkdir -p "$dir"
    kcl run packages/app -D values=manifests/apps/{{ name }}.yaml > "$dir/manifests.yaml"
    flux push artifact oci://{{ registry_push }}/components/{{ name }}:{{ tag }} \
        --path="$dir" --source=kcl-packages --revision={{ tag }}

#   just e2e-component
# The kclx cluster (Flux comes up in devkit wave 0), the `component` module's
# Crossplane layer (waves 2-5), and the artifact its example XR pulls. Adding a
# component after this is one `kubectl apply` of a Component XR — no Composition
# change, no devkit row.
# Dynamic components end-to-end on a real cluster.
e2e-component: e2e-kclx component-push
    #!/usr/bin/env bash
    set -euo pipefail
    just e2e-publish component     # the KCL package the Composition pulls
    # Waves 2-5 again, now that component-flux is in the registry.
    devkit cluster deps || devkit cluster deps
    kubectl -n default wait --for=condition=Ready component/app1 --timeout=5m
    kubectl -n default get component,ocirepository,kustomization,helmrelease

# Kind cluster (devkit) + local registry + cluster deps (Crossplane, pinned in
# devkit.toml [[deps]]) + function runtime config.
e2e-up: registry
    devkit cluster create
    devkit cluster deps
    nx run-many -t build test lint

# Start the local OCI registry: `kind-registry` (port 80) in-cluster, :5001 on
# the host, pinned at {{ registry_ip }} on the docker `kind` network.
registry:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "$(docker ps -q -f name=^{{ registry_host }}$)" ]; then
        docker rm -f {{ registry_host }} >/dev/null 2>&1 || true
        docker run -d --restart=always --name {{ registry_host }} \
            -e REGISTRY_HTTP_ADDR=0.0.0.0:80 -p 127.0.0.1:5001:80 registry:2 >/dev/null
    fi
    # The `kind` network only exists once `kind` has created it, and an address
    # can only be pinned at connect time — so reconnect if it is on the network
    # with some other address.
    if docker network inspect kind >/dev/null 2>&1; then
        ip=$(docker inspect {{ registry_host }} \
            -f '{{{{ (index .NetworkSettings.Networks "kind").IPAddress }}}}' 2>/dev/null || true)
        if [ "$ip" != "{{ registry_ip }}" ]; then
            docker network disconnect kind {{ registry_host }} 2>/dev/null || true
            docker network connect --ip {{ registry_ip }} kind {{ registry_host }}
        fi
    fi
    curl -fsS http://{{ registry_push }}/v2/_catalog >/dev/null && echo "registry ok"

# The vendored provider schemas still `import k8s`, so the function pod resolves
# `k8s = "1.32.4"` at render time. Mirroring it locally (and pointing KPM_REG /
# KPM_REPO at the mirror, see install-functions) keeps the run hermetic — and
# dodges ghcr.io's anonymous-token exchange, which breaks under
# OCI_REG_PLAIN_HTTP=on.
# Mirror the `k8s` schema package into the local registry.
registry-seed-k8s:
    #!/usr/bin/env bash
    set -euo pipefail
    src=$(ls -d ~/.kcl/kpm/k8s_1.32.4 2>/dev/null || true)
    if [ -z "$src" ]; then kcl mod pull oci://ghcr.io/kcl-lang/k8s --tag 1.32.4; src=~/.kcl/kpm/k8s_1.32.4; fi
    tmp=$(mktemp -d) && cp -R "$src"/. "$tmp/" && (cd "$tmp" && kcl mod push --force oci://{{ registry_push }}/kcl-lang/k8s) && rm -rf "$tmp"

# Publish one module's packages to the local registry.
# `--projects` takes a name glob, so no project-list plumbing is needed (and
# `nx show projects --json` prefixes a Node deprecation warning that breaks
# `jq`, while `grep` closing the pipe early makes nx die on EPIPE). The glob has
# no dash: a wrapper module is one package named after the module itself
# (`appstack`), a cloud module is one package per backend (`network-gcp`).
e2e-publish module="bucket": registry-seed-k8s
    KCL_REGISTRY={{ registry_push }} {{ nx }} run-many -t nx-release-publish \
        --projects='{{ module }}*' --skip-nx-cache

# Publish every publishable package (all modules) to the local registry.
publish-all: registry-seed-k8s
    KCL_REGISTRY={{ registry_push }} {{ nx }} run-many -t nx-release-publish \
        --projects=tag:lang:kcl --exclude=tag:area:providers --skip-nx-cache

# Functions + XRD + Compositions for one module, repointed at the local registry.
e2e-install module="bucket": install-functions (install-module module)

# Every module ships the same two Function objects, so applying them all is one
# no-op-after-the-first pass rather than a per-module decision.
# The two functions every Composition runs, plus the runtime config that lets
# function-kcl pull Composition packages from the plain-HTTP local registry.
install-functions:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in packages/*/*/xrd/functions.yaml; do cat "$f"; echo "---"; done | kubectl apply -f -
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

# One module's XRD and Compositions, repointed at the local registry.
install-module module:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(just module-dir {{ module }})
    kubectl apply -f "$dir/xrd/xrd.yaml"
    for f in "$dir"/*/composition.yaml; do
        sed 's#oci://docker.io/yurikrupnik/#oci://{{ registry_host }}/#' "$f"; echo "---"
    done | kubectl apply -f -

# Every module's XRDs and Compositions.
install-all: install-functions
    #!/usr/bin/env bash
    set -euo pipefail
    for d in packages/*/*/xrd; do
        m=$(basename "$(dirname "$d")")
        echo "── $m ─────────────────────────────────────────────────────"
        just install-module "$m"
    done

# Install the Crossplane providers the module's Compositions render against. A
# wrapper module ships none: it composes other XRs, so what needs providers is
# the modules it wraps (`just e2e-providers network`, …).
e2e-providers module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    f="$(just module-dir {{ module }})/xrd/providers.yaml"
    if [ ! -f "$f" ]; then echo "no providers for {{ module }}"; exit 0; fi
    kubectl apply -f "$f"
    kubectl wait --for=condition=Healthy provider.pkg.crossplane.io --all --timeout=900s

# Apply the module's ProviderConfigs, if it ships any. Separate from
# e2e-providers because these are instances of CRDs those providers install,
# so they cannot be applied in the same pass.
e2e-providerconfigs module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    f="$(just module-dir {{ module }})/xrd/providerconfigs.yaml"
    [ -f "$f" ] && kubectl apply -f "$f" || echo "no providerconfigs for {{ module }}"

# Apply every example XR for the module.
e2e-apply module="bucket":
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl apply -f "$(just module-dir {{ module }})/xrd/examples/"

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
    -docker rm -f {{ registry_host }}

# ─── End-to-end: the manager package on a Flux-owned cluster ──────────────────
#
#   just e2e-manager            # a manager cluster: crossplane + the apps' operators
#   just e2e-manager workload   # a workload cluster: the apps' operators only
#
# Its own Kind cluster (`kcl-manager`), because the e2e cluster's devkit.toml
# installs crossplane / chaos-mesh / cert-manager by helm CLI and the manager
# render must be their only owner. manifests/manager/devkit.toml shadows the
# root file when devkit runs from that directory (docs/devkit.md, "Shadow it
# with a nearer devkit.toml"): a smaller cluster, and Flux as the only dep.
#
# The render is applied twice, as the package documents: the issuers and the
# chaos objects are instances of CRDs the cert-manager and chaos-mesh charts
# install, so the first pass takes only what Flux understands, and the second
# pass lands once helm-controller reports every HelmRelease Ready.
manager_values := "packages/manager/examples/values.yaml"
manager_cluster := "kcl-manager" # keep in step with manifests/manager/devkit.toml

# Cluster, Flux, the manager render for one cluster role, and the checks.
e2e-manager role="manager": e2e-manager-up (e2e-manager-apply role) (e2e-manager-check role)
    @just e2e-manager-status

# Kind cluster + Flux, from manifests/manager/devkit.toml.
e2e-manager-up:
    cd manifests/manager && devkit cluster create && devkit cluster deps

# Apply the render for a role: `manager` is the base values, `workload` is the
# <stem>.workload.yaml overlay beside it.
e2e-manager-apply role="manager":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ role }}" in manager) env="" ;; workload) env="workload" ;; *) echo "role must be manager or workload, got '{{ role }}'" >&2; exit 2 ;; esac
    kubectl config use-context kind-{{ manager_cluster }} >/dev/null
    # Pass 1: Namespaces + the Flux objects only.
    just manager {{ manager_values }} "$env" \
        | yq 'select(.kind == "Namespace" or .kind == "HelmRepository" or .kind == "HelmRelease")' \
        | kubectl apply -f -
    kubectl -n flux-system wait helmrelease --all --for=condition=Ready --timeout=20m
    # Pass 2: everything; the CRDs are there now.
    just manager {{ manager_values }} "$env" | kubectl apply -f -

# What the role change promises: a manager cluster runs crossplane, a workload
# cluster does not, and both run every `application` chart.
e2e-manager-check role="manager":
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    ok()   { echo "  ✓ $1"; }
    bad()  { echo "  ✗ $1"; fail=1; }
    type_of() { kubectl -n flux-system get helmrelease "$1" -o jsonpath='{.metadata.labels.platform\.example\.org/type}' 2>/dev/null || true; }
    echo "── role {{ role }} ─────────────────────────────────────────"
    for hr in cert-manager chaos-mesh keda kube-prometheus-stack; do
        [ "$(type_of $hr)" = application ] && ok "$hr installed, type=application" || bad "$hr missing or not type=application"
    done
    if [ "{{ role }}" = manager ]; then
        [ "$(type_of crossplane)" = manager ] && ok "crossplane installed, type=manager" || bad "crossplane missing or not type=manager"
        kubectl get crd compositeresourcedefinitions.apiextensions.crossplane.io >/dev/null 2>&1 && ok "crossplane CRDs served" || bad "crossplane CRDs absent"
    else
        [ -z "$(type_of crossplane)" ] && ok "crossplane absent" || bad "crossplane installed on a workload cluster"
    fi
    ready=$(kubectl -n flux-system get helmrelease -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -vc '=True' || true)
    [ "$ready" = 0 ] && ok "every HelmRelease Ready" || bad "$ready HelmRelease(s) not Ready"
    # Issuers follow cert-manager (type=application), so both roles get them.
    n=$(kubectl get clusterissuer -l platform.example.org/type=application --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = 4 ] && ok "4 ClusterIssuers, labelled application" || bad "expected 4 ClusterIssuers labelled application, got $n"
    kubectl wait clusterissuer/platform-root --for=condition=Ready --timeout=2m >/dev/null && ok "platform-root (self-signed) Ready" || bad "platform-root not Ready"
    # Chaos objects: instances of chaos-mesh CRDs, applied in pass 2.
    for r in schedule/zerg-random-kill stresschaos/node-memory-pressure networkchaos/zerg-db-loss workflow/game-day workflow/everything-at-once; do
        kubectl -n chaos-mesh get "$r" >/dev/null 2>&1 && ok "$r" || bad "$r missing"
    done
    exit $fail

# HelmReleases, issuers and chaos objects on the manager cluster.
e2e-manager-status:
    #!/usr/bin/env bash
    set -uo pipefail
    kubectl config use-context kind-{{ manager_cluster }} >/dev/null
    echo "── helmreleases ───────────────────────────────────────────"
    kubectl -n flux-system get helmrelease -L platform.example.org/type
    echo "── issuers ────────────────────────────────────────────────"
    kubectl get clusterissuer -L platform.example.org/type
    echo "── chaos ──────────────────────────────────────────────────"
    kubectl -n chaos-mesh get schedule,podchaos,networkchaos,stresschaos,workflow 2>/dev/null || true

# Delete the manager cluster.
e2e-manager-down:
    -devkit cluster delete {{ manager_cluster }}

# ─── CNCF: local developer cluster (kind, k3d or openshift) ───────────────────
#
#   just cncf-e2e [kind|k3d|openshift]  # cluster + Flux + the render + the checks
#   just cncf-dev                       # the Tilt loop: re-render and re-apply on change
#   just cncf-ca                        # export the local CA so the host can trust it
#
# Its own cluster (`kcl-cncf`), never kcl-e2e / kcl-manager: this one binds host
# ports 80/443, and so does the e2e cluster — `just e2e-down` first if it is up.
# kind goes through manifests/cncf/devkit.toml (which shadows the root file when
# devkit runs from that directory, docs/devkit.md); k3d goes through the k3d CLI
# with traefik disabled, plus the same flux2 chart by helm.
#
# openshift goes through OpenShift Local: `crc start`, then the same flux2
# chart by helm with distro.openshift=true (no runAsUser/fsGroup, SCC nonroot).
# Ports 80/443 belong to CRC's own port-forward, not to kind — still one runner
# at a time.
#
# The render is applied twice, as the package documents: the ClusterIssuers and
# the Certificates are instances of CRDs the cert-manager chart installs, so the
# first pass takes only what Flux understands and the second lands once
# helm-controller reports both HelmReleases Ready.
cncf_values := "packages/cncf/examples/values.yaml"
cncf_cluster := "kcl-cncf" # keep in step with manifests/cncf/devkit.toml

# k3d 5.8.3 defaults to k3s v1.31, and the flux2 2.19.0 chart's pre-install
# check refuses anything below 1.33 — pin the same minor kind v0.33 brings.
k3s_image := "rancher/k3s:v1.33.13-k3s1"

# Cluster + Flux, the render, the checks. `runner` is kind, k3d or openshift;
# k3d and openshift use the values.<runner>.yaml overlay.
# `(cncf_values)` is grouped because `ident (` parses as a function call in just.
cncf-e2e runner="kind": (cncf-up runner) (cncf-apply (cncf_values) (if runner == "kind" { "" } else { runner })) (cncf-check (cncf_values) (if runner == "kind" { "" } else { runner }))
    @just cncf-status

# kind: devkit from manifests/cncf (shadows the root devkit.toml). k3d: the CLI,
# traefik off, host 80/443 through the serverlb, then flux2 by helm.
cncf-up runner="kind":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ runner }}" in
        kind) cd manifests/cncf && devkit cluster create && devkit cluster deps ;;
        k3d)
            k3d cluster create {{ cncf_cluster }} --image {{ k3s_image }} -p "80:80@loadbalancer" -p "443:443@loadbalancer" --k3s-arg "--disable=traefik@server:*" --wait
            kubectl config use-context k3d-{{ cncf_cluster }} >/dev/null
            # `--repo <url>` makes helm walk every configured repository's index
            # cache first, so one stale entry in ~/.config/helm fails the install;
            # add the repo by name instead, the way devkit does for kind.
            helm repo add flux2 https://fluxcd-community.github.io/helm-charts --force-update >/dev/null
            helm repo update flux2 >/dev/null
            helm upgrade --install flux2 flux2/flux2 --version 2.19.0 \
                -n flux-system --create-namespace --wait --timeout 10m \
                --set imageAutomationController.create=false --set imageReflectionController.create=false --set notificationController.create=false
            ;;
        openshift)
            # Needs `crc setup` once and a pull secret (`crc config set pull-secret-file <path>`).
            # `crc start` is a no-op on a running instance.
            crc start
            kubectl config use-context crc-admin >/dev/null
            helm repo add flux2 https://fluxcd-community.github.io/helm-charts --force-update >/dev/null
            helm repo update flux2 >/dev/null
            # distro.openshift drops the controllers' runAsUser 65534 / pod
            # fsGroup 1337 (rejected by restricted-v2) and grants SCC nonroot.
            helm upgrade --install flux2 flux2/flux2 --version 2.19.0 \
                -n flux-system --create-namespace --wait --timeout 10m \
                --set distro.openshift=true \
                --set imageAutomationController.create=false --set imageReflectionController.create=false --set notificationController.create=false
            ;;
        *) echo "runner must be kind, k3d or openshift, got '{{ runner }}'" >&2; exit 2 ;;
    esac

# Two passes, like e2e-manager-apply: the Flux objects, wait for every
# HelmRelease, then everything (the issuers and certificates need the
# cert-manager CRDs).
cncf-apply values=cncf_values env="":
    #!/usr/bin/env bash
    set -euo pipefail
    just cncf-context
    just cncf {{ values }} {{ env }} | yq 'select(.kind == "HelmRepository" or .kind == "HelmRelease")' | kubectl apply -f -
    kubectl -n flux-system wait helmrelease --all --for=condition=Ready --timeout=20m
    # Pass 2 also applies the openshift IngressController partial; kubectl warns
    # that the pre-existing singleton has no last-applied-configuration
    # annotation, which is expected — client-side apply patches only our fields.
    just cncf {{ values }} {{ env }} | kubectl apply -f -
    # openshift: the router's default certificate is now our wildcard; make the
    # cluster trust the CA that signed it (RH docs, "Replacing the default
    # ingress certificate"): CA → ConfigMap in openshift-config → proxy/cluster
    # trustedCA. The CA bytes only exist once cert-manager issued them, hence not
    # in the render. Nodes may flap NotReady while kubelet/CRI-O restart.
    render=$(just cncf {{ values }} {{ env }})
    if [ -n "$(echo "$render" | yq -N 'select(.kind == "IngressController") | .metadata.name')" ]; then
        ca=$(echo "$render" | yq 'select(.kind == "Certificate" and .spec.isCA == true) | .metadata.namespace + "/" + .metadata.name')
        kubectl -n ${ca%/*} wait certificate/${ca#*/} --for=condition=Ready --timeout=5m
        just cncf-ca {{ values }} {{ env }} >/dev/null
        kubectl -n openshift-config create configmap ${ca#*/} --from-file=ca-bundle.crt=tmp/cncf/ca.crt --dry-run=client -o yaml | kubectl apply -f -
        kubectl patch proxy/cluster --type=merge -p "{\"spec\":{\"trustedCA\":{\"name\":\"${ca#*/}\"}}}"
        kubectl wait node --all --for=condition=Ready --timeout=10m
    fi

# Refuse to touch anything but the cncf cluster (kind, k3d or CRC context).
cncf-context:
    #!/usr/bin/env bash
    ctx=$(kubectl config current-context 2>/dev/null || true)
    case "$ctx" in kind-{{ cncf_cluster }}|k3d-{{ cncf_cluster }}|crc-admin) ;; *) echo "current context '$ctx' is not kind-{{ cncf_cluster }} / k3d-{{ cncf_cluster }} / crc-admin; run 'just cncf-up [kind|k3d|openshift]' first" >&2; exit 2 ;; esac

# Export the local CA (the self-signed certificate in the CA secret) so the host
# can trust every dev certificate below it.
cncf-ca values=cncf_values env="":
    #!/usr/bin/env bash
    set -euo pipefail
    just cncf-context
    ref=$(just cncf {{ values }} {{ env }} | yq 'select(.kind == "Certificate" and .spec.isCA == true) | .metadata.namespace + " " + .spec.secretName')
    mkdir -p tmp/cncf
    kubectl -n ${ref% *} get secret ${ref#* } -o jsonpath='{.data.tls\.crt}' | base64 -d > tmp/cncf/ca.crt
    echo "CA written to tmp/cncf/ca.crt"
    echo "trust it on macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain tmp/cncf/ca.crt"

# What the package promises: both charts Ready, the CA chain Ready, and the
# ingress (ingress-nginx, or the OpenShift router) serving the wildcard for the
# dev domain.
cncf-check values=cncf_values env="":
    #!/usr/bin/env bash
    set -euo pipefail
    just cncf-context
    fail=0; ok() { echo "  ✓ $1"; }; bad() { echo "  ✗ $1"; fail=1; }
    render=$(just cncf {{ values }} {{ env }})
    domain=$(echo "$render" | yq 'select(.kind == "Certificate" and .metadata.name == "wildcard") | .spec.dnsNames[1]')
    ingress_ns=$(echo "$render" | yq 'select(.kind == "Certificate" and .metadata.name == "wildcard") | .metadata.namespace')
    ca=$(echo "$render" | yq 'select(.kind == "Certificate" and .spec.isCA == true) | .metadata.namespace + "/" + .metadata.name')
    for hr in $(echo "$render" | yq -N 'select(.kind == "HelmRelease") | .metadata.name'); do
        [ "$(kubectl -n flux-system get helmrelease $hr -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] && ok "$hr Ready" || bad "$hr not Ready"
    done
    # -N: a multi-document selection would otherwise interleave `---` separators.
    for ci in $(echo "$render" | yq -N 'select(.kind == "ClusterIssuer") | .metadata.name'); do
        kubectl wait clusterissuer/$ci --for=condition=Ready --timeout=2m >/dev/null && ok "clusterissuer $ci Ready" || bad "clusterissuer $ci not Ready"
    done
    kubectl -n ${ca%/*} wait certificate/${ca#*/} --for=condition=Ready --timeout=2m >/dev/null && ok "CA certificate Ready" || bad "CA certificate not Ready"
    kubectl -n $ingress_ns wait certificate/wildcard --for=condition=Ready --timeout=2m >/dev/null && ok "wildcard certificate Ready" || bad "wildcard certificate not Ready"
    if [ -n "$(echo "$render" | yq -N 'select(.kind == "IngressController") | .metadata.name')" ]; then
        [ "$(kubectl -n openshift-ingress-operator get ingresscontroller default -o jsonpath='{.spec.defaultCertificate.name}')" = wildcard-tls ] && ok "router defaultCertificate is wildcard-tls" || bad "router defaultCertificate is not wildcard-tls"
        [ "$(kubectl get proxy/cluster -o jsonpath='{.spec.trustedCA.name}')" = "${ca#*/}" ] && ok "proxy/cluster trusts ${ca#*/}" || bad "proxy/cluster does not trust ${ca#*/}"
        addr=$(crc ip); expect=503; who="the OpenShift router (503: no Route for that host)"
    else
        addr=127.0.0.1; expect=404; who="ingress-nginx (404: default backend)"
    fi
    just cncf-ca {{ values }} {{ env }} >/dev/null
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert tmp/cncf/ca.crt --resolve "hello.$domain:443:$addr" "https://hello.$domain/" || true)
    [ "$code" = $expect ] && ok "https://hello.$domain/ → $expect from $who with a chain the local CA signs" || bad "https://hello.$domain/ → '$code' (expected $expect: $who behind the wildcard cert)"
    exit $fail

# HelmReleases, issuers and certificates on the developer cluster.
cncf-status:
    #!/usr/bin/env bash
    set -uo pipefail
    just cncf-context
    echo "── helmreleases ───────────────────────────────────────────"
    kubectl -n flux-system get helmrelease -L platform.example.org/type
    echo "── issuers ────────────────────────────────────────────────"
    kubectl get clusterissuer
    echo "── certificates ───────────────────────────────────────────"
    kubectl get certificate -A

# The developer loop: Tilt re-renders and re-applies on every change under
# packages/cncf, packages/manager or the values file.
cncf-dev values=cncf_values env="":
    CNCF_VALUES={{ values }} CNCF_ENV={{ env }} tilt up -f manifests/cncf/Tiltfile

# Delete the developer cluster.
cncf-down runner="kind":
    #!/usr/bin/env bash
    case "{{ runner }}" in
        kind) devkit cluster delete {{ cncf_cluster }} ;;
        k3d) k3d cluster delete {{ cncf_cluster }} ;;
        openshift) crc delete -f ;;
        *) echo "runner must be kind, k3d or openshift, got '{{ runner }}'" >&2; exit 2 ;;
    esac

# ─── Release ──────────────────────────────────────────────────────────────────

# The Release workflow refuses to run off main (it versions, tags and pushes
# `HEAD:main`), so preview a release from a feature branch here instead of
# dispatching the workflow at it. `--specifier=patch` matches what the
# workflow forces; without it nx prompts for a bump per project.
# Preview a release: no commit, no tag, no OCI push.
release-dry:
    {{ nx }} release --specifier=patch --dry-run

# Version, changelog, tag, publish (providers excluded via nx.json).
release:
    {{ nx }} release --yes

#   just release-first 0.1.0
# First-ever release when no git tags exist yet.
release-first version:
    {{ nx }} release {{ version }} --first-release --yes

# Publish-only retry: pushes the versions already on disk. Use when versioning,
# changelog and the git tag landed but the OCI push failed (registry/auth).
release-publish:
    {{ nx }} release publish

# ─── Zellij viewpoints ────────────────────────────────────────────────────────
#
#   just zj [ctx]           the workspace for a kube context: one tab per thing
#                           the cluster actually runs (Crossplane, Flux, Argo,
#                           chaos-mesh, KubeBlocks, the kclx operator, metrics),
#                           a viewpoints monitor and a repo shell. The tab set
#                           is derived from `kubectl api-versions`, so the same
#                           command gives a different workspace per cluster.
#   just zj-ls              every viewpoint on this machine: panes, RSS, CPU and
#                           whether it is over budget
#   just zj-ls-all          the same, plus the viewpoints on the hosts in
#                           tools/zellij/hosts.json
#   just zj-advise [name]   the numbers behind a verdict, the host with the most
#                           free capacity, and the command to relocate
#   just zj-move name host  push the script + layout to a host and print (or
#                           take, with --attach) the ssh attach command
#   just zj-layout [ctx]    the generated KDL, for inspection
#
# docs/zellij.md is the long form, including why the CPU numbers are what they
# are (zellij's own server is the biggest line item).

# Open (or attach to) the viewpoint for a kube context.
zj ctx="":
    tools/zellij/zj.sh up {{ ctx }}

# Every viewpoint on this machine, with its cost and a verdict.
zj-ls:
    tools/zellij/zj.sh ls

# The same, plus the viewpoints on every host in the inventory.
zj-ls-all:
    tools/zellij/zj.sh ls --all

# Why a viewpoint is over budget, and where it should go.
zj-advise name="":
    tools/zellij/zj.sh advise {{ name }}

# The remote hosts a viewpoint can be moved to, and their free capacity.
zj-hosts:
    tools/zellij/zj.sh hosts

# Provision a viewpoint on a remote host; --attach takes it now.
zj-move name host *flags:
    tools/zellij/zj.sh move {{ name }} {{ host }} {{ flags }}

# The generated KDL for a context, without touching zellij.
zj-layout ctx="":
    tools/zellij/zj.sh layout {{ ctx }}

zj-clean:
    zellij kill-all-sessions -y
    zellij delete-all-sessions -y
# ─── Inspect ──────────────────────────────────────────────────────────────────

# List all KCL projects.
projects:
    {{ nx }} show projects --projects=tag:lang:kcl

# List the publishable set (everything except providers).
publishable:
    {{ nx }} show projects --projects=tag:lang:kcl --exclude=tag:area:providers
