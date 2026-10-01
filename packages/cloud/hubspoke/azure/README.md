# hubspoke-azure

Azure backend for the `NetworkHub` XR (`cloud.example.org/v1alpha1`). Typed
against the `azure-network` schema package (`packages/providers/azure-network`),
it composes a Virtual WAN, a Virtual Hub (the primary resource) and one
`VirtualHubConnection` per spoke VNet, plus a custom hub route table in
`isolated` topology. The resource group and the spoke VNets already exist and
are never touched. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/hubspoke-azure` through the `hubspoke-azure`
Composition (label `provider: azure`). Background:
[docs/hubspoke.md](../../../../docs/hubspoke.md).

Not composed: Azure Firewall / secured hub, VPN and ExpressRoute gateways,
route maps.

## Composed resources

All are `network.azure.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `VirtualWAN` (`wan`) | always | `allowBranchToBranchTraffic` true in mesh, false in isolated |
| `VirtualHub` (`managed`) | always | `addressPrefix` = `hubCidr`, `sku: Standard`, `branchToBranchTrafficEnabled` as above, WAN by `matchControllerRef` |
| `VirtualHubRouteTable` (`route-table-isolated`) | `topology: isolated` | route-table label `isolated` |
| `VirtualHubConnection` (`connection-<spoke>`) | mesh: always; isolated: once the hub's `defaultRouteTableId` and the custom table's `id` are observed | `remoteVirtualNetworkId` = `network`, `internetSecurityEnabled: false`; no routing block in mesh |

Isolated routing per connection: workload spokes associate with the custom
table and propagate into the default one; shared spokes associate with the
default table and propagate into both. Connections are held back until both
table ids exist, because rendering them without a routing block would build a
full mesh first.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` of the WAN and the hub |
| `resourceGroup` | `resourceGroupName` of the WAN and the hub (required) |
| `hubCidr` | `VirtualHub.addressPrefix` (required) |
| `topology` | branch-to-branch switches, custom route table, connection routing (default `mesh`) |
| `spokes[].name` | `connection-<name>` |
| `spokes[].network` | `remoteVirtualNetworkId` |
| `spokes[].shared` | isolated routing (default `false`) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` on the WAN and the hub |

Ignored: `summaryCidr`, `amazonSideAsn`, `spokes[].subnets`,
`spokes[].routeTableIds`. The render fails without `resourceGroup` or
`hubCidr`, on duplicate spoke names, and on `topology: isolated` with no
`shared: true` spoke.

Status written back: `provider: azure`, `topology`, `hubName` (XR name),
`ready` (hub id observed and every connection has an id), `hubId`,
`defaultRouteTableId`, `routeTableIds` (the custom table, isolated only),
`spokeCount`, `attachedCount`, `spokes[]`, and `cloud-url` (the hub's portal
page once its id is known, the Virtual WAN list before). `hubState` is never
set: the generated `VirtualHub` schema observes no provisioning state.

## Usage

Without `option("params")`, `main.k` renders a built-in example: mesh,
`westeurope`, `platform-rg`, `10.200.0.0/23`, one spoke `team-a`.

```bash
kcl run packages/cloud/hubspoke/azure

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/hubspoke/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/hubspoke/xrd/examples/hubspoke-azure.yaml)}"
```

The shipped example is isolated, so with no `ocds` the second command renders
the WAN, the hub and the custom route table but no connections yet. The output
has `items` (what function-kcl reads: the managed resources, then the
`NetworkHub` carrying status) next to the module's public constants.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/hubspoke-azure.yaml`:

```bash
pnpm exec nx run hubspoke-azure:render
```

On a cluster: `just install-module hubspoke`, or `just e2e hubspoke` end to end.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `hub.k` | `render(oxr, ocds)` and `status(oxr, ocds)` |
| `hub_test.k` | `kcl test` cases |
| `composition.yaml` | `hubspoke-azure` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run hubspoke-azure:test     # kcl test
pnpm exec nx run hubspoke-azure:lint     # kcl lint
pnpm exec nx run hubspoke-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
