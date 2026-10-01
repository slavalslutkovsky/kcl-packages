# network-aws

AWS backend for the `Network` XR (`cloud.example.org/v1alpha1`): a VPC with one
private and (optionally) one public subnet per availability zone, internet and
NAT egress, a workload security group, and the RDS / ElastiCache subnet groups
that `PostgresInstance` and `RedisInstance` attach to. Typed against the
vendored `aws-ec2`, `aws-rds` and `aws-elasticache` schema packages
([../../../providers/](../../../providers/)). The `network-aws` Composition
runs it through `function-kcl` from `oci://docker.io/yurikrupnik/network-aws`,
followed by `function-auto-ready`.

`NetworkHub` spokes reference the VPC this XR publishes as `status.id`; see
[docs/hubspoke.md](../../../../docs/hubspoke.md).

## Composed resources

Every MR gets a deterministic `metadata.name` derived from the XR name, so MRs
of a kind with several instances (subnets, route tables) are wired by
`<field>Ref.name`; single-instance kinds (VPC, security group) by
`<field>Selector.matchControllerRef`. Routes and security group rules are
separate MRs because the generated `RouteTable` and `SecurityGroup` types have
no inline `route` / `ingress` / `egress`.

| resource (API group) | name | when |
| --- | --- | --- |
| `VPC` (`ec2.aws.m.upbound.io`) | `<xr>-vpc` | always; DNS support and DNS hostnames on |
| `Subnet` | `<xr>-private-<i>` | one per zone, `mapPublicIpOnLaunch: false` |
| `Subnet` | `<xr>-public-<i>` | `publicSubnets`, one per zone, `mapPublicIpOnLaunch: true` |
| `InternetGateway` | `<xr>-igw` | `publicSubnets` |
| `RouteTable` + `Route` `0.0.0.0/0` → IGW | `<xr>-public-rt`, `<xr>-public-route` | `publicSubnets` |
| `RouteTableAssociation` | `<xr>-public-rta-<i>` | `publicSubnets`, one per public subnet |
| `EIP` (`domain: vpc`) + `NATGateway` | `<xr>-nat-eip`, `<xr>-nat` | `natGateway` and `publicSubnets`; one gateway, in `public-0` |
| `RouteTable` | `<xr>-private-rt` | always |
| `Route` `0.0.0.0/0` → NAT | `<xr>-private-route` | NAT enabled |
| `RouteTableAssociation` | `<xr>-private-rta-<i>` | always, one per private subnet |
| `SecurityGroup` | `<xr>-workload` | always |
| `SecurityGroupEgressRule` (all protocols to `0.0.0.0/0`) | `<xr>-workload-egress` | always |
| `SecurityGroupIngressRule` (all protocols from `cidr`) | `<xr>-workload-ingress` | `allowInternalIngress` |
| `SubnetGroup` (`rds.aws.m.upbound.io`) | `<xr>-db` | `databaseSubnetGroups`; private subnets only; external-name pinned to `<xr>-db` |
| `SubnetGroup` (`elasticache.aws.m.upbound.io`) | `<xr>-cache` | `databaseSubnetGroups`; private subnets only; external-name pinned to `<xr>-cache` |

All `ec2` kinds are in `ec2.aws.m.upbound.io`.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | default | effect |
| --- | --- | --- |
| `region` | required | `forProvider.region` on every MR |
| `cidr` | `10.0.0.0/16` | VPC `cidrBlock`; source range for the subnets; ingress rule source |
| `subnetPrefixLength` | `20` | size of each carved subnet. Blocks are taken from the front of `cidr` in order: private subnets get blocks `0..n-1`, public `n..2n-1`, and both halves are always reserved, so enabling public subnets later never renumbers the private ones. The render fails if `2n` blocks do not fit |
| `availabilityZones` | none | required here: an empty list fails the render |
| `publicSubnets` | `true` | public tier, IGW and public routing; `false` also forces NAT off |
| `natGateway` | `true` | EIP + NAT Gateway + private default route (only with public subnets) |
| `allowInternalIngress` | `true` | ingress rule from `cidr` |
| `databaseSubnetGroups` | `true` | RDS and ElastiCache subnet groups |
| `deletionPolicy` | `Delete` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | `{}` | merged over a `Name` tag (`<mr-name>`) on every taggable MR; user tags win |
| `serviceRange`, `privateGoogleAccess` | | ignored (GCP only) |

Status written back to the XR (observed values keyed by composition resource
name):

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once the VPC reports an `id` |
| `id` | VPC id, once observed |
| `name` | XR name (the VPC's `Name` tag) |
| `region` | observed VPC region, else `spec.region` |
| `cidr` | observed `cidrBlock`, else `spec.cidr`, else `10.0.0.0/16` |
| `privateSubnetIds` / `publicSubnetIds` | observed subnet ids in zone order, skipping ones not created yet |
| `securityGroupIds` | the workload group id, once observed |
| `natEnabled` | effective NAT (`false` when `publicSubnets` is off) |
| `dbSubnetGroupName` / `cacheSubnetGroupName` | `<xr>-db` / `<xr>-cache` (observed id when present), only with `databaseSubnetGroups` |
| `cloud-url` | VPC console link |

`selfLink` and `serviceRange` are never set.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`us-east-1`, two zones, all defaults):

```bash
kcl run packages/cloud/network/aws
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/network/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/network/xrd/examples/network-aws.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/network-aws.yaml](../xrd/examples/network-aws.yaml)):

```bash
pnpm exec nx run network-aws:render
```

On a cluster: `just e2e network` (installs the `ec2`, `rds` and `elasticache`
providers from [../xrd/providers.yaml](../xrd/providers.yaml) and applies the
examples), or `just install-module network` for the XRD and Compositions alone.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `network.k` | `subnet_cidrs` carving, `render`, `status` |
| `network_test.k` | `kcl test` cases: CIDR carving, every MR tier, each flag off, deletion policy, status |
| `composition.yaml` | `network-aws` Composition (`provider: aws` label) |

## Development

```bash
pnpm exec nx run network-aws:test     # kcl test
pnpm exec nx run network-aws:lint     # kcl lint
pnpm exec nx run network-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
