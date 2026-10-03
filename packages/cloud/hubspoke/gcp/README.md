# hubspoke-gcp

GCP backend for the `NetworkHub` XR (`cloud.example.org/v1alpha1`). Typed
against the `gcp-networkconnectivity` schema package
(`packages/providers/gcp-networkconnectivity`), it composes one Network
Connectivity Center `Hub` and one VPC `Spoke` per spoke network. The networks
already exist and are never touched. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/hubspoke-gcp` through the `hubspoke-gcp`
Composition (label `provider: gcp`). Background:
[docs/hubspoke.md](../../../../docs/hubspoke.md).

Not composed: VPN, Interconnect and router-appliance spokes, producer VPC
spokes, `ServiceConnectionPolicy`, and the `center`/`edge` groups a `STAR` hub
creates for itself.

## Composed resources

All are `networkconnectivity.gcp.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `Hub` (`managed`) | always | external-name = XR name; `policyMode: PRESET`; `presetTopology` `MESH` (mesh) or `STAR` (isolated) |
| `Spoke` (`spoke-<spoke>`) | mesh: always; isolated: once the hub's resource path is observed | external-name `<xr>-<spoke>`; `location: global`; `linkedVpcNetwork.uri` = `network`; hub by `matchControllerRef` |

In isolated, each spoke's `group` is
`projects/<p>/locations/global/hubs/<hub>/groups/center` for shared spokes and
`…/groups/edge` for workload spokes. That URI embeds the project, which is not
in the spec, so it is taken from the hub's observed `name` or `id` (whichever
contains `/hubs/`) and the spokes appear one reconcile after the hub.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `topology` | `presetTopology` and spoke groups (default `mesh`) |
| `spokes[].name` | `spoke-<name>` and external-name suffix |
| `spokes[].network` | `linkedVpcNetwork.uri` |
| `spokes[].shared` | `center` vs `edge` group in isolated (default `false`) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `labels` on the hub and every spoke |

Ignored: `region` (the NCC hub is global), `resourceGroup`, `hubCidr`,
`summaryCidr`, `amazonSideAsn`, `spokes[].subnets`, `spokes[].routeTableIds`.
The render fails on duplicate spoke names and on `topology: isolated` with no
`shared: true` spoke.

Status written back: `provider: gcp`, `topology`, `hubName` (XR name),
`spokeCount`, `attachedCount` and `spokes[].attached` (spoke `state` is
`ACTIVE`), `ready` (hub `ACTIVE` and every spoke attached), `hubId` (hub
resource path), `hubState`, `spokes[]`, and `cloud-url` (with `?project=` once
the hub reports its project). `routeTableIds` and `defaultRouteTableId` are
never set: NCC has no route-table object.

## Usage

Without `option("params")`, `main.k` renders a built-in example: mesh, spokes
`shared-services` (shared) and `team-a`.

```bash
kcl run packages/cloud/hubspoke/gcp

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/hubspoke/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/hubspoke/xrd/examples/hubspoke-gcp.yaml)}"
```

The output has `items` (what function-kcl reads: the managed resources, then
the `NetworkHub` carrying status) next to the module's public constants.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/hubspoke-gcp.yaml`:

```bash
pnpm exec nx run hubspoke-gcp:render
```

On a cluster: `just install-module hubspoke`, or `just e2e hubspoke` end to end.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `hub.k` | `render(oxr, ocds)` and `status(oxr, ocds)` |
| `hub_test.k` | `kcl test` cases |
| `composition.yaml` | `hubspoke-gcp` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run hubspoke-gcp:test     # kcl test
pnpm exec nx run hubspoke-gcp:lint     # kcl lint
pnpm exec nx run hubspoke-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
