# console

Multi-cloud console over the portable XRDs in [`packages/cloud`](../../packages/cloud):
one single-spa micro frontend per domain, composed by the shluviza-wrokspace
console host (`apps/console-host`) into an aggregate dashboard. Each domain
joins two kinds of source into one row per real resource:

* the Crossplane composites in the current kubecontext, and
* each cloud's own inventory, read through its CLI (`aws`, `gcloud`, `az`),

so a row shows whether Crossplane manages it, whether the cloud confirms it,
and which cloud resources nothing manages yet (import candidates — see
[`packages/cloud/bucket/import`](../../packages/cloud/bucket/import)).

```
 browser ──▶ console-host :4240  (shluviza-wrokspace apps/console-host, single-spa root config)
               │  import map from mfe-registry :8097 (MicroFrontend resources)
               │  /           overview: every module's `widget` parcel
               │  /buckets    @shluviza/bucket application
               │  /buckets/api/*  ──▶ kcl-console :8095 (rust/crates/kcl-console)
               ▼                         ├─ k8s    buckets.cloud.example.org (kube-rs)
             bucket :4201                ├─ aws    aws s3api list-buckets
             (console-bucket,            ├─ gcp    gcloud storage buckets list
              src/mfe.tsx)               └─ azure  az storage account list
```

`bucket` is the micro frontend `@shluviza/bucket`: route `/buckets`, apiBase
`/buckets`. It has no Kubernetes deployment; it runs in local dev only.

## Run

With the workspace host (ports: bucket 4201, kcl-console 8095, mfe-registry
8097, host 4240):

```shell
just console-api      # API on 127.0.0.1:8095, all four sources
just console-dev      # bucket micro frontend :4201, hot reload
# in shluviza-wrokspace: mfe-registry on :8097 and the host on :4240, with a
# MicroFrontend for @shluviza/bucket (dev entry http://localhost:4201/src/mfe.tsx);
# see docs/console-host.md there
open http://localhost:4240/buckets
```

`just console-api --source k8s` limits the sources. A source that is not set
up (no kubeconfig, CLI not on PATH, XRD not installed) is reported as
`unavailable`; one that fails (expired login, timeout) as `error`, with the
CLI's first stderr line. Neither fails the response. The CLIs run with the
caller's own login, so the console lists exactly what that person can see.

The micro frontend also runs alone: `pnpm nx serve console-bucket` →
http://localhost:4201, proxying `/api` to kcl-console.

| project | targets |
| --- | --- |
| `console-bucket` | `serve`, `build`, `preview`, `typecheck`, `test` |
| `kcl-console` (cargo) | `just console-api`; checked by `just kclx-test` |

`build` writes the standalone SPA to `dist/` and the module to
`dist/mfe/entry.js` with hashed chunks in `dist/mfe/assets/`.

## Module contract

`src/mfe.tsx` is an ES module exporting single-spa application lifecycles and
a `widget` parcel (the overview card):

```ts
export function bootstrap(props: AppProps): Promise<void>;
export function mount(props: AppProps): Promise<void>;
export function unmount(props: AppProps): Promise<void>;
export const widget: { bootstrap; mount; unmount }; // props: WidgetProps

interface AppProps { name: string; domElement: HTMLElement; apiBase: string; basePath: string; navigate(to: string): void; addStyles?(css: string): () => void }
type WidgetProps = Omit<AppProps, 'name'>;
```

Both render into the host's `domElement`. API calls go to
`${apiBase}/api/...`. The module hands its Tailwind build to the host's
`addStyles`, which scopes it to the module's containers with CSS `@scope`, and
calls the returned remover when neither the page nor the widget is mounted;
without a host it injects `<style id="mfe-style-@shluviza/bucket">` itself.
Nothing is shared at the framework level, so host and modules deploy and
upgrade independently. The full contract is `docs/console-host.md` in
shluviza-wrokspace.

## Adding a domain

1. `rust/crates/kcl-console`: a source module for the XR (`k8s.rs` pattern)
   and the cloud listings (`cloud.rs`), merged by `model::merge`, under a new
   `/api/<domain>` route.
2. `apps/console/<domain>`: copy `bucket/`, change the port, the module name
   and the style id.
3. Host: a `MicroFrontend` resource for the module in shluviza-wrokspace.
