# entitlement

The paid-feature gate. Two halves: a library the gated Compositions import
([forge/forgejo](../../cloud/forge/forgejo/),
[repository/forgejo](../../cloud/repository/forgejo/)) to refuse composing
unless the tenant's record grants the feature, and a renderer for those
records — the cluster-scoped `Entitlement`
(`platform.example.org/v1alpha1`) named after the tenant namespace. Records
are normally written by whatever owns billing; the renderer lets a tenant list
live in version control.

## Usage

```bash
# built-in demo tenants (tenant-a: team, forgejo + repository; tenant-free: free)
kcl run packages/platform/entitlement -q

# your own tenant list
kcl run packages/platform/entitlement -D values=tenants.yaml -q | kubectl apply -f -
just entitlements tenants.yaml
```

With no `-D values=`, `values.yaml` in the current directory is read if it
exists, otherwise the demo renders. An explicit path that does not exist fails
the render. The recipe only renders; it never applies.

Gate, from a Composition module's `main.k` (the `lib.k` docstring, after
[forge/forgejo/main.k](../../cloud/forge/forgejo/main.k)):

```kcl
import entitlement as ent

_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_gate = ent.resolve(_params, _oxr, "forgejo")

items = [ent.request(_oxr)] + (forge.render(_oxr, _gate) + [forge.status(_oxr, _ocds)] if _gate.ready else [])
```

`request(oxr)` returns a `meta.krm.kcl.dev/v1alpha1` `RequiredResources` item
asking Crossplane for `Entitlement/<oxr namespace>`; emit it on every call.
`resolve` returns a `Gate`: `pending` on the first iteration (no answer yet;
compose nothing, no assert), fatal assert when the record is missing or lacks
the feature, `ready` otherwise. Needs function-kcl >= v0.12 and
`input.spec.target: Default` on the pipeline step.

| function | purpose |
| --- | --- |
| `request(oxr)` | the `RequiredResources` item; asserts the XR has a namespace |
| `resolve(params, oxr, feature)` | `Gate {ready, pending, feature, plan, features, quota}` |
| `at_least(gate, floor)` | plan rank `free` < `team` < `enterprise`; an unknown plan ranks below every floor |
| `within_quota(gate, key, used, default)` | asserts `used <= quota[key]` (or `default`), returns the cap |
| `render(records)` | `[Record]` to `Entitlement` objects |

## Inputs

Values file: a `tenants` list, each entry validated as `lib.Record`.

```yaml
tenants:
  - namespace: tenant-a
    plan: team
    features: [forgejo, repository]
    quota: {repositories: 50}
```

| key | type | default | meaning |
| --- | --- | --- | --- |
| `namespace` | string | required | tenant namespace; becomes the record's `metadata.name` |
| `plan` | `free` \| `team` \| `enterprise` | `free` | informational and `at_least()` input; grants nothing |
| `features` | [string] | `[]` | the authority; each must be in `known_features` (`forgejo`, `repository`) or the render fails |
| `quota` | {string: int} | `{}` | caps read by `within_quota()`; negative values fail |
| `reference` | string | unset | opaque billing handle, never read by a Composition |

## Outputs

A YAML stream of `Entitlement` (`platform.example.org/v1alpha1`, cluster
scoped) objects, one per tenant, `spec.{plan,features}` plus `quota` and
`reference` when set.

## Manifests

| file | content |
| --- | --- |
| `crd.yaml` | the `Entitlement` CRD: plain CRD, not an XRD; cluster-scoped so a tenant cannot edit its own grant |
| `rbac.yaml` | ClusterRole `entitlement:aggregate-to-crossplane` (get/list/watch), so Crossplane core can fetch records |

devkit applies `crd.yaml` and `rbac.yaml` in wave 1 and `examples/` in wave 2.

## Examples

- `examples/tenant-a.yaml` — apply-ready Namespaces and `Entitlement` records
  for `tenant-a` (team, `forgejo` + `repository`, quotas) and `tenant-free`
  (the negative case). A manifest stream, not a values file.

## Layout

| file | content |
| --- | --- |
| `main.k` | record renderer: `-D values=` contract and the built-in demo |
| `lib.k` | `Gate`, `request`, `resolve`, `at_least`, `within_quota`; `Record`, `known_features`, `render` |
| `lib_test.k` | `kcl test` cases for the gate |

## Development

```bash
pnpm exec nx run entitlement:test     # kcl test
pnpm exec nx run entitlement:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
