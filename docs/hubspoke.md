# Hub and spoke

One `NetworkHub` XR is a transit fabric plus one attachment per spoke network.
It does **not** create the spokes. `spokes[].network` names a network that
already exists — the one a `Network` XR publishes as `status.id` (AWS) or
`status.selfLink` (GCP), or an Azure VNet ARM id. Keeping the hub and the
networks in separate XRs is what lets a spoke be detached without touching the
workloads in it, and a hub be deleted without taking a VPC with it.

```
kubectl -n default apply -f packages/cloud/hubspoke/xrd/examples/hubspoke-aws.yaml
kubectl -n default get networkhub
NAME       READY   PROVIDER   TOPOLOGY   SPOKES   HUB
prod-hub   true    aws        isolated   3        tgw-0a1b2c3d4e5f
```

Backend selection is a label, not a field:

```yaml
  crossplane:
    compositionSelector:
      matchLabels:
        provider: aws        # aws | gcp | azure
```

## The tool map

Every cloud sells the same shape under a different product, in a different
service, with a different unit of attachment. That mapping is this module:

| concern | aws | gcp | azure |
|---|---|---|---|
| the hub | `TransitGateway` (ec2, regional) | NCC `Hub` (networkconnectivity, **global**) | `VirtualWAN` + `VirtualHub` (network, regional) |
| unit of attachment | `TransitGatewayVpcAttachment` (needs subnets — it places an ENI per AZ) | `Spoke` with `linkedVpcNetwork.uri` | `VirtualHubConnection` with `remoteVirtualNetworkId` |
| spoke identified by | VPC id (`vpc-…`) | network URI (`projects/<p>/global/networks/<n>`) | VNet ARM id (`/subscriptions/…`) |
| hub address space | none | none | **required** (`spec.hubCidr`) — Azure runs routers inside the hub |
| mesh reachability | default route table does association + propagation | `presetTopology: MESH` | default hub route table + branch-to-branch |
| spoke isolation | two `TransitGatewayRouteTable`s + explicit associations and propagations | `presetTopology: STAR`, spokes in the hub's `center`/`edge` groups | a custom `VirtualHubRouteTable` that only shared connections propagate into |
| spoke-side routes | **yours to install** — one `Route` per `spokes[].routeTableIds` toward the gateway | programmed by NCC | owned by the connection's routing |
| cross-region | not by this XR (a TGW attaches VPCs in its own region; crossing needs a peering attachment) | native — the hub is global | not by this XR (one hub per region) |
| provider package | `provider-aws-ec2` | `provider-gcp-networkconnectivity` | `provider-azure-network` |

Two consequences worth saying out loud:

1. **AWS needs subnets, the other two do not.** A Transit Gateway attachment is
   a set of ENIs; a zone without a subnet in `spokes[].subnets` has no path to
   the gateway at all. The aws backend therefore rejects a spoke with no
   subnets instead of building an attachment that silently drops that zone.
2. **AWS is also the only backend that cannot finish the job.** The gateway
   routes what reaches it; getting traffic out of the spoke VPC is a route in
   the spoke's own route table. That is what `spokes[].routeTableIds` and
   `spec.summaryCidr` are for. Leaving `routeTableIds` empty attaches the VPC
   and sends nothing — deliberate, because those route tables usually belong to
   the `Network` XR.

## Topologies

`spec.topology` is the only knob that changes the resource set, and
`spokes[].shared` is the only thing that distinguishes one spoke from another.

### `mesh` — every spoke reaches every spoke

The cheapest form on all three clouds, because each one's default routing
already does it: AWS leaves `defaultRouteTableAssociation`/`Propagation` on
`enable`, GCP uses a `MESH` hub, Azure's connections carry no routing block and
land on the hub's default route table. `shared: true` means nothing here.

### `isolated` — a workload spoke reaches shared services only

The shared-services pattern: DNS, inspection, CI and management live in spokes
marked `shared: true`; everything else may talk to them and to nothing else.
The three clouds express it in three different objects, but with one and the
same argument:

- **aws** — the Transit Gateway's default association and propagation are
  turned **off**, and two route tables are composed. Every attachment
  propagates into the `shared` table; only shared spokes' attachments also
  propagate into the `isolated` table. Workload spokes associate with the
  `isolated` table, shared spokes with the `shared` one. A workload spoke's
  table therefore holds shared routes only, while a shared spoke's table holds
  everything.
- **gcp** — the hub becomes `presetTopology: STAR`, whose `center` and `edge`
  groups are exactly this distinction. Shared spokes join
  `…/hubs/<hub>/groups/center`, workload spokes `…/groups/edge`; NCC then
  refuses edge-to-edge itself.
- **azure** — one custom hub route table is composed. Workload connections
  associate with it and propagate into the hub's default table; shared
  connections associate with the default table and propagate into **both**. So
  the custom table learns shared routes only, and the default table learns
  everything.

`topology: isolated` with no `shared: true` spoke is rejected by all three
backends: it describes a hub where nothing may reach anything, which is a typo,
not a topology.

## Ordering the backends cannot avoid

