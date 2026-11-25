# network-azure

Azure backend for the `Network` XR (`cloud.example.org/v1alpha1`): a
VirtualNetwork over `cidr` in an existing resource group, with either one subnet
over the whole of `cidr` or an explicit address plan of named subnets
(`subnets`), a Standard NAT Gateway with one static Public IP associated with
every subnet, and one Network Security Group associated with every subnet.
Typed against the vendored `azure-network` schema package
([../../../providers/azure-network](../../../providers/azure-network)), and its
input against the `network-xrd` package generated from the XRD
([../xrd](../xrd), `just xrd-schema network`). The `network-azure` Composition
runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/network-azure`, followed by `function-auto-ready`.

`NetworkHub` (azure, Virtual WAN) spokes reference the VNet by the ARM id this
XR publishes as `status.id`; see [docs/hubspoke.md](../../../../docs/hubspoke.md).

## Composed resources

All kinds are `network.azure.m.upbound.io/v1beta1`; every location /
`resourceGroupName` is `region` / `resourceGroup`. `<key>` is empty without
`subnets` and `-<slug(name)>` with them.

| resource | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `VirtualNetwork` | `managed` | always | external-name = XR name, `addressSpace: [cidr]`, `tags` |
| `Subnet` | `subnet<key>` | per subnet | external-name = subnet name (legacy `<xr-name>-<region>`), `addressPrefixes: [cidr]`, `virtualNetworkNameSelector.matchControllerRef`, labelled `network.cloud.example.org/subnet: <slug>` |
| `PublicIP` | `public-ip` | `natGateway` | `sku: Standard`, `allocationMethod: Static` |
| `NATGateway` | `nat-gateway` | `natGateway` | `skuName: Standard` |
| `NATGatewayPublicIPAssociation` | `nat-gateway-public-ip` | `natGateway` | |
| `SubnetNATGatewayAssociation` | `subnet-nat-gateway<key>` | `natGateway`, per subnet | selects its subnet by label |
| `SecurityGroup` | `security-group` | always | |
| `SecurityRule` | `security-rule-deny-vnet-inbound` | `allowInternalIngress: false` | Inbound Deny `VirtualNetwork` → `VirtualNetwork`, priority 4000 (`true` needs no rule: Azure's default `AllowVnetInBound` already allows it) |
| `SubnetNetworkSecurityGroupAssociation` | `subnet-security-group<key>` | per subnet | selects its subnet by label |

`deletionPolicy: Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR.

### Address plan

Failures fail the render with a `network-azure:` message: `resourceGroup` is
required; `cidr` and every subnet `cidr` are aligned IPv4 CIDRs; subnets lie
inside `cidr`, do not overlap, have unique names (and slugs), and are in
`region` (a VNet is regional).

Ignored on Azure: `subnetPrefixLength`, `availabilityZones`, `publicSubnets`,
`databaseSubnetGroups`, `serviceRange`, `servicePeering`,
`privateGoogleAccess`, `subnets[].secondaryRanges` (AKS Azure CNI Overlay takes
pod/service CIDRs outside the VNet; not validated against `cidr`) and
`subnets[].flowLogSampling`.

## Status

| status | value |
| --- | --- |
| `provider` | `azure` |
| `ready` | `true` once the VNet reports an `id` |
| `id` | observed VNet ARM id |
| `name` | XR name |
| `selfLink` | `""` |
| `region`, `cidr` | from spec |
| `privateSubnetIds` | observed subnet ARM ids, spec order |
| `publicSubnetIds` | `[]` |
| `securityGroupIds` | `[<nsg id>]` once observed |
| `subnets` | `[{name, region, cidr, id?}]`, spec order |
| `natEnabled` | `natGateway` |
| `cloud-url` | `https://portal.azure.com/#@/resource<vnet id>` |

## Usage

```bash
kcl run packages/cloud/network/azure     # built-in westeurope example
kcl run packages/cloud/network/azure \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/network/xrd/examples/network-azure.yaml)"
```

## Development

```bash
pnpm exec nx run network-azure:test     # kcl test
pnpm exec nx run network-azure:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
