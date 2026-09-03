# kclx — one KCL renderer, two front ends

```
                 ┌──────────────────────────────┐
 kclx render ───▶│  kcl-render                  │
 (CLI, JSON/YAML)│    engine.rs  embedded KCL   │──▶ items
                 │    deps.rs    kcl.mod + OCI  │
 kclx function ─▶│    compose.rs desired state  │──▶ RunFunctionResponse.desired
 (gRPC :9443)    └──────────────────────────────┘
```

`kcl-render` is the only place KCL is executed and the only place rendered
items are turned into Crossplane desired state. The CLI and the composition
function are thin adapters over it, which is what makes
`kclx render --view desired` an honest rehearsal of what the cluster composes
— verified byte-for-byte against `crossplane-contrib/function-kcl` v0.12.2
(see *Parity* below).

The KCL runtime is **embedded** (`kcl-lang`, the KCL Rust SDK): no `kcl`
binary in the image, no process spawn per reconcile, no LLVM (KCL 0.10+ uses a
pure-Rust evaluator).

## CLI

```shell
# A working-tree package, against its example XR
kclx render packages/cloud/apigateway/aws \
  --oxr packages/cloud/apigateway/xrd/examples/apigateway-aws.yaml -n

# A published package, JSON out
kclx render 'oci://docker.io/yurikrupnik/bucket-gcp?tag=0.1.0' \
  --oxr packages/cloud/bucket/xrd/examples/bucket-gcp.yaml -o json

# Query parameters straight into option("params") — values keep their JSON
# types, so this is exactly what an HTTP front end would hand to the engine
kclx render ./mypkg -q 'region=eu-west-1&replicas=3&cors={"allowOrigins":["*"]}'

# What the composition function would return
kclx render ./mypkg --oxr xr.yaml --view desired -o json
```

Sources use the same grammar as a Composition's `spec.source`: a path, inline
KCL, or `oci://<repo>[?tag=<version>]`.

| flag | effect |
| --- | --- |
| `-p/--param k=v`, `--param-json k=<json>`, `-q/--query 'a=1&b=2'`, `--params-file f` | build `option("params")` |
| `--oxr`, `--ocds`, `--ctx` | composition state (`params.oxr`, `params.ocds`, `params.ctx`); `--oxr` also seeds `params.dxr` |
| `-D name=value` | raw KCL top-level argument, wins over everything |
| `--view items\|plan\|desired` | resources (default), the whole KCL plan, or Crossplane desired state |
| `-o yaml\|json` | YAML document stream, or a JSON array |
| `-n`, `-S`, `-O`, `-r`, `--sort-keys`, `--show-hidden`, `--vendor` | the corresponding `kcl run` flags |

## Composition function

`kclx function` implements `apiextensions.fn.proto.v1.FunctionRunnerService`
(port 9443, mTLS from `--tls-certs-dir`, `--insecure` for local runs) via
`function-sdk-rust`.

Its input is deliberately **function-kcl's** `krm.kcl.dev/v1alpha1, KCLInput`
(`spec.source`, `spec.params`, `spec.config`, `spec.target`, `spec.resources`),
and it exposes the same KCL contract, so every package under
`packages/cloud/**` runs unchanged:

```python
_params = option("params")   # oxr, dxr, ocds, dcds, ctx, requiredResources,
                             # extraResources + spec.params
items = [...]                # only the top-level `items` list is composed
```

* `ocds` / `dcds` keep function-kcl's capitalised Go field names —
  `option("params").ocds["managed"]?.Resource?.status?.atProvider`.
* `requiredResources` / `extraResources` are
  `{"<key>": [{"Resource": {...}}]}` — the same Go field name again. A key
  appears only on the call *after* the module asked for it, and a lookup that
  matched nothing comes back as `[]`, so the idiom is
  `_ents = option("params")?.requiredResources?.entitlement` followed by
  `if _ents != Undefined`.
* `metadata.annotations["krm.kcl.dev/composition-resource-name"]` names a
  composed resource (falling back to `metadata.name`) and is stripped from the
  output; `krm.kcl.dev/ready` (`True|False|Unspecified`) forces readiness.
* Under the default target, an item whose GVK equals the composite's
  contributes only its `status` to the XR; other targets: `Resources`,
  `PatchDesired`, `PatchResources`, `XR`.
