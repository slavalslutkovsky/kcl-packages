# hubspoke-xrd

The `NetworkHub` XRD (`networkhubs.cloud.example.org`, group
`cloud.example.org`, version `v1alpha1`, `Namespaced`) and the KCL schemas
generated from it under `models/`. One `NetworkHub` is a transit fabric plus one
attachment per spoke network; it attaches networks that already exist and
never creates them. Design notes, the per-cloud mapping and the topologies are
in [docs/hubspoke.md](../../../../docs/hubspoke.md).

`models/` is produced by `just xrd-schema hubspoke` (`kcl import -m crd` over
`xrd.yaml`, with the `spec.crossplane` selector block Crossplane injects into
every v2 XR added). Regenerate after every change to `xrd.yaml`; do not edit
`models/` by hand. Import the composite type with:

```kcl
import hubspoke_xrd.models.v1alpha1.cloud_example_org_v1alpha1_network_hub as hub
```

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `region` | string | ✓ | | Hub region. aws: Transit Gateway and every attachment (spoke VPCs in other regions cannot be attached). azure: Virtual Hub location. Ignored by gcp (NCC hub is global). |
| `resourceGroup` | string | | | Azure-only: existing resource group for the Virtual WAN and Virtual Hub. Required by azure. |
| `hubCidr` | string | | | Azure-only: the Virtual Hub's own address space (/23 or larger, no overlap with spokes). Required by azure. |
| `topology` | `mesh` \| `isolated` | | `mesh` | `mesh`: every spoke reaches every spoke. `isolated`: spokes reach only `shared: true` spokes; needs at least one shared spoke on every backend. |
| `summaryCidr` | string | | `10.0.0.0/8` | AWS-only: destination of the route installed toward the Transit Gateway in each `spokes[].routeTableIds` table. |
| `amazonSideAsn` | integer | | `64512` | AWS-only: Transit Gateway BGP ASN; immutable after creation. |
| `spokes[]` | array, min 1 | ✓ | | One attachment per entry: `name` (DNS-1123, max 40, suffix of every composed resource; required), `network` (VPC id / VNet ARM id / GCP network URI; required), `subnets` (AWS-only, one per AZ, required by aws), `routeTableIds` (AWS-only, optional), `shared` (default `false`). Removing an entry detaches that network and leaves it running. |
| `deletionPolicy` | `Delete` \| `Orphan` | | `Delete` | Maps to Crossplane `managementPolicies`; `Orphan` keeps the hub and attachments. Spoke networks are never touched. |
| `tags` | map[string]string | | | aws tags (gateway, attachments, route tables), azure tags (Virtual WAN, Virtual Hub), gcp labels (hub, spokes). |

Status: `ready`, `provider`, `topology`, `hubId`, `hubName`, `hubState`,
`spokeCount`, `attachedCount`, `spokes[]` (`name`, `network`, `id`, `shared`,
`attached`), `routeTableIds`, `defaultRouteTableId`, `cloud-url`. Printer
columns: `READY`, `PROVIDER`, `TOPOLOGY`, `SPOKES` (`attachedCount`), `HUB`
(`hubId`).

## Backends

The backend is picked by `spec.crossplane.compositionSelector.matchLabels.provider`.

| backend | Composition | `provider` label | composes |
| --- | --- | --- | --- |
| [`../aws/`](../aws/) | `hubspoke-aws` | `aws` | Transit Gateway, VPC attachments, route tables/associations/propagations (isolated), spoke-side routes |
| [`../azure/`](../azure/) | `hubspoke-azure` | `azure` | Virtual WAN, Virtual Hub, hub connections, custom hub route table (isolated) |
| [`../gcp/`](../gcp/) | `hubspoke-gcp` | `gcp` | NCC Hub (`MESH` / `STAR`), VPC Spokes |

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | The `CompositeResourceDefinition` (`apiextensions.crossplane.io/v2`) |
| `providers.yaml` | `provider-aws-ec2`, `provider-gcp-networkconnectivity`, `provider-azure-network`; versions match the schema packages under `packages/providers/` (`just seed-hubspoke-providers`) |
| `functions.yaml` | Pinned `function-kcl` and `function-auto-ready` Functions |
| `examples/hubspoke-aws.yaml` | `prod-hub`: isolated, three spokes with subnets and route tables, `summaryCidr`, `amazonSideAsn` |
| `examples/hubspoke-azure.yaml` | `prod-hub-azure`: isolated, `resourceGroup` + `hubCidr`, spokes by VNet ARM id |
| `examples/hubspoke-gcp.yaml` | `prod-hub-gcp`: mesh, spokes by network URI |

Each example has exactly one `shared: true` spoke (`shared-services`, first).
There is no `providerconfigs.yaml`.

## Usage

Needs a cluster with Crossplane:

```bash
just install-module hubspoke      # xrd.yaml + every backend composition.yaml, repointed at the local registry
just e2e hubspoke                 # cluster, publish, install, providers, apply examples, status
kubectl apply -f packages/cloud/hubspoke/xrd/examples/hubspoke-aws.yaml
kubectl -n default get networkhub
```

## Layout

| path | content |
| --- | --- |
| `main.k` | Placeholder; the package exists to ship `models/` |
| `models/` | Generated schemas: `v1alpha1/cloud_example_org_v1alpha1_network_hub.k` and the k8s `ObjectMeta` it references |
| `xrd_test.k` | The examples decode as `NetworkHub`; XRD defaults come through the generated schema |

## Development

```bash
pnpm exec nx run hubspoke-xrd:test     # kcl test
pnpm exec nx run hubspoke-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
