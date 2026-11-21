# network-gcp

GCP backend for the `Network` XR (`cloud.example.org/v1alpha1`): a custom-mode
VPC network with either one regional subnetwork over `cidr` or an explicit
address plan of named subnetworks with secondary ranges (`subnets`), Cloud
Router + Cloud NAT egress per region, an optional private-service-access range
reservation (and, opt-in, its servicenetworking peering), and an ingress
firewall rule standing in for AWS's intra-VPC security group. Typed against the
vendored `gcp-compute` and `gcp-servicenetworking` schema packages
([../../../providers/gcp-compute](../../../providers/gcp-compute),
[../../../providers/gcp-servicenetworking](../../../providers/gcp-servicenetworking)),
and its input against the `network-xrd` package generated from the XRD
([../xrd](../xrd), `just xrd-schema network`): `spec` is converted to
`NetworkSpec`, so XRD defaults, enums and required fields apply in the render
too. Regenerate it after changing `xrd.yaml`. The `network-gcp` Composition
runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/network-gcp`, followed by `function-auto-ready`.

`NetworkHub` spokes reference the network this XR publishes as
`status.selfLink`; see [docs/hubspoke.md](../../../../docs/hubspoke.md).

## Composed resources

All kinds except the `Connection` (`servicenetworking.gcp.m.upbound.io`) are in
`compute.gcp.m.upbound.io`; everything after the network binds to it (or to the
router / reservation) with `<field>Selector.matchControllerRef`.

Without `subnets` (legacy mode, unchanged since before the field existed):

| resource | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Network` | `network` | always | `metadata.name` = XR name (the GCP network name); `autoCreateSubnetworks: false`, `routingMode: REGIONAL` |
| `Subnetwork` | `subnetwork` | always | `ipCidrRange` = `cidr`, `privateIpGoogleAccess` |
| `Router` | `router` | `natGateway` | |
| `RouterNAT` | `nat` | `natGateway` | `ALL_SUBNETWORKS_ALL_IP_RANGES`, `natIpAllocateOption: AUTO_ONLY`, logging off |
| `GlobalAddress` | `service-range` | `serviceRange` set | `purpose: VPC_PEERING`, `addressType: INTERNAL`, `address` / `prefixLength` split from the CIDR (malformed CIDRs fail the render) |
| `Connection` | `service-peering` | `serviceRange` set and `servicePeering` | `service: servicenetworking.googleapis.com`; `networkSelector` and `reservedPeeringRangesSelector` bind the composed network and GlobalAddress |
| `Firewall` | `firewall-internal` | `allowInternalIngress` | `INGRESS`, protocol `all` from `cidr` |

With `subnets` the network, `service-range`, `service-peering` and
`firewall-internal` rows stay, and the rest becomes:

| resource | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Subnetwork` | `subnetwork-<slug(name)>` | per `subnets[]` entry | `crossplane.io/external-name` = `name`; `ipCidrRange` = `cidr`; `secondaryIpRange[]` = `{rangeName, ipCidrRange}` per `secondaryRanges` entry; `stackType: IPV4_ONLY`; `privateIpGoogleAccess`; `flowLogSampling` > 0 → `logConfig {aggregationInterval: INTERVAL_5_MIN, flowSampling, metadata: INCLUDE_ALL_METADATA}`, 0 → `enableFlowLogs: false`, unset → neither |
| `Router` | `router-<region>` | `natGateway`, per distinct subnet region | labelled `network.cloud.example.org/region: <region>` |
| `RouterNAT` | `nat-<region>` | `natGateway`, per distinct subnet region | as above; `routerSelector` also matches the region label, so each NAT binds its own region's router. `ALL_SUBNETWORKS_ALL_IP_RANGES` keeps pod secondary ranges egressing |

The firewall's `sourceRanges` become every primary and secondary range of every
subnet, in spec order.

`servicePeering` is off by default: networks created before it existed did the
`servicenetworking.googleapis.com` peering out of band, and a second
`CreateConnection` would fight that peering. Turn it on for new networks, or
once the out-of-band peering has been removed.

### Address plan (subnets mode)

Mirrors the infra Pulumi `cidr.ts` checks; any failure fails the render with a
`network-gcp:` message:

- every primary and secondary range (and `cidr`) is a valid IPv4 CIDR with no
  host bits set;
- subnet names, and their composition-resource-name slugs, are unique;
- no two ranges overlap: primaries, secondaries and `serviceRange`;
- every subnet range lies inside `cidr` (the address block; `serviceRange` may
  sit elsewhere);
- `flowLogSampling` is within `[0, 1]`.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | default | effect |
| --- | --- | --- |
| `region` | required | legacy: `Subnetwork`, `Router`, `RouterNAT` region; subnets: default subnet region |
| `cidr` | `10.0.0.0/16` | legacy: subnetwork primary range and firewall source range; subnets: the address block every subnet range must lie inside |
| `subnets[]` | unset | explicit address plan: `name` (default `<xr-name>-<region>`), `region` (default `region`), `cidr` (required), `secondaryRanges` (`{rangeName: cidr}`), `privateGoogleAccess` (default `privateGoogleAccess`), `flowLogSampling` (0..1, unset sends nothing). An empty list is legacy mode |
| `natGateway` | `true` | Router + RouterNAT (one pair per subnet region) |
| `privateGoogleAccess` | `true` | `Subnetwork.privateIpGoogleAccess` (per-subnet default in subnets mode) |
| `serviceRange` | unset | `GlobalAddress` reservation |
| `servicePeering` | `false` | servicenetworking `Connection` peering the reservation (needs `serviceRange`) |
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
| `privateSubnetIds` | every observed subnetwork's id (or selfLink) in spec order; legacy `[<subnetwork id or selfLink>]`; `[]` until observed |
| `subnets` | `[{name, region, cidr, secondaryRanges, id?, selfLink?}]` in spec order; `id` / `selfLink` only once observed. Legacy: the one subnetwork, `name` only once observed (its GCP name is generated) |
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

The GKE-ready address plan (the infra `mgmt` host network: block
`10.10.0.0/16`, one `me-west1` subnet with `pods` / `services` secondary
ranges, peered service range) is
[../xrd/examples/network-gcp-gke.yaml](../xrd/examples/network-gcp-gke.yaml):

```bash
kcl run packages/cloud/network/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/network/xrd/examples/network-gcp-gke.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/network-gcp.yaml](../xrd/examples/network-gcp.yaml)):

```bash
pnpm exec nx run network-gcp:render
```

On a cluster: `just e2e network` (installs `provider-gcp-compute` and
`provider-gcp-servicenetworking` from
[../xrd/providers.yaml](../xrd/providers.yaml) and applies the examples), or
`just install-module network` for the XRD and Compositions alone.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `network.k` | `cidr_parts`, `cidr_range`, `slug`, `resolve_subnets`, `validate_plan`, `render`, `status` |
| `network_test.k` | `kcl test` cases: shape, custom mode, subnetwork, NAT, service range, firewall, deletion policy, status, subnets mode, address-plan rejections, service peering |
| `composition.yaml` | `network-gcp` Composition (`provider: gcp` label) |

## Development

```bash
pnpm exec nx run network-gcp:test     # kcl test
pnpm exec nx run network-gcp:lint     # kcl lint
pnpm exec nx run network-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
