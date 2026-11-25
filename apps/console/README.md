# console

Multi-cloud console over the portable XRDs in [`packages/cloud`](../../packages/cloud):
one micro frontend per domain, composed by a host into an aggregate dashboard.
Each domain joins two kinds of source into one row per real resource:

* the Crossplane composites in the current kubecontext, and
* each cloud's own inventory, read through its CLI (`aws`, `gcloud`, `az`),

so a row shows whether Crossplane manages it, whether the cloud confirms it,
and which cloud resources nothing manages yet (import candidates — see
[`packages/cloud/bucket/import`](../../packages/cloud/bucket/import)).

```
 browser ──▶ host :4200  (console-host, Module Federation host)
               │  /           overview: every remote's ./Widget
               │  /buckets    bucket remote's ./Page
               │  /api/*  ──▶ kcl-console :8095 (rust/crates/kcl-console)
               ▼                 ├─ k8s    buckets.cloud.example.org (kube-rs)
             bucket :4201        ├─ aws    aws s3api list-buckets
             (console-bucket,    ├─ gcp    gcloud storage buckets list
              remoteEntry.js)    └─ azure  az storage account list
```

## Run

```shell
just console-api      # API on 127.0.0.1:8095, all four sources
just console-dev      # host :4200 + bucket remote :4201, hot reload
open http://localhost:4200
```

`just console-api --source k8s` limits the sources. A source that is not set
up (no kubeconfig, CLI not on PATH, XRD not installed) is reported as
`unavailable`; one that fails (expired login, timeout) as `error`, with the
CLI's first stderr line. Neither fails the response. The CLIs run with the
caller's own login, so the console lists exactly what that person can see.

The remote also runs alone: `pnpm nx serve console-bucket` → http://localhost:4201.

| project | targets |
| --- | --- |
| `console-host` | `serve`, `build`, `preview`, `typecheck` |
| `console-bucket` | `serve`, `build`, `preview`, `typecheck`, `test` |
| `kcl-console` (cargo) | `just console-api`; checked by `just kclx-test` |

## Remote contract

A remote exposes `./Widget` (overview card) and `./Page` (its route). Each
exports one function:

```ts
mount(el: HTMLElement, props: { apiBase?: string; pageHref?: string; navigate?: (to: string) => void }): () => void
```

It renders into the host's element and returns the teardown. Nothing is
shared at the framework level (`shared: {}`), so host and remotes deploy and
upgrade independently; each remote injects its own Tailwind build once
(`<style id="console-remote-<name>">`). Remotes call `/api/...` relative to
the page, so the host's origin (dev proxy, or the ingress in a deployment)
routes every remote's API traffic.

Point the host at a deployed remote at build or dev time:
`VITE_BUCKET_REMOTE=https://…/remoteEntry.js pnpm nx build console-host`.

## Adding a domain

1. `rust/crates/kcl-console`: a source module for the XR (`k8s.rs` pattern)
   and the cloud listings (`cloud.rs`), merged by `model::merge`, under a new
   `/api/<domain>` route.
2. `apps/console/<domain>`: copy `bucket/`, change the federation `name`, the
   port, and the style id.
3. Host: the remote in `vite.config.ts` `remotes`, a `declare module` in
   `src/remotes.d.ts`, an entry in `src/domains.ts`.
