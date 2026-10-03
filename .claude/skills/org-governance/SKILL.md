---
name: org-governance
description: Org-level tenancy on this platform — the Entitlement record that sells free/team/enterprise, the gate Compositions call, every cost-bearing knob (FinOps) and every security control (SecOps) that actually exists, where an external IdP such as Keycloak attaches, and what a self-managed multi-machine cluster does and does not get. Use when changing plans, quotas, tenant onboarding, cost defaults, security posture, or the on-prem/self-managed path.
when_to_use: Triggered by tenant, namespace onboarding, plan, entitlement, quota, billing, FinOps, cost, tags/cost-center, SecOps, PSA, RBAC, SSO/Keycloak/IdP, or questions about self-managed / on-prem / fault-tolerant clusters.
paths:
  - packages/platform/entitlement/**
  - packages/cloud/forge/**
  - packages/cloud/repository/**
  - packages/cloud/cluster/onprem/**
  - psa/**
---

# Org-level governance: plans, cost, security

One tenant = **one Kubernetes namespace** = one cluster-scoped `Entitlement` record named after that namespace. That record is the only org-level control surface in the repo. Everything below either reads it or is documented here as not reading it.

## A. The record and the gate

| Piece | Path |
| --- | --- |
| API | `packages/platform/entitlement/crd.yaml` — `entitlements.platform.example.org`, **plain CRD, Cluster-scoped**, `spec.plan` enum `free\|team\|enterprise` default `free` (`:44-47`), `spec.features[]` (`:54-57`), `spec.quota` `additionalProperties: integer` (`:64-67`), `spec.reference` opaque billing handle (`:72-74`) |
| Gate | `packages/platform/entitlement/lib.k` — `request()` (`:104-115`), `resolve()` (`:122-147`), `at_least()` (`:151-154`), `within_quota()` (`:158-162`), `plan_rank = {free 0, team 1, enterprise 2}` (`:76`) |
| RBAC | `packages/platform/entitlement/rbac.yaml` — ClusterRole `entitlement:aggregate-to-crossplane`, `get/list/watch` only, labelled `rbac.crossplane.io/aggregate-to-crossplane` |
| Authoring | `schema Record` + `known_features = ["forgejo", "repository"]` (`lib.k:169-203`), entry `main.k`, recipe `just entitlements [values.yaml]` (`justfile:99-100`) — **renders only, never applies** |
| Examples / render mocks | `packages/platform/entitlement/examples/tenant-a.yaml`; per-capability copies at `packages/cloud/{forge,repository}/xrd/required-resources/entitlement.yaml`, mounted by `tools/nx-kcl/src/render/render-executor.ts:229-241` |
| Cluster bootstrap | `devkit.toml:288-301` — CRD + RBAC in wave 1, example records in wave 2 |

Why it is shaped this way, and what breaks if you change it:

- **Cluster-scoped, not namespaced** (`crd.yaml:8-11`): a namespaced record would live in the namespace it grants, so anyone with edit rights there could upgrade their own plan.
- **`features[]` is the sole authority; `plan` grants nothing** (`crd.yaml:48-53`, `lib.k:71-75`). Adding a capability to a plan can never retroactively entitle a tenant who did not buy it. `plan` only feeds `at_least()`, and an unranked/typo'd plan scores `-1`, below every floor.
- **Tri-state `resolve()`** (`lib.k:31-38`): `pending` (Crossplane has not fetched yet — emit only the request, compose nothing, do **not** assert), `denied` (fatal assert → `SEVERITY_FATAL`, zero resources), `ready` (compose). Failing closed is the point: an unentitled tenant gets a named error, never a half-provisioned instance.
- **Emit `request()` on every iteration, not just the first** (`lib.k:100-103`): Crossplane compares the whole requirements message between iterations; dropping it flips requirements back and forth forever.
- **Crossplane core performs the fetch, not the function** — hence the aggregated ClusterRole. Without `rbac.yaml`, every gated Composition errors instead of composing.
- **Wiring requirements**: function-kcl `>= v0.12` (pinned `v0.12.2`) and `input.spec.target: Default` on the Composition pipeline step (`packages/cloud/forge/forgejo/composition.yaml:20-26`). v0.11.x rejects the `RequiredResources` meta-kind outright.
- **Nothing in this repo creates a record at runtime** (`lib.k:6-7`). Billing writes them; the repo ships a renderer and two examples.

## B. The three plans — sold vs. enforced

Product intent (`free` = shared, `team` = 4 CPU, `enterprise` = custom machines + self-managed dev env) against what the code enforces **today**:

| Plan | Sold as | Enforced today | Where |
| --- | --- | --- | --- |
| `free` | shared, no dedicated compute | `spec.private` on a Repository is refused (default is `true`, so a free tenant's Repository XR fails unless it sets `private: false`); `quota.repositories` fallback cap 1 | `repository.k:81`, `:87` |
| `team` | 4 CPU ceiling | **nothing CPU-related.** Only unlocks `private` repositories | `repository.k:81` |
| `enterprise` | custom machines, self-managed env | `Forge.spec.highAvailability` → `replicaCount: 2` + `ReadWriteMany` volume | `forge.k:97`, `:173-176`, `:189-190` |

Only two feature keys exist (`lib.k:203`) and only two quota keys are consumed: `storageGb` (Forge PVC ceiling, `forge.k:106-108`) and `repositories` (`repository.k:87`).

Three traps in that table:

1. `within_quota()` **asserts and returns the cap; it never trims** (`lib.k:158-162`, `forge.k:103-108`). A request above the cap is a fatal render, and the volume is sized by the *request*, so raising a plan's quota does not grow existing forges.
2. `quota.repositories` has **no cross-XR counting** — `used` is hard-coded `1` (`repository.k:87`), so the check passes for every single XR and only fails at `quota.repositories: 0`. The comment at `:83-86` states the intent; the function sees one XR at a time.
3. Enterprise HA is a *shape*, not a provisioning: `highAvailability` also demands `database.mode: postgres` with an externally existing host (`forge.k:101`, `:128-136`), because chart 17.x bundles no PostgreSQL.

## C. FinOps — the knobs that actually cost money

Every capability declares its cost knobs on the XRD and each backend maps them; fields a backend cannot honour are documented as ignored or fail the render. The defaults are deliberately the cheapest rung.

| Family | Knobs (default) | Cite |
| --- | --- | --- |
| postgres | `memoryGb` 2 → `db.t4g.small`, `storageGb` 20, `highAvailability` false, `replicas` 0, `snapshotRetentionDays` 7 | `postgres/xrd/xrd.yaml:37-132`, ladders `postgres/aws/postgres.k:16-30`, `postgres/azure/postgres.k:18-45` |
| redis | `memoryGb` 1 (min 0.5 → `cache.t4g.micro`), `replicas` 0, `highAvailability` false, `snapshotRetentionDays` **0** | `redis/xrd/xrd.yaml:36-82`, `redis/aws/redis.k:15-29` |
| cluster | `nodeCount` 2, `nodeSize` small (`t3.medium`/`e2-medium`/`Standard_B2s`), `spot` false, `autoscaling` unset | `cluster/xrd/xrd.yaml:37-66` |
| vm | `size` small, `diskGb` 30, `spot` false, `publicIp` false | `vm/xrd/xrd.yaml:35-59` |
| serverless | `cpu` 1, `memoryMb` 512, `minInstances` **0** (scale to zero), `maxInstances` unset, `timeoutSeconds` 60 | `serverless/xrd/xrd.yaml:45-67` |
| registry | `tier` standard, `storageGb` 8 (zot PVC), retention knobs | `registry/xrd/xrd.yaml:40-79` |
| bucket | `storageClass` standard, `versioning` **true**, lifecycle/retention/requesterPays | `bucket/xrd/xrd.yaml:29-129` |
| network | `natGateway` **true** — exactly one NAT + EIP, never per-zone, by explicit cost decision | `network/xrd/xrd.yaml:54-57`, rationale `network/aws/network.k:222-225` |
| queue / email | `retentionDays` 4, `replicas` 1, `persistenceSizeGb` 1 / 10 | `queue/xrd/xrd.yaml:48-84`, `email/xrd/xrd.yaml:70-73` |
| appstack | forwards every numeric knob **only when set**, so the child XRD default stays authoritative | `appstack/stack/appstack.k:98-115` |

Two cross-cutting mechanisms:

- **`deletionPolicy: Orphan`** is the same constant in 45 backend modules — `_orphan_policies = ["Observe","Create","Update","LateInitialize"]`, applied as `_mp = _orphan_policies if deletionPolicy == "Orphan" else Undefined`. Delete (default) sets nothing, letting the provider default `["*"]` apply. Documented non-implementers: `postgres/cnpg`, `serverless/knative` (no MR wrapper), `bucket/azure`, `bucket/rustfs`, `name/*` (not implemented), and the shared openbao transit mount, which is never deleted by an XR (`kms/xrd/xrd.yaml:85`).
- **`tags` reach is partial and that is the cost-allocation hole.** Full coverage: postgres/aws, redis/aws+gcp+valkey, cluster/aws+gcp+azure, serverless/* (azure asserts both MRs, `serverless/azure/serverless_test.k:114-121`), queue/aws+gcp, email/aws, kms/azure. Partial (parent only): dns (records are untaggable on both clouds — `dns/aws/dns.k:51-55`, `dns/gcp/dns.k:57-63`), bucket/aws (companion MRs get none), postgres/gcp + postgres/azure (companion Database/User/Configuration get none), vm/aws (KeyPair) and vm/azure (NIC, PublicIP). None at all: `bucket/azure`, `bucket/rustfs`, `cluster/onprem`, `name/*`, and `packages/app` (fixed label set only, `app/lib.k:387-395`). Examples already use `cost-center` (`bucket/xrd/examples/bucket-aws.yaml:21` and five others) — **nothing validates, defaults or requires that key**.

## D. SecOps — the controls that exist

| Layer | Control | Cite |
| --- | --- | --- |
| Admission | PSA via apiserver config, not namespace labels: `enforce: baseline` (v1.31), `audit`/`warn: restricted`, exempt `kube-system` | `psa/config.yaml:8-16`, wired `kind.yaml:6-8,15-28` |
| Audit | `level: Metadata` for pods/apps/batch, `None` for everything else; node-local file, `maxage 1` | `psa/audit-policy.yaml:4-14`, `kind.yaml:17-18` |
| Workload | `packages/app` renders **restricted-grade** by default: `runAsNonRoot`, `runAsUser 65534`, `seccompProfile RuntimeDefault`, `allowPrivilegeEscalation false`, `drop: [ALL]`, `readOnlyRootFilesystem true` | `app/lib.k:412-415`, `:427-431`, `:685-689`, `:699-704`, defaults `:176-178` |
| Secrets | Every capability references secrets **by name**; no composition writes secret bytes. `.vals.yaml` holds `ref+gcpsecrets://` pointers only; `just secrets-check` is a filename + regex gate on every staged file | `justfile:556-577`, `lefthook.yml:44-48`, ESO render `app/lib.k:832-838` |
| RBAC | Exactly two ClusterRoles ship, both read-only aggregates to Crossplane: `entitlement:aggregate-to-crossplane` and `flux:aggregate-to-crossplane` (`component/xrd/providers.yaml:10-20`). No ClusterRoleBinding anywhere in `packages/**`. `packages/app` renders, only when a Workload/Task sets `serviceAccount:`, a ServiceAccount (token automount off by default, on the SA and the pod) and, per `serviceAccount.rules`, a namespaced Role + RoleBinding bound to that SA alone — never cluster-scoped; `rules` require an explicit `namespace` | `app/lib.k:304-333` (`PolicyRule`, `ServiceAccount`), `app/lib.k:739-763` (`_saPodSpec`, `_saObjects`), checks `app/lib.k:473,517` |
| Blast radius | `Component.spec.serviceAccountName` makes Flux impersonate; without it the controller applies with its own cluster-admin-grade identity | `component/xrd/xrd.yaml:159-161` |
| Supply chain | `?tag=` pin must equal `kcl.mod` `version` (`.claude/hooks/manifest-gate.sh:79-93`); `guard-delivery.sh` denies public publishes and out-of-context cluster mutation; lefthook runs fmt/lint/yaml/mod/secrets/graph/typecheck | — |

Known soft spots, in the code as written: `Workload.volumes` is untyped (`app/lib.k:448`) so a `hostPath` entry would render a non-baseline pod with no `check:` stopping it; `runAsUser` has no check forbidding `0`; a `Workload` without `serviceAccount:` sets no `serviceAccountName` (`app/lib.k:452-453`), so its pods run as the namespace `default` SA; PSA has no per-namespace override anywhere, so every tenant namespace gets the same cluster default.

## E. Where Keycloak attaches

**No identity provider exists in this repo.** The only trace is a commented-out `#keycloak:` line in `.vals.yaml:13`, read by nothing. All OIDC here is *workload* federation (`iam`, `workload-identity`, `kind.k:34-53` service-account issuer) — never human authentication. There is no ClusterRoleBinding to any group or user.

The seam is already defined by the record: **`Entitlement` is written by "whatever owns billing"** (`lib.k:6-7`). An IdP becomes the org layer by owning that write, and the join key is fixed and non-negotiable:

```
Keycloak org/group  →  Kubernetes namespace  →  Entitlement/<namespace>.spec.{plan,features,quota}
                                                                     └ reference = subscription id
```

Three integration levels, in increasing cost:

1. **Keycloak as a delivered chart** — one `manager.Dependency` row (`type: application`) gets a HelmRepository/HelmRelease pair for free; on the dev cluster add it under `dependencies:` in a `cncf` values file and it inherits the wildcard certificate. No new package.
2. **Keycloak as the record writer** — a reconciler (outside this repo, per `lib.k:6-7`) mapping group membership to `Entitlement` objects. Nothing in the gate changes; the CRD is already the contract. Keep it cluster-scoped and keep writes out of tenant namespaces.
3. **Keycloak objects as managed resources** — `crossplane-contrib/provider-keycloak` (v3.0.1) turns realms/clients/groups into MRs. That needs a `packages/providers/registry.yaml` row + `nx-kcl:import-crd` generation first, exactly like every other provider.

Human RBAC (group → ClusterRoleBinding) is a fourth, separate job: nothing in `packages/**` renders bindings today.

## F. Self-managed and the three machines

What `packages/cloud/cluster/onprem` does: **adopts an existing cluster** through a kubeconfig Secret (`cluster.k:1-9`, `:78-93`) and installs flux2 2.19.0, optional flux2-sync 1.15.0 (only once flux2 is observed `deployed`) and crossplane 2.3.4 via provider-helm Releases (`cluster.k:116-156`).

What it refuses, as fatal asserts (`cluster.k:64-74`): `version`, `autoscaling`, `machineType`, `spot`, `network`, `resourceGroup`, and `bootstrap.sync` without flux. `nodeCount` and `nodeSize` are silently ignored (`cluster/xrd/xrd.yaml:41`, `:59`).

**Absent, repo-wide:** bare-metal or physical-machine provisioning (no Metal3/Tinkerbell/CAPI/vSphere/Proxmox; Talos only as the `talosctl gen config` argv `packages/cluster/talos.k` renders), etcd configuration or backup, control-plane replica or availability-zone fields on the `KubernetesCluster` XRD (all four backends), and any quorum / `topologySpreadConstraints` / `podAntiAffinity` model (the only `PodDisruptionBudget` is the opt-in `disruptionBudget:` of an `app` Workload). Matches for `etcd`, `quorum`, `bareMetal` exist only in generated upstream provider schemas that nothing here composes.

So for a three-machine purchase, the division of labour is:

- **Outside the platform:** install the OS and a Kubernetes distribution across the three machines with **all three as control-plane nodes** — etcd needs an odd member count and 3 tolerates exactly one loss. Storage must provide `ReadWriteMany` if any Forge is to run HA (`forge.k:173-176`).
- **Inside the platform:** one `KubernetesCluster` XR with `compositionSelector provider: onprem` and `spec.kubeconfigSecret`, which adopts the cluster and lands Flux + Crossplane on it. Its `status.ready` is "every wanted component deployed" (`cluster.k:157-188`) — it says nothing about node health.
- **Not available yet:** the cluster is fault-tolerant, the *workloads* are not. `packages/app` renders no anti-affinity and no spread constraints (a PDB only when a Workload sets `disruptionBudget:`), so a three-node cluster will happily schedule every replica of a Deployment onto one machine. Fixing that is item 3 below.
- `packages/cluster/kind.k` cannot model this locally: the control-plane list is a single literal `Node`, not a comprehension. `packages/cluster` with `-D runner=k3s -D control_planes=3` (k3d, embedded etcd) or `-D runner=talos -D provisioner=qemu -D control_planes=3` can; `-D runner=talos -D provisioner=metal -D endpoint=<url>` renders the `talosctl gen config` call for the real machines.

## G. Gaps to close, not work around

1. **`team = 4 CPU` is unenforced.** No CPU or memory cap exists anywhere: `Workload.resources` is a free-form dict with `requests.cpu 250m` / `limits.memory 512Mi` and **no CPU limit at all** (`app/lib.k:184`, `:220`); `AppStack.api.cpu` has `minimum: 0.25` and no maximum (`appstack/xrd/xrd.yaml:100-107`); no `ResourceQuota` or `LimitRange` object is authored anywhere. Enforcing it means: add quota keys (`cpu`, `memoryMb` — `spec.quota` is `{str:int}`, so cores as an integer or millicores, decided once and documented in `crd.yaml`), add the feature keys to `known_features` (`lib.k:203`), and call `ent.resolve` + `ent.within_quota` from the module that owns the sizing. **`packages/app` and `packages/platform/appstack` do not import `entitlement` at all** — that import is the actual work, and `appstack/stack/appstack.k:98-115` is where the forwarded numbers pass through.
2. **Per-namespace `ResourceQuota` is the honest enforcement point for "shared vs 4 CPU".** A render-time gate binds one XR; only a namespace quota binds the sum. Nothing renders one today.
3. **Workload fault tolerance.** No `topologySpreadConstraints`, no `podAntiAffinity` in `packages/app`, and its PodDisruptionBudget is opt-in (`disruptionBudget:`), not a default. On a three-node cluster this is the difference between surviving a node loss and not.
4. **`quota.repositories` does not count** (`repository.k:87`). Either count outside the function or drop the pretence.
5. **`storageGb` is undocumented in the CRD.** `packages/platform/entitlement/examples/tenant-a.yaml:28` and both `required-resources/entitlement.yaml` set it, but `crd.yaml:71` lists only `repositories` under "Keys in use".
6. **Cost allocation is advisory.** `tags` is optional everywhere and unreachable on the resources listed in §C. A required `cost-center` would need defaulting at the XRD level plus the missing backend mappings.

## Invariants

1. `metadata.name` of the record **is** the tenant namespace. Crossplane fetches by name (`lib.k:112`); rename it and every gated render in that namespace fails as unentitled.
2. Never assert in the `pending` branch. Guard on `_pending`, or the first iteration kills every render (`lib.k:119-121`).
3. A gated module emits `ent.request(oxr)` unconditionally and the composed resources only `if _gate.ready` (`forge/forgejo/main.k:19-24`).
4. The Composition must set `input.spec.target: Default`, and function-kcl must be `>= v0.12`.
5. `rbac.yaml` stays read-only. Composition must never be able to widen an entitlement.
6. Adding a feature key means extending `known_features`, so a typo in a record is a build failure rather than a tenant who paid and got a fatal render.

## Commands

```bash
just entitlements packages/platform/entitlement/examples/tenant-a.yaml | kubectl apply -f -
kubectl get entitlements                       # PLAN / FEATURES / AGE printer columns
node_modules/.bin/nx run-many -t build test lint --projects=entitlement,forge-forgejo,repository-forgejo
just render forge-forgejo                      # exercises the gated path via xrd/required-resources
kubectl -n <tenant> describe forge <name>      # a denied gate shows as one fatal result naming the plan
```

## Absent — do not assume these exist

Budget objects, cost estimation, showback/chargeback, spend limits, Kubecost/OpenCost/Infracost, cloud billing exports · CPU/memory caps, `ResourceQuota`, `LimitRange` · NetworkPolicy, OPA/Gatekeeper/Kyverno, admission webhooks beyond PSA, cosign/SBOM/provenance (`--provenance=false`, `justfile:657-661`), Falco, audit-log shipping · human SSO, group→role mapping, any IdP integration · bare-metal provisioning, etcd management, control-plane replica or AZ fields, quorum modelling.
