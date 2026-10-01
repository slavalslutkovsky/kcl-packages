# xup vs. this repo's KCL-based Crossplane tooling

`python/xup-cli` (`xup`) is a small, pythonic CLI — inspired by
[Upbound's `up`](https://docs.upbound.io/cli/) — for scaffolding and
validating multi-cloud Crossplane packages. This repo already has its own,
much more mature answer to the same problem: KCL typed schemas
(`packages/providers/*`), per-cloud Composition logic (`packages/cloud/*`),
a registry-driven codegen pipeline (`tools/nx-kcl`, `tools/providers.sh`,
`packages/providers/registry.yaml`), and `just`/`devkit` for the rest of the
lifecycle. This doc compares them honestly — `xup` is not a replacement for
any of this, and isn't trying to be.

## What each one actually does

| | **kcl-packages (this repo)** | **xup** |
|---|---|---|
| Composition logic | Typed KCL (`packages/cloud/<module>/<cloud>/*.k`), compiled by `function-kcl` at apply time | Static YAML templates (Patch-and-Transform pipeline), rendered once at scaffold time |
| Managed-resource schemas | Full typed schemas generated from real provider CRDs (`packages/providers/*/models`, via `tools/nx-kcl` `import-crd`) | None — `xup init` hardcodes one example field (`region`/`location`) per cloud in `xup/clouds.py` |
| Provider catalog | `packages/providers/registry.yaml`, 60+ rows, drift-checked against generated packages and installed manifests (`tools/providers.sh check`) | `xup/providers.py`: a 10-entry built-in catalog, **or** read the same `registry.yaml` this repo already has (`xup providers --registry ...`) |
| Validation | `just providers-check` (registry/package/manifest drift), KCL's own compile-time type checking, `xrd_test.k`/`bucket_test.k` unit tests per module | `xup validate`: structural checks only — crossplane.yaml shape, XRD required fields, Composition→XRD ref resolution. No type checking of `forProvider` fields |
| Build/package | `devkit`, `just kclx-install`, OCI-published KCL modules | Delegates to `crossplane xpkg build`/`up xpkg build` — xup adds nothing here beyond a thin wrapper (see below) |
| Multi-cloud parity | Enforced by hand: one `.k` file per cloud per module, reviewed like any other code | Enforced by construction: `xup init --clouds aws,gcp,azure` cannot produce a package where one cloud is missing a Composition |
| Scaffolding a new capability | Copy an existing module, rewrite the schema imports and `render()` logic per cloud (hours) | `xup init NAME --kind Kind --group group --clouds aws,gcp,azure` (seconds) — but produces a skeleton, not a working Composition |

## The same example, side by side

Both systems can express "a Bucket claim that composes to a cloud-native
object store." The repo's version is
[`packages/cloud/bucket/aws/bucket.k`](../packages/cloud/bucket/aws/bucket.k):
238 lines of typed KCL importing the real `aws-s3` provider schema, handling
versioning, encryption, public-access blocking, ownership controls, lifecycle
transitions between storage tiers, object lock, CORS, logging and an
import-existing-bucket path — all type-checked against the actual S3
Terraform-provider-derived CRD at compile time. `xup init bucket-demo --kind
Bucket --group storage.example.org --clouds aws` produces ~15 lines of static
YAML with one field (`region`) and no schema behind `forProvider` at all —
KCL's compiler would catch a typo in a field name; `xup`'s templates have no
way to.

This is the central tradeoff: kcl-packages' depth comes from typed schemas
generated straight from provider CRDs and hand-written Composition logic per
cloud. xup's speed comes from not doing any of that — it templates the
*shape* every package needs (meta file, XRD, one Composition per cloud,
example), not the *content* of a specific managed resource.

## Where xup is a genuine complement, not a rewrite

- **`xup providers --registry packages/providers/registry.yaml`** reads this
  repo's actual registry and lists it — same schema
  (`name`/`cloud`/`image`/`tag`/`modules`), no translation layer. It's a
  read-only, pythonic view onto data this repo already owns, not a competing
  source of truth.
- **`xup build` / `xup push`** don't reimplement xpkg's OCI layout (an
  annotated-image spec built by go-containerregistry) — they shell out to
  whichever of `crossplane`/`up` is on `PATH`. Building that in Python would
  either be an incomplete copy or silently diverge from what the real tool
  accepts; delegating is the honest choice. One real bug surfaced doing this:
  `crossplane xpkg build`'s own `--examples-root` default (`./examples`) is
  relative to the *current directory*, not `--package-root` — `xup` passes it
  explicitly so `xup build somedir` works from anywhere, not just from inside
  `somedir`.
- **Structural validation without a cluster.** `xup validate` catches a
  Composition whose `compositeTypeRef` matches no XRD, or an XRD missing
  `openAPIV3Schema`, without needing `crossplane render` or a live API
  server. kcl-packages catches the same class of error differently: KCL's
  compiler plus `xrd_test.k`/`*_test.k` per module.

## Where kcl-packages should stay the source of truth

- **Anything that touches a real managed-resource field.** xup has no
  provider-CRD schema generation; kcl-packages' whole `tools/nx-kcl`
  pipeline exists for exactly that. A field xup can't validate, KCL rejects
  at compile time.
- **Provider registry governance.** `registry.yaml` plus
  `tools/providers.sh check` enforces that every row's generated package,
  installed-provider manifest and catalog entry agree. xup's registry reader
  is consume-only; it has no equivalent write-side check, and shouldn't grow
  one — that would just be a second, divergent implementation of
  `providers.sh`.
- **Non-trivial Composition logic.** Storage tiers, companion resources,
  import-existing-resource semantics, patch functions — this is exactly what
  KCL's `render()` functions are for. xup's templates stop at "one managed
  resource, one field, one patch."

## Verdict

Use `xup` for the first five minutes of a new multi-cloud capability — a
scaffold that's structurally valid and has one Composition per cloud from the
start — and for a quick, pythonic look at this repo's provider registry
without touching `yq`. Everything after that first scaffold (real schemas,
real Composition logic, registry governance, drift checking) belongs in
kcl-packages' existing KCL + Nx + `just` pipeline, which xup deliberately
does not try to replace.