* Under the default target, an item whose `apiVersion` is
  `meta.krm.kcl.dev/v1alpha1` is not composed at all. `RequiredResources` and
  `ExtraResources` carry a `requirements` map of
  `{apiVersion, kind, name?, namespace?, matchLabels?}` — `name` wins over
  `matchLabels`, and no `namespace` means cluster-scoped — which becomes
  `RunFunctionResponse.requirements`. Crossplane fetches the matches and calls
  the function again, up to five times while the requirements keep changing.

  ```python
  items = [{
      apiVersion = "meta.krm.kcl.dev/v1alpha1"
      kind = "RequiredResources"
      requirements.entitlement = {
          apiVersion = "platform.example.org/v1alpha1"
          kind = "Entitlement"
          name = _params.oxr.spec.team
      }
  }]
  ```

* Render failures come back as a **fatal result** on the XR, not a gRPC error.

Not supported, and rejected with a fatal result rather than silently ignored:
`spec.credentials` (registry pulls are anonymous), `spec.dependencies`
(declare dependencies in the package's own `kcl.mod`), and every other
`meta.krm.kcl.dev/v1alpha1` kind (`CompositeConnectionDetails`, `Conditions`,
`Events`, `Context`), which are rejected by name.

Local development against a real Composition:

```shell
just kclx-serve                          # kclx function --insecure on :9443
# functions.yaml: annotate the Function with
#   render.crossplane.io/runtime: Development
crossplane render xr.yaml composition.yaml functions.yaml
```

Packaging:

```shell
just kclx-image ghcr.io/yurikrupnik/function-kclx-runtime:v0.1.0
crossplane xpkg build --package-root=rust/package \
  --embed-runtime-image=ghcr.io/yurikrupnik/function-kclx-runtime:v0.1.0
crossplane xpkg push ghcr.io/yurikrupnik/function-kclx:v0.1.0
```

## Local cluster

On the Kind cluster, `devkit cluster deps` applies
`manifests/crossplane/functions.yaml` and the rest of the Crossplane stack, and
`just kclx-install` builds what devkit cannot (`docs/devkit.md` has the wave
layout and the full loop; `just e2e-kclx` runs it). Three decisions in that
manifest are each a workaround for something outside this repo.

**Installed under the name `function-kcl`.** A Composition references a
function by name, and every Composition under `packages/cloud/**` says
`functionRef: {name: function-kcl}`. Since `kclx function` accepts the same
`krm.kcl.dev/v1alpha1, KCLInput` input and exposes the same `option("params")`
contract, installing our Function object under that name swaps the rendering
engine for the whole repo without editing a single Composition. Applying
`packages/cloud/<module>/xrd/functions.yaml` over it goes back to upstream
v0.12.2.

**`spec.package` is an RFC1918 `IP:port`** — `172.18.0.100:80/function-kclx:v0.1.0`.
Crossplane 2.3.x/2.4.x has no insecure-registry setting at all, and two
independent rules have to hold at once: `spec.package` is CEL-validated to
require a dot in the registry authority (which rejects both `localhost:5001/…`
and `kind-registry:80/…`), while go-containerregistry, which does the fetch,
only falls back to plain HTTP for hosts it recognises as local — an RFC1918
address, a `*.localhost` name, or loopback. An IP on the docker `kind` network
satisfies both, and `172.18.0.100` is where `just registry` pins the
`kind-registry` container (listening on :80 inside that network, published on
the host as `127.0.0.1:5001`).

**The runtime image is side-loaded, not pulled.** A Function's runtime
Deployment defaults to the same image reference as `spec.package`, but it is
pulled by kubelet/containerd, which know nothing about Crossplane's plain-HTTP
allowance. The `function-kclx` DeploymentRuntimeConfig therefore overrides the
`package-runtime` container's image with `function-kclx-runtime:dev` at
`imagePullPolicy: IfNotPresent`, and `kind load docker-image` puts that tag
directly into the nodes' image store. The xpkg in the registry then only has to
carry `package.yaml`. Two consequences: `spec.packagePullPolicy` must stay at
`IfNotPresent`, because Crossplane copies it onto the runtime container and
`Always` sends kubelet to Docker Hub looking for `function-kclx-runtime:dev`;
and a running pod keeps the image it started with, so a rebuild is
`just kclx-install` (build + `kind load` + push) plus a pod restart.

### Registry configuration

`Registries::from_env()` reads the first two of these; `KCLX_CACHE_DIR` is
clap's `env` fallback for `--cache-dir`. The two registry flags are repeatable
and *add to* whatever the environment already says, so a local run extends the
deployed configuration instead of restating it.

| env var | flag | value |
| --- | --- | --- |
| `KCLX_PLAIN_HTTP_REGISTRIES` | `--plain-http-registry HOST` | comma-separated registry hosts (`host` or `host:port`) to talk to without TLS; every other host stays HTTPS |
| `KCLX_SOURCE_REWRITE` | `--rewrite-source FROM=TO` | comma-separated `from=to` package-reference prefix rewrites |
| `KCLX_CACHE_DIR` | `--cache-dir DIR` | where inline sources and pulled packages land; the image runs as nonroot, so in-cluster this must be a writable path (`/tmp/kclx`) |

Rewrites are what let a *committed* Composition resolve against a locally
published build: the manifest on the cluster still says
`oci://docker.io/yurikrupnik/…`, and the function redirects the pull. They
apply to a top-level `spec.source`, to every `oci://` entry in the package's
`kcl.mod`, and to bare-version entries too — `k8s = "1.32.4"` becomes
`oci://ghcr.io/kcl-lang/k8s` before the rewrites run, exactly as it would under
`kcl run`.

```shell
# oci://docker.io/yurikrupnik/bucket-gcp?tag=0.1.0
#   → oci://172.18.0.100:80/bucket-gcp?tag=0.1.0, fetched over plain HTTP
kclx render 'oci://docker.io/yurikrupnik/bucket-gcp?tag=0.1.0' \
  --rewrite-source docker.io/yurikrupnik=172.18.0.100:80 \
  --plain-http-registry 172.18.0.100:80 \
  --oxr packages/cloud/bucket/xrd/examples/bucket-gcp.yaml

# The env form — verbatim what the function pod's DeploymentRuntimeConfig sets
KCLX_SOURCE_REWRITE=docker.io/yurikrupnik=172.18.0.100:80,ghcr.io/kcl-lang=172.18.0.100:80/kcl-lang,localhost:5001=172.18.0.100:80 \
KCLX_PLAIN_HTTP_REGISTRIES=172.18.0.100:80 \
  kclx render packages/cloud/bucket/gcp
```

The target is the pinned IP rather than the `kind-registry` name for a reason
that costs an hour to rediscover: an OCI reference whose first segment has
neither a dot nor a port is a *Docker Hub namespace*, so `kind-registry/bucket-gcp`
resolves to `index.docker.io/kind-registry/bucket-gcp`. `kind-registry:80` would
be fine — it resolves in-cluster, because CoreDNS forwards to the node and the
node's resolver is docker's embedded DNS — but one address for both the package
fetch and `spec.package` is fewer moving parts.

Matching is on whole path segments, longest prefix first, and the `oci://`
scheme is preserved whether or not either side of the pair carries it: with
`docker.io/yuri=x` nothing rewrites `docker.io/yurikrupnik/bucket-gcp`, and with
both `docker.io=mirror` and
`docker.io/yurikrupnik/bucket-gcp=172.18.0.100:80/bucket-gcp-dev` declared, the
longer pair wins for that one package while everything else on `docker.io` goes
to `mirror`. The other two rewrites in the cluster's environment carry the same
kind of weight: `ghcr.io/kcl-lang=…` points `import k8s` at the mirror
`just registry-seed-k8s` pushes, and `localhost:5001=…` fixes up packages whose
recorded dependencies name the registry as `just e2e-publish` saw it, from the
host.

## Parity

`crossplane render` output was compared step for step against
`ghcr.io/crossplane-contrib/function-kcl:v0.12.2` for the `apigateway-aws`
Composition — identical with no observed state, identical with observed
composed resources (`status.atProvider` → XR status via `ocds`), and identical
for an `oci://` source.

## Notes

* Renders are serialised inside `Engine`: the KCL runner swaps the
  process-global panic hook around `catch_unwind`, which is not thread safe. A
  render is a few milliseconds, so a mutex is not the bottleneck.
* `Cargo.lock` is committed and the image builds with `--locked`: `kcl-lang`
  depends on `kcl-lang/kcl` by branch, so an unlocked build follows upstream
  `main`.
* Dependency resolution (`kcl.mod` `[dependencies]`, including `oci://` and
  `path` entries) is done by `kcl-render`, cached by content digest, and needs
  no `kcl`/`kpm` binary.
