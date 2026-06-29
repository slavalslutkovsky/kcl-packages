# nx-kcl

An [Nx](https://nx.dev) plugin for [KCL](https://kcl-lang.io) packages. It makes
every `kcl.mod` in the workspace a first-class Nx project — with `build`, `test`,
`lint`, dependency management, packaging, and OCI publishing — and wires KCL into
`nx release` so packages are versioned from Conventional Commits and pushed to an
OCI registry.

## How it works

The plugin is a single [inferred-task plugin](https://nx.dev/extending-nx/recipes/project-graph-plugins).
Its `createNodesV2` hook globs `**/kcl.mod` (ignoring `node_modules`) and, for
each one, synthesizes an Nx project:

- **name** — the `name` field from `kcl.mod` (e.g. `cluster`)
- **root** — the directory containing `kcl.mod`
- **projectType** — `library`
- **tags** — `lang:kcl`
- **targets** — `build`, `test`, `lint`, `fmt`, `add`, `remove`, `pkg`, `nx-release-publish`

There is no `project.json` to write and no registration step: drop a `kcl.mod`
anywhere under the workspace and the project appears automatically.

## Prerequisites

- The [KCL CLI](https://kcl-lang.io/docs/user_docs/getting-started/install) (`kcl`) on `PATH`.
- Node.js and Nx (the plugin runs as TypeScript via `@swc-node/register`).

## Setup

Register the plugin in `nx.json`:

```json
{
  "plugins": ["./tools/nx-kcl/src/index.ts"]
}
```

Optionally pass an OCI registry prefix used by the publish executor:

```json
{
  "plugins": [
    {
      "plugin": "./tools/nx-kcl/src/index.ts",
      "options": { "registryPrefix": "oci://ghcr.io/my-org" }
    }
  ]
}
```

> **Resolving `nx-kcl:` generators and executors.** They are referenced by the
> package name `nx-kcl`, which must exist under `node_modules`. This repo lists
> it as a workspace devDependency so every package manager links it:
>
> ```jsonc
> // root package.json
> "devDependencies": { "nx-kcl": "workspace:*" }
> ```
>
> This is required under pnpm and bun (they only link workspace packages that are
> depended on). The workspace itself is defined in `pnpm-workspace.yaml`
> (`packages:` globs) — pnpm ignores the `workspaces` field in `package.json`.

## Project targets

Each KCL package gets these targets:

| Target               | Command                          | Cached | Notes |
| -------------------- | -------------------------------- | :----: | ----- |
| `build`              | `kcl run main.k`                 | yes    | Compiles the entry point. |
| `test`               | `kcl test`                       | yes    | Runs `*_test.k` tests. |
| `lint`               | `kcl lint`                       | yes    | |
| `fmt`                | `kcl fmt`                        | no     | Formats sources in place. |
| `add`               | `kcl mod add <args>`             | no     | Add a dependency (args forwarded). |
| `remove`            | `nx-kcl:remove`                  | no     | Remove a dependency + reconcile the lock. |
| `pkg`               | `kcl mod pkg --target .`         | yes    | Builds a `.tar`; depends on `test`, `lint`. |
| `nx-release-publish` | `nx-kcl:publish`                 | no     | `kcl mod push` to OCI; depends on `test`, `lint`. Run via `nx release`. |

```bash
nx build cluster
nx test cluster
nx run-many -t build test lint        # across all KCL packages
```

## Dependency management

### Add a dependency

The `add` target wraps `kcl mod add`; everything after the target is forwarded:

```bash
nx run cluster:add k8s:1.32.4         # pin a version
nx run cluster:add k8s                # latest
nx run cluster:add helloworld --oci https://ghcr.io/kcl-lang/helloworld --tag 0.1.0
nx run cluster:add konfig --git https://github.com/kcl-lang/konfig --tag v0.4.0
```

This updates `[dependencies]` in `kcl.mod` and writes the resolved checksum to
`kcl.mod.lock`.

### Remove a dependency

```bash
nx run cluster:remove k8s
nx run cluster:remove k8s --dry-run
```

KCL has no `kcl mod remove`, and no `kcl mod` subcommand prunes a dependency that
lingers in `kcl.mod.lock`. The `nx-kcl:remove` executor therefore edits
`[dependencies]` in `kcl.mod`, deletes `kcl.mod.lock`, and runs
`kcl mod metadata --update` to regenerate it from the remaining dependencies
(preserving their checksums). Removing the last dependency also drops the empty
`[dependencies]` section.

## Generators

The repo's root `justfile` wraps these generators for the common flows — run
`just --list`. `just provider <name> <image>` adds a provider schema package,
`just composition <name>` scaffolds an XRD + per-provider Compositions, and
`just check` builds/tests everything except the internal providers. The raw
`nx g nx-kcl:<gen>` commands below are what each recipe runs.

### `package` — scaffold a new KCL package

```bash
nx g nx-kcl:package my-pkg
nx g nx-kcl:package my-pkg --directory=packages
nx g nx-kcl:package my-pkg --dependencies=k8s:1.32.4,helloworld
```

Writes the starter sources (a schema module, a `main.k` entry point, and a
passing `*_test.k` test), then delegates to `kcl mod init` to create `kcl.mod`
and `kcl.mod.lock`, and finally runs `kcl mod add` for each `--dependencies`
entry. Letting the KCL CLI own the manifest means the `edition` is stamped for
the installed toolchain rather than hardcoded. `kcl mod init` never clobbers the
sources. The package is auto-discovered by the plugin — no further wiring.
Hyphenated names get a valid KCL module identifier (e.g. `my-pkg` → `my_pkg`).

| Option           | Default     | Description |
| ---------------- | ----------- | ----------- |
| `name`           | —           | Package name (also the Nx project and OCI image name). Positional. |
| `directory`      | `packages`  | Parent directory for the package. |
| `dependencies`   | `[]`        | Dependencies to add after creation; each is passed to `kcl mod add` (e.g. `k8s:1.32.4`). |

### `search` — discover packages on Artifact Hub

```bash
nx g nx-kcl:search             # list KCL packages by relevance
nx g nx-kcl:search prometheus  # free-text search
nx g nx-kcl:search k8s --limit=50
```

Queries [Artifact Hub](https://artifacthub.io) for published KCL packages
(`kind=20`) and prints each name, version, stars, and publisher, plus the
`kcl mod add` line to use. Packages from the default KCL registry
(`kcl-lang/modules`) are addable by bare name; others link to their source
registry. Writes nothing — discovery only. Requires network access.

| Option    | Default | Description |
| --------- | ------- | ----------- |
| `query`   | —       | Free-text search term (name/description). Positional; omit to list by relevance. |
| `limit`   | `20`    | Maximum number of results. |

### `import-crd` — generate a package from CRDs

Consume up-to-date cloud resources (GCP/AWS/Azure, etc.) by generating KCL
schemas from Crossplane provider CRDs — the Artifact Hub KCL modules for the
clouds are often stale, but the providers ship current CRDs.

```bash
# From a released provider OCI image (recommended — versioned, what the providers ship):
nx g nx-kcl:import-crd gcp-storage \
  --image=ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0

# From a Crossplane provider repo, pinned + filtered by service:
nx g nx-kcl:import-crd gcp-storage \
  --repo=crossplane-contrib/provider-upjet-gcp --ref=main --service=storage

# From local CRD files you already have:
nx g nx-kcl:import-crd my-crds --from=./crds
```

Runs `kcl import -m crd` on each CRD into `<package>/models/`, creates `kcl.mod`
via `kcl mod init`, strips the nested `models/kcl.mod` that `kcl import` emits
(so `models/` stays part of the package), and adds the `k8s` dependency (the
generated schemas import `k8s.apimachinery…`).

- **`--image`** extracts `/package.yaml` from the provider image (`docker create`
  + `docker export | tar`), filters CRDs to `--apiScope` (+ `--service`) with
  `yq`, then imports. Requires `docker` and `yq`. This is the versioned artifact
  the providers actually publish — pin the image tag for reproducibility.
- **`--repo`** downloads only the matching CRDs from the repo at `--ref`.

Provenance is written into the package's `main.k`. Requires `kcl` + network.

| Option      | Default        | Description |
| ----------- | -------------- | ----------- |
| `name`      | —              | Package name. Positional. |
| `directory` | `packages`     | Parent directory for the package. |
| `image`     | —              | Provider OCI image to extract CRDs from. Needs `docker` + `yq`. |
| `repo`      | —              | Crossplane provider GitHub repo (e.g. `crossplane-contrib/provider-upjet-gcp`). |
| `from`      | —              | Local directory/file of CRD YAMLs. |
| `ref`       | `main`         | Git ref/tag for `--repo` — pin a release. |
| `service`   | — (all)        | Comma-separated service/group prefixes, e.g. `storage,compute`. |
| `crdPath`   | `package/crds` | CRD directory within `--repo`. |
| `apiScope`  | `cluster`      | `cluster` (`*.upbound.io`) or `namespaced` (`*.m.upbound.io`). |

### `composition` — Crossplane XRD + per-provider Compositions

Scaffold a single abstract Crossplane resource (one **v2 XRD**) plus one
`function-kcl` **Composition package per cloud**. The runtime resource is created
once and the backend is chosen by a flag — `spec.crossplane.compositionSelector`.

```bash
nx g nx-kcl:composition bucket
nx g nx-kcl:composition bucket --providers=aws,gcp --group=cloud.acme.io
```

Layout produced (e.g. `bucket`, all 4 providers):

```
packages/cloud/bucket/
  xrd/        # shared Bucket XRD (v2, Namespaced) + functions.yaml + example XR
  aws/        # function-kcl module (bucket-aws) + composition.yaml (labels provider=aws)
  gcp/        #   "            (bucket-gcp)                          provider=gcp
  azure/      #   "            (bucket-azure)                        provider=azure
  rustfs/     #   "  S3-compatible: provider-aws S3 + rustfs endpoint
```

- **One abstract API** (`Bucket`), **per-provider Compositions** — each its own
  KCL package, published as its own OCI module (`oci://…/bucket-<provider>`),
  referenced by its `composition.yaml`.
- The runtime **flag** is the Composition selector — Crossplane picks the cloud:
  ```yaml
  spec:
    region: us-central1
    crossplane:
      compositionSelector:
        matchLabels: { provider: gcp }
  ```
- **Typed against the cloud schemas.** If a provider's schema package exists in
  the workspace (created via `nx g nx-kcl:import-crd`, see table below), the
  Composition path-depends on it and its `render` builds the **typed** managed
  resource (schema defaults + type-checking). Otherwise it falls back to an
  untyped dict and tells you which `import-crd` to run. Generate the schema
  packages first to get typed Compositions:
  ```bash
  nx g nx-kcl:import-crd gcp-storage --image=ghcr.io/crossplane-contrib/provider-gcp-storage:v2.6.0 --directory=packages/providers
  nx g nx-kcl:import-crd aws-s3      --image=ghcr.io/crossplane-contrib/provider-aws-s3:<tag>      --directory=packages/providers
  nx g nx-kcl:import-crd azure-storage --image=ghcr.io/crossplane-contrib/provider-azure-storage:<tag> --directory=packages/providers
  nx g nx-kcl:composition bucket    # gcp/aws/azure now typed; rustfs reuses aws-s3
  ```
  Expected schema package per provider: `aws` → `aws-s3`, `gcp` → `gcp-storage`,
  `azure` → `azure-storage`, `rustfs` → `aws-s3`.
- Each provider package's `render` logic is unit-tested (`nx test bucket-<provider>`)
  and `nx build` renders the managed resource locally. Publish the modules with
  `nx release` (`--vendor` to bundle the schema dep), then pin `?tag=` in each
  `composition.yaml`. For production, apply the XRD/Compositions/Functions and
  `crossplane render` against the published modules.

| Option       | Default               | Description |
| ------------ | --------------------- | ----------- |
| `name`       | —                     | Resource name (singular), e.g. `bucket` → XR kind `Bucket`. Positional. |
| `providers`  | `aws,gcp,azure,rustfs`| Backends to scaffold a Composition for. |
| `group`      | `cloud.example.org`   | XRD API group. |
| `version`    | `v1alpha1`            | XRD API version. |
| `directory`  | `packages/cloud`      | Parent dir; tree is `<directory>/<name>/<provider>`. |
| `registry`   | `oci://ghcr.io/your-org` | OCI prefix the Compositions reference for each module. |

## Executors

| Executor          | Purpose |
| ----------------- | ------- |
| `nx-kcl:publish`  | `kcl mod push` a package to an OCI registry. Used by `nx-release-publish`. |
| `nx-kcl:remove`   | Remove a dependency from `kcl.mod` and reconcile `kcl.mod.lock`. Backs the `remove` target. |

The publish target defaults to `oci://$KCL_REGISTRY/<project>`. The registry can
be set per invocation via the executor `registry` option, the plugin
`registryPrefix` option, or the `KCL_REGISTRY` environment variable; `$VARS` in
the registry string are expanded at runtime.

## Releasing & publishing

Releases are driven by [`nx release`](https://nx.dev/features/manage-releases)
configured in `nx.json`:

- **Projects** — published packages are those tagged `lang:kcl` **except**
  provider/schema packages (`!tag:area:providers`), which are internal
  dependencies consumed by relative path (see below). Versioned **independently**.
- **Versioning** — Conventional Commits since each package's last tag
  (`fix:` → patch, `feat:` → minor, `feat!`/`BREAKING CHANGE:` → major). A
  package with no releasable commits is skipped. Commit-to-project attribution
  is by the **files a commit changes**, not the commit scope.
- **Manifest** — `version-actions.ts` reads and writes the version in `kcl.mod`
  (not `package.json`).
- **Tags** — one per released package, pattern `{projectName}@{version}`
  (e.g. `cluster@1.2.0`).
- **Changelog** — per-project `CHANGELOG.md`.
- **Publish** — `nx-release-publish` runs `nx-kcl:publish` → `kcl mod push`,
  using the version from `kcl.mod` as the OCI tag.

```bash
nx release --dry-run                   # preview version bumps + changelog
nx release --yes                       # version, changelog, tag, publish
```

In CI (`.github/workflows`):

- `ci.yml` runs `build`, `test`, `lint` on pull requests and pushes to `main`.
- `release.yml` runs `nx release --yes` on pushes to `main`, logging in to the
  registry first and pushing the version commits and tags back.

### First release

Conventional-commit versioning needs a baseline tag, and a non-conventional
history releases nothing. For the very first release (no tags yet), publish an
explicit version once:

```bash
export KCL_REGISTRY=docker.io/<namespace>
kcl registry login -u <user> -p <token> docker.io
nx release 0.1.0 --first-release --yes      # add --dry-run to preview
```

`release.yml` auto-passes `--first-release` when no tags exist; afterwards plain
`nx release --yes` versions from conventional commits.

### Provider/schema packages are internal

A Composition package (e.g. `bucket-gcp`) imports a schema package (e.g.
`gcp-storage`) by a **version-less local path dependency**:

```toml
[dependencies]
gcp-storage = { path = "../../../providers/gcp-storage" }
```

- **No version pin** — the schema is versioned independently; a pin breaks the
  moment it is bumped (`package 'gcp-storage:0.0.1' not found`). kcl resolves a
  path dep from disk, so `build`/`test`/`lint` and local `crossplane render` /
  `kcl run` work offline with no registry.
- **Not published** — provider/schema packages live under `packages/providers/`
  (tagged `area:providers`) and are excluded from `nx release`. They are an
  internal implementation detail: compositions consume them by relative path and
  are rendered locally, so the schema never needs its own OCI image.

> If you later need a composition pulled remotely by function-kcl
> (`source: oci://…`), the schema must travel with it — kcl cannot vendor a path
> dep, so you would embed the schema into the composition package. Not needed
> for the local-render workflow.

## Layout

```
tools/nx-kcl/
  src/
    index.ts               # exports createNodesV2
    create-nodes.ts        # infers a project per kcl.mod + its targets
    utils.ts               # kcl.mod parse / version / dependency helpers
    generators/
      package/             # `nx g nx-kcl:package`
    remove/                # `nx-kcl:remove` executor
    release/
      version-actions.ts   # nx release version actions for kcl.mod
      publish-executor.ts  # `nx-kcl:publish` executor (kcl mod push)
  generators.json
  executors.json
  package.json
```