Two backends need an observed value before part of the topology can exist, so
those resources appear one reconcile later — the same pattern as
`packages/cloud/cluster/onprem` (`flux2-sync` after `flux2`) and
`packages/cloud/landing/azure` (the Front Door origin after the web host):

| second pass | needs | why it cannot be a reference |
|---|---|---|
| gcp spokes, in `isolated` only | the hub's observed resource path (`projects/<p>/locations/global/hubs/<h>`) | `Spoke.forProvider.group` is a plain URI string ending in `/groups/center` or `/groups/edge`, and it embeds the project, which is nowhere in the spec. The two groups are created by the API itself, so they cannot be composed and referenced either. The backend takes the path from whichever of the hub's observed `name`/`id` actually carries `/hubs/` — upjet fills them inconsistently across builds. |
| azure connections, in `isolated` only | the hub's `defaultRouteTableId` **and** the composed custom table's id | Both are ARM ids assigned by Azure. Rendering the connections before they are known would build a full mesh first and tighten it afterwards — a window where every spoke can reach every spoke. |

AWS needs no second pass: every reference there resolves through a selector.
Because it composes *two* route tables, those selectors match on
`matchControllerRef` **plus** a label (`cloud.example.org/hub-table`,
`cloud.example.org/spoke`) — `matchControllerRef` alone would be ambiguous and
Crossplane would refuse to resolve it.

## Status

| field | meaning |
|---|---|
| `ready` | the hub exists **and** every spoke is attached — half a topology is not one |
| `hubId`, `hubName` | Transit Gateway id / NCC hub resource path / Virtual Hub ARM id; `hubName` is always the XR name |
| `hubState` | **gcp only** (`CREATING`/`ACTIVE`). Neither the generated `TransitGateway` nor `VirtualHub` schema observes a lifecycle state, so aws and azure omit the key rather than invent one |
| `spokeCount`, `attachedCount` | asked for vs. confirmed; they are equal when `ready` |
| `spokes[]` | one row per spec spoke, in spec order: `name`, `network`, `shared`, `attached`, `id` |
| `routeTableIds` | the hub-side tables this XR composed (isolated only; empty in mesh, where the cloud's own default table is used) |
| `defaultRouteTableId` | AWS `associationDefaultRouteTableId` / Azure `defaultRouteTableId`; empty on gcp, which has no such object |

## Files

| path | what |
|---|---|
| `packages/cloud/hubspoke/xrd/xrd.yaml` | the API: `networkhubs.cloud.example.org`, Namespaced, v1alpha1 |
| `packages/cloud/hubspoke/xrd/models/` | generated schemas (`just xrd-schema hubspoke`) — never hand-edited |
| `packages/cloud/hubspoke/xrd/providers.yaml` | one Provider per cloud |
| `packages/cloud/hubspoke/xrd/examples/` | one XR per backend (aws and azure isolated, gcp mesh) |
| `packages/cloud/hubspoke/aws/hub.k` | Transit Gateway + attachments + route tables/associations/propagations + spoke routes |
| `packages/cloud/hubspoke/gcp/hub.k` | NCC Hub + VPC Spokes; in STAR each spoke names the hub's own `center`/`edge` group, which the API creates and this module never composes |
| `packages/cloud/hubspoke/azure/hub.k` | Virtual WAN + Virtual Hub + connections (+ the isolated route table) |
| `packages/providers/registry.yaml` | the `gcp-networkconnectivity` row; `aws-ec2` and `azure-network` gained `hubspoke` |
| `devkit.toml` | the `hubspoke-*` deps rows: XRD wave 2, providers 3, Compositions 4, examples 5 |

## Commands

```bash
nx run-many -t build test lint --projects=hubspoke-xrd,hubspoke-aws,hubspoke-gcp,hubspoke-azure
just render hubspoke-aws                   # render the example XR through function-kcl (docker)
just render hubspoke-gcp --example=packages/cloud/hubspoke/xrd/examples/hubspoke-gcp.yaml
just xrd-schema hubspoke                   # regenerate xrd/models after an XRD change
just seed-hubspoke-providers               # regenerate the transit schema packages
kubectl -n default get networkhub
```

## Not covered on purpose

- **No spoke networks.** That is the `Network` XR. This one attaches what
  exists, so the two lifecycles stay independent.
- **No hybrid attachments.** VPN, Direct Connect, ExpressRoute, Interconnect
  and router appliances are each a separate object with its own credentials and
  its own BGP story; none of it is portable across the three clouds.
- **No inspection.** An AWS appliance-mode attachment, an Azure secured hub
  with Azure Firewall, and a GCP router appliance are three different products
  with three different pricing models — a portable `firewall: true` would be a
  lie.
- **No cross-account / cross-subscription sharing.** AWS needs RAM shares, GCP
  needs cross-project hub admin roles, Azure needs the peering to be accepted
  on the other side. All three are identity work, not network work.
- **No cross-region hub meshing.** GCP gets it for free (a global hub); AWS
  would need peering attachments and Azure a hub per region plus a WAN-level
  mesh. One hub per XR keeps the region field meaning one thing.
