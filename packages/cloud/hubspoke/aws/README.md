# hubspoke-aws

AWS backend for the `NetworkHub` XR (`cloud.example.org/v1alpha1`). Typed
against the `aws-ec2` schema package (`packages/providers/aws-ec2`), it composes
one Transit Gateway and one `TransitGatewayVPCAttachment` per spoke VPC, plus
hand-wired route tables in `isolated` topology and spoke-side routes toward the
gateway. The spoke VPCs already exist and are never touched. Run by
`function-kcl` from `oci://docker.io/yurikrupnik/hubspoke-aws` through the
`hubspoke-aws` Composition (label `provider: aws`). Background:
[docs/hubspoke.md](../../../../docs/hubspoke.md).

## Composed resources

All are `ec2.aws.m.upbound.io/v1beta1`. Every cross-resource reference is a
selector (no observed state needed, no second pass). Route tables and
attachments carry labels (`cloud.example.org/hub-table`,
`cloud.example.org/spoke`) so selectors match exactly one candidate alongside
`matchControllerRef`.

| resource | when | notes |
| --- | --- | --- |
| `TransitGateway` (`managed`) | always | `amazonSideAsn`, `dnsSupport: enable`; `defaultRouteTableAssociation`/`Propagation` `enable` in mesh, `disable` in isolated |
| `TransitGatewayVPCAttachment` (`attachment-<spoke>`) | one per spoke | `vpcId` = `network`, `subnetIds` = `subnets`; default-table association/propagation `true` in mesh, `false` in isolated |
| `TransitGatewayRouteTable` (`route-table-shared`, `route-table-isolated`) | `topology: isolated` | |
| `TransitGatewayRouteTableAssociation` (`association-<spoke>`) | isolated, one per spoke | shared spokes → `shared` table, workload spokes → `isolated` table |
| `TransitGatewayRouteTablePropagation` (`propagation-<spoke>-shared`) | isolated, one per spoke | every attachment propagates into `shared` |
| `TransitGatewayRouteTablePropagation` (`propagation-<spoke>-isolated`) | isolated, shared spokes only | so the `isolated` table holds routes to shared spokes only |
| `Route` (`route-<spoke>-<i>`) | one per `spokes[].routeTableIds` entry | `destinationCidrBlock` = `summaryCidr`, `transitGatewayIdSelector` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on every resource |
| `topology` | resource set and default-table switches above (default `mesh`) |
| `summaryCidr` | `Route.destinationCidrBlock` (default `10.0.0.0/8`) |
| `amazonSideAsn` | `TransitGateway.amazonSideAsn` (default `64512`) |
| `spokes[].name` | composition-resource-name suffixes and the spoke label |
| `spokes[].network` | `TransitGatewayVPCAttachment.vpcId` |
| `spokes[].subnets` | attachment `subnetIds` |
| `spokes[].routeTableIds` | one `Route` each; empty attaches the VPC without sending traffic |
| `spokes[].shared` | association/propagation targets in isolated (default `false`) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` on gateway, attachments and route tables, merged over a `Name` tag |

Ignored: `resourceGroup`, `hubCidr`. The render fails when spoke names are not
unique, when a spoke has no `subnets`, or when `topology: isolated` has no
`shared: true` spoke.

Status written back: `provider: aws`, `topology`, `hubName` (XR name),
`spokeCount`, `attachedCount`, `ready` (gateway id observed and every attachment
has an id), `hubId`, `defaultRouteTableId` (`associationDefaultRouteTableId`),
`spokes[]`, `routeTableIds` (the two composed tables, isolated only), and
`cloud-url` (the region's Transit Gateways console page). `hubState` is never
set: the generated `TransitGateway` schema observes no state.

## Usage

Without `option("params")`, `main.k` renders a built-in example: isolated,
`eu-west-1`, spokes `shared-services` (shared) and `team-a`.

```bash
kcl run packages/cloud/hubspoke/aws

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/hubspoke/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/hubspoke/xrd/examples/hubspoke-aws.yaml)}"
```

The output has `items` (what function-kcl reads: the managed resources, then
the `NetworkHub` carrying status) next to the module's public constants.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/hubspoke-aws.yaml`:

```bash
pnpm exec nx run hubspoke-aws:render
```

On a cluster: `just install-module hubspoke`, or `just e2e hubspoke` end to end.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `hub.k` | `render(oxr)` and `status(oxr, ocds)` |
| `hub_test.k` | Mesh and isolated resource sets, reachability, selectors, routes, tags, deletion policy, status |
| `composition.yaml` | `hubspoke-aws` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run hubspoke-aws:test     # kcl test
pnpm exec nx run hubspoke-aws:lint     # kcl lint
pnpm exec nx run hubspoke-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
