# kclx — one KCL renderer, five front ends

```
                  ┌──────────────────────────────┐
 kclx render ────▶│  kcl-render                  │──▶ items
 (CLI, JSON/YAML) │    engine.rs  embedded KCL   │
                  │    deps.rs    kcl.mod + OCI  │
 kclx function ──▶│    compose.rs desired state  │──▶ RunFunctionResponse.desired
 (gRPC :9443)     └──────────────────────────────┘
                                 ▲
 kclx operator ──▶┌──────────────┴───────────────┐──▶ server-side apply
 (KclModule CRD)  │  kcl-operator                │    + prune + status
                  │    controller.rs  reconcile  │
 kclx api ───────▶│    apply.rs       discovery  │
 (HTTP :8080)     │    service.rs     CLI ∩ API  │
 kclx module ────▶└──────────────────────────────┘
                                 ▲
 kclx agent ─────▶┌──────────────┴───────────────┐──▶ read, dry run, and —
 (CLI, HTTP :8090)│  kcl-agent                   │    only with --yes —
                  │    llm.rs     chat + tools   │    apply / delete
                  │    agent.rs   the loop       │
                  └──────────────────────────────┘
```

`kcl-render` is the only place KCL is executed and the only place rendered
items are turned into Crossplane desired state. Every front end is a thin
adapter over it, which is what makes `kclx render --view desired` an honest
rehearsal of what the cluster composes — verified byte-for-byte against
`crossplane-contrib/function-kcl` v0.12.2 (see *Parity* below) — and what
makes `POST /v1/render` an honest rehearsal of what the operator will apply.

The KCL runtime is **embedded** (`kcl-lang`, the KCL Rust SDK): no `kcl`
binary in the image, no process spawn per reconcile, no LLVM (KCL 0.10+ uses a
pure-Rust evaluator).

## Checks

`just kclx-test` — `cargo clippy --all-targets --locked -- -D warnings` then
`cargo test --locked`, which is exactly what `.github/workflows/rust.yml` runs
on any PR or main push touching `rust/**`, and what the `rust` pre-push hook
runs when the push contains a `rust/**` file. `--locked` everywhere because
`kcl-lang/lib` depends on `kcl-lang/kcl` by branch.

One test is `#[ignore]`d (`deps::tests::a_gzipped_package_pulls_and_resolves`):
it pulls a real package from docker.io. `cargo test -- --ignored` runs it.

`cargo fmt` is deliberately not a gate: this tree is not default-rustfmt
clean, and reformatting it would rewrite every hand-wrapped signature here.

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

## Operator

`kclx operator run` reconciles `KclModule` (`kclx.example.org/v1alpha1`,
namespaced, short name `kclm`): render `spec.source`, apply every item, prune
what the previous render owned and this one does not.

```yaml
apiVersion: kclx.example.org/v1alpha1
kind: KclModule
metadata: {name: hello, namespace: default}
spec:
  source: oci://docker.io/yurikrupnik/app?tag=0.1.4   # or a path, or inline KCL
  params: {greeting: hi}        # → option("params")
  interval: 5m                  # re-render + re-apply, i.e. drift correction
  targetNamespace: apps         # default: the module's own namespace
  prune: true
  suspend: false
  options: {arguments: [], disableNone: true, sortKeys: false}
```

The reconcile contract, and why each part is the way it is:

* **The inventory is the truth.** `status.inventory` lists every applied
  object; pruning is `previous − current`, and deleting the module deletes
  the inventory through the `kclx.example.org/inventory` finalizer. Owner
  references are *not* used: a namespaced `KclModule` may not own a
  cluster-scoped object (the garbage collector would delete the dependent as
  an invalid reference) nor one in another namespace, and running two cleanup
  mechanisms for the two halves of what a package renders is worse than
  running one for all of it.
* **Every apply is a forced server-side apply** under the `kclx` field
  manager. Without `force`, one `kubectl edit` takes a field and every later
  reconcile fails with a conflict instead of correcting the drift.
* **Rendered objects are validated before anything is written**: no
  `apiVersion`, no `kind`, no `metadata.name` (a `generateName` has no stable
  identity to re-apply or prune by), or the same object twice — all rejected
  as `InvalidRender`, with nothing applied.
* **Namespaces are settled against discovery**, not guessed: a namespaced
  object without one gets `targetNamespace`, and a cluster-scoped object that
  carries one has it stripped.
* **Drift is corrected on `spec.interval`**, not by watching the applied
  objects. A dynamic watch per kind a render happens to emit, started and
  stopped as renders change, buys latency on a correction the next re-apply
  already performs.
* **A status write that changes nothing is skipped.** The controller watches
  its own objects, so each status write schedules another reconcile; a status
  that differs every time — a fresh timestamp is enough — is a hot loop.
  `lastAppliedTime` therefore moves with `lastAppliedHash`, not with the
  reconcile.
* **A failed render never clears the inventory**: the module keeps owning
  what it applied, and `Ready=False` carries the reason
  (`RenderFailed`, `InvalidRender`, `UnknownKind`, `ApplyFailed`).

### REST API

`kclx api --addr 0.0.0.0:8080` serves the same modules over HTTP. Both it and
`kclx module …` call one service layer, so neither can grow behaviour the
other lacks.

