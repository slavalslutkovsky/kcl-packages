# network-gcp

GCP backend for the `Network` XR (`cloud.example.org/v1alpha1`): a custom-mode
VPC network with one regional subnetwork, Cloud Router + Cloud NAT egress, an
optional private-service-access range reservation, and an ingress firewall rule
standing in for AWS's intra-VPC security group. Typed against the vendored
`gcp-compute` schema package
([../../../providers/gcp-compute](../../../providers/gcp-compute)). The
`network-gcp` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/network-gcp`, followed by `function-auto-ready`.

`NetworkHub` spokes reference the network this XR publishes as
`status.selfLink`; see [docs/hubspoke.md](../../../../docs/hubspoke.md).

## Composed resources

All kinds are in `compute.gcp.m.upbound.io`; everything after the network binds
to it (or to the router) with `<field>Selector.matchControllerRef`.

| resource | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Network` | `network` | always | `metadata.name` = XR name (the GCP network name); `autoCreateSubnetworks: false`, `routingMode: REGIONAL` |
| `Subnetwork` | `subnetwork` | always | `ipCidrRange` = `cidr`, `privateIpGoogleAccess` |
| `Router` | `router` | `natGateway` | |
| `RouterNAT` | `nat` | `natGateway` | `ALL_SUBNETWORKS_ALL_IP_RANGES`, `natIpAllocateOption: AUTO_ONLY`, logging off |
| `GlobalAddress` | `service-range` | `serviceRange` set | `purpose: VPC_PEERING`, `addressType: INTERNAL`, `address` / `prefixLength` split from the CIDR (malformed CIDRs fail the render) |
| `Firewall` | `firewall-internal` | `allowInternalIngress` | `INGRESS`, protocol `all` from `cidr` |

Only the range reservation is managed: the `servicenetworking.googleapis.com`
peering that consumes it is a one-time out-of-band step per network, because
provider-gcp ships no `ServiceNetworkingConnection` resource.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | default | effect |
| --- | --- | --- |
| `region` | required | `Subnetwork`, `Router`, `RouterNAT` region |
| `cidr` | `10.0.0.0/16` | subnetwork primary range and firewall source range |
| `natGateway` | `true` | Router + RouterNAT |
| `privateGoogleAccess` | `true` | `Subnetwork.privateIpGoogleAccess` |
| `serviceRange` | unset | `GlobalAddress` reservation |
| `allowInternalIngress` | `true` | the internal firewall rule; off leaves GCP's implied deny-all ingress |
| `deletionPolicy` | `Delete` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | | `GlobalAddress.labels` only; no other composed kind has a labels field |
| `subnetPrefixLength`, `availabilityZones`, `publicSubnets`, `databaseSubnetGroups` | | ignored (AWS only) |

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | `true` once the network reports an `id` |
| `id` | observed network `id` |
| `name` | XR name |
| `selfLink` | observed network self link only; never synthesised (the project id is unknown to the composition) |
| `region` | `spec.region` |
| `cidr` | `spec.cidr`, else `10.0.0.0/16` |
| `privateSubnetIds` | `[<subnetwork id or selfLink>]` once observed, else `[]` |
| `serviceRange` | the observed reservation as `<address>/<prefixLength>`, else the requested `spec.serviceRange` |
| `natEnabled` | `natGateway` |
| `cloud-url` | VPC network console link |

`publicSubnetIds`, `securityGroupIds`, `dbSubnetGroupName` and
`cacheSubnetGroupName` are never set.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`us-central1`, `serviceRange: 10.240.0.0/16`):

```bash
kcl run packages/cloud/network/gcp
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/network/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/network/xrd/examples/network-gcp.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/network-gcp.yaml](../xrd/examples/network-gcp.yaml)):

```bash
pnpm exec nx run network-gcp:render
```

On a cluster: `just e2e network` (installs `provider-gcp-compute` from
[../xrd/providers.yaml](../xrd/providers.yaml) and applies the examples), or
`just install-module network` for the XRD and Compositions alone.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `network.k` | `cidr_parts`, `render`, `status` |
| `network_test.k` | `kcl test` cases: shape, custom mode, subnetwork, NAT, service range, firewall, deletion policy, status |
| `composition.yaml` | `network-gcp` Composition (`provider: gcp` label) |

## Development

```bash
pnpm exec nx run network-gcp:test     # kcl test
pnpm exec nx run network-gcp:lint     # kcl lint
pnpm exec nx run network-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
