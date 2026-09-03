# devkit and `devkit.toml`

`devkit` is a shared dev/ops engine — a Nushell module living in the dotfiles at
`~/.config/nushell/scripts/devkit/`, with a bash launcher on `PATH` at
`~/.local/bin/devkit` so it runs from any shell. The engine hardcodes no paths,
namespaces, cluster names, or chart versions: every one of those is a *default*
it reads through its config layer, and any repo overrides the subset it cares
about with a `devkit.toml` at its root.

This repo's `devkit.toml` is exactly that override file. It exists for one
reason: the Crossplane end-to-end tests (`just e2e`, `just e2e-kclx`) need a
throwaway Kind cluster with Crossplane on it *and* the whole stack under test —
composition functions, XRDs, providers, Compositions, example composites —
declared once, in dependency order. The app/overlay/database sections devkit
offers for app monorepos are left at their defaults and unused here.

## What this repo actually calls

```
just e2e-up      →  devkit cluster create      # Kind cluster from [cluster]
                    devkit cluster deps        # everything in [[deps]]
just e2e-down    →  devkit cluster delete kcl-e2e
```

`devkit cluster deps` is no longer only helm charts. Waves 0/1 are the platform
charts (the crossplane chart itself among them); waves 2–5 are the Crossplane
stack under test — the composition functions, the XRD, the providers, the
Compositions, and the example composites. Applying wave 5 is what makes
Crossplane call the function and create managed resources, so `devkit cluster
deps` is the single step that turns an empty cluster into a reconciling one.
See [Waves](#waves-the-crossplane-stack-under-test) for the layout, the build
steps it depends on, and its rough edges.

Everything else (`devkit up`, `dev`, `manager`, `secrets`, `setup`) is available
but not wired into the justfile.

## How config is resolved

Two layers, merged once per command:

1. **Built-in defaults** — the `DEFAULTS` record in `config.nu` of the devkit
   module. This is the authoritative list of every key that exists.
2. **The nearest `devkit.toml`** — found by walking up from `$PWD` to the
   filesystem root, taking the first directory that has one.

The merge is `DEFAULTS | merge deep --strategy=overwrite <your file>`:

- **Records (`[cluster]`, `[namespaces]`, `[paths.overlays]`…) deep-merge.**
  Setting `cluster.name` leaves `cluster.workers` at its default.
- **Lists (`[[deps]]`, `[[endpoints]]`, `app_namespaces`, `migration_cmd`)
  replace the default wholesale.** This repo declares one `[[endpoints]]` row,
  so the effective config has exactly one endpoint — the default five are gone,
  not appended to. Same for `[[deps]]`: the list you write is the whole list.

Inspect the result, never guess:

```bash
devkit config              # expanded table of the effective merged config
devkit config --path       # which devkit.toml won discovery
devkit config --data       # raw record (nu) — pipe it

# from bash, to query one value:
nu -c 'use devkit *; devkit config --data | get cluster.name'
nu -c 'use devkit *; devkit config --data | get deps | select name version'
```

`devkit config init [dir] [--force]` scaffolds a fully commented reference
`devkit.toml` from the bundled example. Useful for seeing the shape of a section
you have never set.

## Manual override, from most persistent to most local

### 1. Edit `devkit.toml` (the normal case)

Persistent, committed, applies to everyone. Only write keys that differ from the
defaults — an unset key is not "empty", it falls back.

### 2. Shadow it with a nearer `devkit.toml`

Discovery stops at the **first** `devkit.toml` found walking up from `$PWD`. A
file in a subdirectory therefore wins for commands run from inside it:

```bash
mkdir -p tmp/bigcluster && cat > tmp/bigcluster/devkit.toml <<'EOF'
[cluster]
name = "kcl-e2e-big"
workers = 3
EOF
cd tmp/bigcluster && devkit cluster create
```

**The nearer file replaces the root one — it does not chain onto it.** Only
`DEFAULTS` and the winning file are merged, so anything the root file set
(`[[deps]]`, `[namespaces]`, `ingress = false`) reverts to the built-in default
unless the shadowing file restates it. Copy the root file and edit it rather
than writing a two-line stub, unless reverting is what you want. Keep these
scratch files out of commits — nothing in the repo ignores them for you.

### 3. `--file` on `devkit config`

```bash
devkit config -f /path/to/other/devkit.toml
```

Note the limit: **only `devkit config` takes `-f/--file`.** Every other command
resolves by discovery. Use it to preview a merge, not to drive a run.

### 4. Per-invocation CLI flags

The highest-precedence override, and the right tool for a one-off:

| Command | Flags that override config |
|---|---|
| `devkit cluster create` | `-n/--name` → `cluster.name`, `-w/--workers` → `cluster.workers`, `-d/--db-workers` → `cluster.db_workers`, `-i/--ingress` → `cluster.ingress` |
| `devkit cluster delete <name>` | positional arg → `cluster.name` |
| `devkit up` | `-n/--name`, `-w/--workers`; `--skip-dbs`, `--skip-secrets`, `--skip-tilt`; opt-ins `--istio --core --gitops --observability --flux`; `--dry-run` |
| `devkit down` | `-n/--name`, `--keep-cluster` |
| `devkit secrets fetch` | `-c/--config` → `secrets.config`, `-o/--output` → `secrets.output` |

```bash
devkit cluster create -n scratch -w 3        # one-off, config untouched
devkit cluster delete scratch
```

Two flag gotchas worth knowing:

- `--ingress` is OR'd with the config value (`$ingress or $cfg.cluster.ingress`).
  It can force ingress **on**, never off. The only way to disable it is
  `ingress = false` in config.
- `--workers`/`--db-workers` default to the sentinel `-1`, not `0`. Passing
  `-w 0` is a real, explicit "no workers" and is honoured.
- `devkit up` always calls `cluster create` with `--ingress -d 1`, ignoring your
  `[cluster]` values for those two. `just e2e` avoids `up` for this reason.

## Key reference

Keys this repo sets, and what they drive:

| Key | Value here | Effect |
|---|---|---|
| `app_namespaces` | `["dbs", "monitoring", "external-secrets"]` | Namespaces created on `devkit up`. Empty ⇒ derived from dirs under `paths.apps_dir`. |
| `[namespaces]` | `dbs`, `monitoring`, `external_secrets` | Namespaces the lifecycle commands manage/delete. |
| `cluster.name` | `kcl-e2e` | Dedicated name so `just e2e-down` can never delete another cluster. |
| `cluster.workers` | `3` | Plain workers. Crossplane, its providers and the function pod all schedule here. |
| `cluster.db_workers` | `1` | One tainted database-dedicated worker. |
| `cluster.ingress` | `true` | Passed as `-D ingress=true` to the cluster KCL package, which binds host ports 80/443. Set it to `false` if something already listens there — the flag can only force it on. |
| `cluster.kcl_package` / `kcl_tag` | *(commented out)* | Falls back to `oci://docker.io/yurikrupnik/cluster` @ `0.0.6`. The Kind topology comes from this repo's own `packages/cluster` KCL package, rendered by `kcl run <pkg> --tag <tag>`. Uncomment and bump `kcl_tag` in step with releases of that package. |
| `[[deps]]` waves 0–1 | n8s, web, openbao, crossplane 2.3.4, pgbouncer, openebs, vcluster, external-secrets, kubeblocks(-crds), cert-manager, flagger, chaos-mesh, flux2 | The platform charts, `helm upgrade --install --wait`. `flux2` is here because the `component` module composes Flux objects directly, so its controllers and CRDs must predate wave 2. `chaos-mesh` is the operator behind the `app` package's `chaos:` faults (chaos-daemon pinned to Kind's containerd socket, dashboard off). |
| `[[deps]]` waves 2–5 | `crossplane-functions`, `bucket-xrd`, `bucket-providers`, `bucket-composition-{aws,azure,gcp,rustfs}`, `bucket-examples`, `component-xrd`, `component-providers`, `component-composition-flux`, `component-examples` | The Crossplane stack under test, `kubectl apply --server-side` in dependency order. See [Waves](#waves-the-crossplane-stack-under-test). |
| `secrets.config` / `output` | `.vals.yaml` → `.env` | Inputs to `devkit secrets fetch`. |
| `tilt.enabled` | `true` | Whether `devkit up` starts Tilt (unused by `just e2e`). |
| `[[endpoints]]` | Tilt UI only | Printed after `devkit up`. Replaces the default five. |

Sections that exist in `DEFAULTS` but are left alone here: `paths`, `database`,
`external_secrets`, `flux`, `manager`. Run `devkit config init /tmp/x` and read
the generated file for their shape.

### `[[deps]]` rows

Each row is either a **helm chart**:

```toml
[[deps]]
name = "crossplane"                              # release name; also the helm repo alias
repo = "https://charts.crossplane.io/stable"     # omit to treat `chart` as a full ref (oci://…)
chart = "crossplane"                             # default: name
version = "2.3.4"                                # omit for latest
namespace = "crossplane-system"                  # default: "default"; created with --create-namespace
timeout = "10m"                                  # default: "10m"
values = "manifests/values/crossplane.yaml"      # path or list of paths → helm -f, later files win
```

…or a **raw manifest**:

```toml
[[deps]]
name = "cert-manager-crds"
manifest = "https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml"
```

Ordering is by `wave`, not by file order: rows sharing a wave (default `0`)
install in **parallel**, waves run in ascending order, and a wave starts only
once the previous one has fully succeeded — a failed row aborts the whole
command with every later wave untouched. Put CRDs, operators and anything else
a later row needs into an earlier wave.

Path resolution differs between the two row kinds, and the difference bites:
`values` paths resolve against `$PWD` first, then the directory holding
`devkit.toml` (a missing values file is a hard error, not a warning), while
`manifest` is handed to `kubectl -f` verbatim. **A relative `manifest`
therefore resolves against `$PWD` — run `devkit cluster deps` from the repo
root.** A `manifest` may also be a directory, in which case `kubectl` applies
every file in it. Helm runs `upgrade --install … --wait` and manifests go
through `kubectl apply --server-side`, so the whole command is idempotent:
re-running it after editing a version upgrades in place.

### Waves: the Crossplane stack under test

| wave | rows | why here and not earlier |
|---|---|---|
| 0 | the platform charts + `kubeblocks-crds` | helm runs with `--wait`, so when wave 0 finishes the crossplane deployment is up and the `pkg.crossplane.io` / `apiextensions.crossplane.io` APIs are registered. `flux2` lands here too: the `component` module composes `source.toolkit.fluxcd.io` / `kustomize.toolkit.fluxcd.io` / `helm.toolkit.fluxcd.io` objects, so those CRDs and controllers must already exist |
| 1 | `kubeblocks` | its chart templates `lookup` the CRDs applied in wave 0 |
| 2 | `crossplane-functions`, `bucket-xrd`, `component-xrd` | the composition functions the Compositions run, and the XRDs that define the composite APIs — all instances of wave 0's Crossplane CRDs |
| 3 | `bucket-providers`, `component-providers` | the providers whose CRDs the composed managed resources are instances of; a wave of their own so the (slow) package pulls start before the Compositions and examples land. `component-providers` installs no provider at all — it is the `rbac.crossplane.io/aggregate-to-crossplane` ClusterRole without which Crossplane may not compose Flux kinds |
| 4 | `bucket-composition-{aws,azure,gcp,rustfs}`, `component-composition-flux` | a Composition's `compositeTypeRef` names wave 2's XRD API and its `functionRef` names wave 2's Functions |
| 5 | `bucket-examples`, `component-examples` | the "run" step: each example XR is an instance of the composite CRD Crossplane derives from wave 2's XRD, and applying it is what makes Crossplane call the function and create managed resources. The `component` examples additionally need the OCI artifact they point at — `just component-push` |

Wave 0 is load-bearing in a way the later waves are not: helm's `--wait` is the
only synchronisation in the whole sequence. Waves 2–5 are `kubectl apply
--server-side` and return immediately — see *Rough edges*.

#### What devkit applies, and what `just` has to build first

`devkit cluster deps` only applies. It cannot build an image, side-load one into
Kind, build or push an xpkg, or publish a KCL package, so these artefacts must
already exist by the time it runs:

| artefact | produced by | consumed by |
|---|---|---|
| the `kind-registry` container, joined to the docker `kind` network (`kind-registry:80` in-cluster, `localhost:5001` from the host) | `just registry` | everything below |
| `function-kclx-runtime:dev` in the Kind nodes' image store, and the xpkg at `172.18.0.100:80/function-kclx:v0.1.0` | `just kclx-install` | wave 2, via `manifests/crossplane/functions.yaml` |
| the module's published KCL packages and the mirrored `k8s` schema package | `just e2e-publish bucket` (which runs `registry-seed-k8s` first) | wave 4's Compositions, pulled by the function at render time |
| the OCI artifact a `Component` XR pulls (`172.18.0.100:80/components/app1:v1`) | `just component-push app1 v1` | wave 5's `component-examples`, pulled by the Flux source-controller |

Wave 4 applies the **committed** Composition files, untouched: `spec.source`
still reads `oci://docker.io/yurikrupnik/bucket-gcp?tag=0.1.0`. Nothing rewrites
it on the way in — unlike `just install-module`, which `sed`s the registry host
before applying. The redirection to the local registry happens inside our
function at pull time, driven by `KCLX_SOURCE_REWRITE` on the `function-kclx`
DeploymentRuntimeConfig; `rust/README.md` documents that env var.

#### Rough edges

**Manifest rows do not wait.** `kubectl apply --server-side` returns once the
API server has stored the object, not once anything is ready, and devkit has no
wait or retry of its own. Two consequences:

- Providers stay `Unhealthy` for a minute or two after wave 3 while their
  packages download, and nothing in waves 4-5 blocks on that: the composites
  render, but Crossplane cannot create the composed managed resources until the
  provider CRDs exist. `just e2e-providers bucket` re-applies the same file and
  then blocks on
  `kubectl wait --for=condition=Healthy provider.pkg.crossplane.io --all`.
- Wave 5 can lose the race against wave 2: Crossplane derives the composite CRD
  (`buckets.cloud.example.org`) from the XRD asynchronously, and if it has not
  been established yet `kubectl` rejects the examples as an unknown kind, the
  row fails, and `devkit cluster deps` exits non-zero. Every row is idempotent
  — re-run `devkit cluster deps`, or apply just that row's file with
  `just e2e-apply bucket`.

**One failing row aborts every later wave.** `devkit cluster deps` collects the
failures in a wave, prints them, and exits 1 — so a broken chart in wave 0
means the Crossplane stack in waves 2-5 is never applied at all. Three rows
here needed fixing before the stack could install, and the fixes are worth
knowing because they are the shape of what goes wrong:

| row | symptom | fix in `devkit.toml` |
|---|---|---|
| `n8s` | `chart "n8s" matching 1.24.33 not found` — the chart is `n8n` | renamed the row |
| `web` | no such chart in `community-charts` at all | commented out, with a note |
| `pgbouncer` | the chart's userlist Secret template hard-errors without an admin password | `set = ["config.adminPassword=devkit"]` |
| `openbao` | on the *second* run: a server-side-apply conflict over `caBundle` on the agent injector's webhook, owned by the injector's own controller (field manager `vault-k8s`) | `set = ["injector.enabled=false"]` |

Verify a row before blaming the cluster: `helm search repo <name> --versions`
for existence, `devkit config --data | get deps` for what devkit actually
merged.

**`just install-functions` undoes wave 2.** It applies every module's
`packages/cloud/*/xrd/functions.yaml`, where `function-kcl` is upstream
`ghcr.io/crossplane-contrib/function-kcl:v0.12.2`, and repoints it at the
`function-kcl-local-oci` runtime config. Because wave 2 installs *our* function
under that same name, anything that calls `install-functions` — `just e2e`,
`just up`, `just workload` — switches the rendering engine back to upstream.
That is a choice, not a bug: `just e2e` exercises upstream function-kcl,
`just e2e-kclx` exercises ours. Re-running `devkit cluster deps` switches back.

**Adding another module means adding its rows.** The waves are declared per
module, not derived from the tree, so a second module needs the same four kinds
of row (`just modules` lists what exists, `just backends <module>` its
backends). For `redis`, whose backends are `aws`, `gcp` and `valkey`:

```toml
[[deps]]
name = "redis-xrd"
manifest = "packages/cloud/redis/xrd/xrd.yaml"
wave = 2

[[deps]]
name = "redis-providers"
manifest = "packages/cloud/redis/xrd/providers.yaml"
wave = 3

[[deps]]
name = "redis-composition-valkey"          # one row per backend
manifest = "packages/cloud/redis/valkey/composition.yaml"
wave = 4

[[deps]]
name = "redis-examples"                    # directory: every example XR
manifest = "packages/cloud/redis/xrd/examples/"
wave = 5
```

`crossplane-functions` is repo-wide, so it is not repeated. What has no row at
all is `providerconfigs.yaml`: those are instances of CRDs the providers install,
so they cannot be applied in the same pass as the providers — `redis` ships one
and needs `just e2e-providerconfigs redis` after wave 3 reports Healthy.
`bucket` ships none.

## Recipes

**The whole local-cluster loop, from a clean machine**

`just e2e-kclx` runs exactly this. Spelled out, because in practice you re-run
one step, not all of them:

```bash
just registry               # 1. registry: :80 in docker, :5001 on the host
devkit cluster create       # 2. Kind cluster kcl-e2e from [cluster]
just registry               # 3. again — joins it to the `kind` docker network,
                            #    which exists only once kind has created it
just kclx-install           # 4. function image → Kind nodes, xpkg → registry
just e2e-publish bucket     # 5. `k8s` mirror + the module's KCL packages
devkit cluster deps         # 6. waves 0-5; run from the repo root
just e2e-providers bucket   # 7. optional: wait until providers are Healthy
just e2e-status             # 8. composites, managed resources, render errors
```

Steps 1-3 are idempotent, and so is 6 — 6 is also the step to repeat if wave 5
raced the composite CRD. After a Rust change the loop is `just kclx-test`, then
step 4, then a restart of the function pod in `crossplane-system`: the
DeploymentRuntimeConfig pins `imagePullPolicy: IfNotPresent`, so a running pod
keeps the image it started with even after a fresh `:dev` is side-loaded.
`just e2e-down` deletes the cluster and the registry container.

**Bigger cluster for one e2e run, without touching the file**

```bash
just registry
devkit cluster create -n kcl-e2e -w 5
devkit cluster deps
```

**Add a cluster dependency**

Append a `[[deps]]` row — with a `wave` above every row whose CRDs, webhooks or
controllers it needs — then re-run `devkit cluster deps`; no cluster rebuild
needed. Confirm it landed with `devkit config --data | get deps` before blaming
helm.

**Point the cluster topology at a local KCL package build**

```toml
[cluster]
kcl_package = "oci://localhost:5001/cluster"
kcl_tag = "0.0.7"
```

The value goes straight into `kcl run <kcl_package> --tag <kcl_tag>`, so the URL
must carry **no** tag of its own.

**Check what a change will do before running anything**

```bash
devkit config              # merged view
devkit up --dry-run        # prints the plan without executing
```