```
GET    /healthz                        process is up
GET    /readyz                         the API server answers (returns its version)
GET    /v1/modules[?namespace=ns]      list
GET    /v1/modules/{namespace}/{name}  read
PUT    /v1/modules/{namespace}/{name}  create or update; body is a KclModule spec
DELETE /v1/modules/{namespace}/{name}  delete; the controller prunes what it applied
POST   /v1/render                      render a spec without applying it
```

`POST /v1/render` is the dry run: it renders and resolves kinds against the
cluster, returning the items, the inventory that *would* be recorded, and the
digest — the same three the reconcile computes. Errors answer with the
condition vocabulary, `{"reason": "InvalidRender", "error": "item 0: …"}`,
so a client switches on one set of names whether it read a status or a
response.

```shell
curl -s localhost:8080/v1/modules | jq '.items[].metadata.name'
curl -s -X POST localhost:8080/v1/render -d '{"source": "items = [{apiVersion = \"v1\", kind = \"ConfigMap\", metadata.name = \"c\"}]"}'
curl -s -X PUT localhost:8080/v1/modules/default/hello -d '{"source": "oci://docker.io/yurikrupnik/app?tag=0.1.4", "params": {"name": "web"}}'
```

### CLI

```shell
kclx operator crd | kubectl apply -f -   # or: just kclx-crd && kubectl apply -f manifests/kclx-operator/crd.yaml
kclx module apply -f manifests/kclx-operator/example.yaml
kclx module ls -A
kclx module render hello                 # what the controller would apply, now
kclx module get hello -o json
kclx module rm hello                     # deletes the module and its inventory
```

### Install

`just kclx-operator-install` builds the image `just kclx-image` already
builds — one binary, one image, five front ends — side-loads it onto the Kind
nodes and applies `manifests/kclx-operator/`. The controller runs with a
single replica by design: there is no leader election, and two controllers
force-applying the same objects under the same field manager would overwrite
each other forever.

Its ClusterRole is deliberately broad (`apiGroups: ['*']`), because what a
module renders is not knowable in advance; `manifests/kclx-operator/rbac.yaml`
says how to scope it down for a fixed set of kinds.

## Agent

`kclx agent` puts a model in front of that same service layer. It is the one
component in this repo that calls an LLM.

```shell
export KCLX_LLM_MODEL=gpt-4o-mini KCLX_LLM_API_KEY=$OPENAI   # or, local:
export KCLX_LLM_BASE_URL=http://localhost:11434/v1 KCLX_LLM_MODEL=qwen2.5:7b

kclx agent ask "which Buckets in default are not Ready, and what is failing?"
kclx agent ask --yes "create a KclModule hello2 in default rendering a ConfigMap greeting=hi"
kclx agent ask -o json "how many KclModules exist?" | jq '.steps[].tool'
kclx agent serve --addr 0.0.0.0:8090     # POST /v1/agent
```

The endpoint is the OpenAI-compatible `POST {base}/chat/completions` with
tool calling, so OpenAI, Ollama, vLLM, llama.cpp and gateways all work; the
model must support tool calls. No streaming and no memory between runs — one
task per invocation, the whole transcript returned at the end.

**Propose by default.** Without `--yes` (`"approve": true` over HTTP) the
model is not *offered* write tools and `Toolbox::call` refuses them anyway;
the run ends with the YAML it would have applied. The ten tools:

| | tool | |
| --- | --- | --- |
| read | `list_kinds` | the kinds under `kclx.example.org`, `cloud.example.org`, `platform.example.org` |
| | `describe_kind` | the CRD schema, so a proposed spec cannot be invented |
| | `list_resources` | objects plus their conditions |
| | `get_resource` | one object in full |
| | `composed_resources` | a composite's composed objects and their Synced/Ready conditions — the triage call |
| | `events` | recent events for one object |
| dry run | `preview_module` | render a `KclModule` source without applying it (`Service::preview`) |
| | `validate_resource` | server-side apply with `dryRun=All`: the API server validates, nothing is written |
| write | `apply_resource` | server-side apply; a `KclModule` goes through `Service::apply` |
| | `delete_resource` | delete one object |

The system prompt requires a dry run before any proposal or write, and the
tools enforce what a prompt cannot: `v1/Secret` is refused in code, results
over 48 KiB are truncated with a hint to narrow the query, and a cluster
refusal comes back to the model as `{"reason", "error"}` — the same
vocabulary a `Ready` condition uses — so it can correct itself. A model,
transport or configuration failure is not recoverable that way and ends the
run (`ModelFailed` → HTTP 502, `StepLimitReached` → 422).

```
GET  /healthz   process is up
GET  /readyz    the API server answers
POST /v1/agent  {"task": "…", "namespace"?: "default", "approve"?: false, "maxSteps"?: 20}
                → {"answer", "approved", "steps": [{tool, arguments, result, ok}], "writes": []}
```

In-cluster it is a third Deployment with its own ServiceAccount, because it
holds model credentials the module API has no business carrying. Its model
endpoint comes from the `kclx-agent-llm` Secret, which is not committed:
`just kclx-agent-secret <model> [base-url]` creates it, and without it the
pod stays in `CreateContainerConfigError` rather than falling back to some
default model. Whoever can `POST /v1/agent` can set `"approve": true`, so
that Service does not belong on the public side of anything.

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
