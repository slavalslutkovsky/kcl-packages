import .network

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

_zones = ["us-east-1a", "us-east-1b"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Network", metadata.name = "demo", spec = _spec}
}

# A two-zone spec with every backend default left alone, plus overrides.
_two_zone = lambda _extra {
    {region = "us-east-1", cidr = "10.0.0.0/16", subnetPrefixLength = 20, availabilityZones = _zones} | _extra
}

# Composition resource names of a render, in emission order.
_names = lambda _spec {
    [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in network.render(_build(_spec))]
}

# The single resource carrying composition resource name `_key`, or Undefined.
_pick = lambda _spec, _key: str {
    _hits = [_r for _r in network.render(_build(_spec)) if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _key]
    _hits[0] if _hits else Undefined
}

# ---- cidr carving -----------------------------------------------------------

# The exact blocks a /16 at /20 must yield: 4096 addresses each, so the third
# octet steps by 16, tiling from the base with no gaps.
test_subnet_cidrs_exact = lambda {
    _out = network.subnet_cidrs("10.0.0.0/16", 20, 4)
    assert _out == ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"], "10.0.0.0/16 at /20 must tile as 0/16/32/48, got ${_out}"
    assert network.subnet_cidrs("172.16.0.0/12", 24, 3) == ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24"], "a /24 block steps the third octet by one"
    assert network.subnet_cidrs("10.1.0.0/16", 28, 2) == ["10.1.0.0/28", "10.1.0.16/28"], "a /28 block steps the fourth octet by sixteen"
    assert len(network.subnet_cidrs("10.0.0.0/16", 20, 16)) == 16, "a /16 holds exactly 16 /20 subnets"
}

# Private takes blocks 0..n-1, public blocks n..2n-1 — the two halves must not
# overlap, and the private half must not move when public subnets exist.
test_subnet_cidrs_private_public_disjoint = lambda {
    _rendered = network.render(_build(_two_zone({})))
    _private = [_r.spec.forProvider.cidrBlock for _r in _rendered if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] in ["private-0", "private-1"]]
    _public = [_r.spec.forProvider.cidrBlock for _r in _rendered if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] in ["public-0", "public-1"]]
    assert _private == ["10.0.0.0/20", "10.0.16.0/20"], "private subnets must take the first blocks, got ${_private}"
    assert _public == ["10.0.32.0/20", "10.0.48.0/20"], "public subnets must take the blocks after the private ones, got ${_public}"
    assert len([_c for _c in _private if _c in _public]) == 0, "private and public ranges must be disjoint"

    # Dropping the public subnets must not renumber the private ones, or
    # flipping the flag would recreate every private subnet.
    _private_only = [_r.spec.forProvider.cidrBlock for _r in network.render(_build(_two_zone({publicSubnets = False}))) if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] in ["private-0", "private-1"]]
    assert _private_only == _private, "private ranges must not depend on publicSubnets"
}

# ---- render: shape ----------------------------------------------------------

# The full default two-zone network: VPC, 2+2 subnets, IGW, both route tables
# with their default routes and per-subnet associations, NAT plus its EIP, the
# workload group with egress and internal ingress, and both subnet groups.
test_render_two_zone_default = lambda {
    _got = _names(_two_zone({}))
    assert _got == [
        "vpc"
        "private-0"
        "private-1"
        "public-0"
        "public-1"
        "igw"
        "public-rt"
        "public-route"
        "public-rta-0"
        "public-rta-1"
        "nat-eip"
        "nat"
        "private-rt"
        "private-route"
        "private-rta-0"
        "private-rta-1"
        "sg"
        "sg-egress"
        "sg-ingress"
        "db-subnet-group"
        "cache-subnet-group"
    ], "the default two-zone render must emit exactly these resources in this order, got ${_got}"
}

test_render_vpc = lambda {
    _vpc = _pick(_two_zone({
        tags = {team = "platform"}
    }), "vpc")
    assert _vpc.apiVersion == "ec2.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert _vpc.kind == "VPC", "wrong kind"
    assert _vpc.metadata.name == "demo-vpc", "MR names must be derived from the XR name so refs resolve"
    _fp = _vpc.spec.forProvider
    assert _fp.region == "us-east-1", "region must be carried onto every MR"
    assert _fp.cidrBlock == "10.0.0.0/16", "cidr must become the VPC cidrBlock"
    assert _fp.enableDnsSupport == True, "private RDS/ElastiCache hostnames need VPC DNS support"
    assert _fp.enableDnsHostnames == True, "private RDS/ElastiCache hostnames need VPC DNS hostnames"
    assert _fp.tags == {Name = "demo-vpc", team = "platform"}, "tags must be carried alongside the console Name tag, got ${_fp.tags}"
}

# Subnets are per zone, private ones never hand out public addresses, and both
# tiers bind to the composed VPC by controller reference.
test_render_subnets = lambda {
    _p0 = _pick(_two_zone({}), "private-0").spec.forProvider
    _p1 = _pick(_two_zone({}), "private-1").spec.forProvider
    assert _p0.availabilityZone == "us-east-1a", "private subnet 0 must land in the first zone"
    assert _p1.availabilityZone == "us-east-1b", "private subnet 1 must land in the second zone"
    assert _p0.mapPublicIpOnLaunch == False, "private subnets must not hand out public addresses"
    assert _p0.vpcIdSelector.matchControllerRef == True, "subnets must bind to the composed VPC by controller reference"
    _pub = _pick(_two_zone({}), "public-1").spec.forProvider
    assert _pub.availabilityZone == "us-east-1b", "public subnet 1 must land in the second zone"
    assert _pub.mapPublicIpOnLaunch == True, "public subnets must hand out public addresses"
    assert len(_names(_two_zone({availabilityZones = ["us-east-1a", "us-east-1b", "us-east-1c"]}))) == 25, "a third zone adds one private and one public subnet plus their two associations"
}

# The generated RouteTable has no inline route block, so the default routes are
# Route MRs bound to their table by name (matchControllerRef cannot tell the
# two tables apart).
test_render_routes = lambda {
    _pub = _pick(_two_zone({}), "public-route").spec.forProvider
    assert _pub.destinationCidrBlock == "0.0.0.0/0", "the public default route must cover the whole internet"
    assert _pub.routeTableIdRef.name == "demo-public-rt", "the public route must attach to the public route table"
    assert _pub.gatewayIdRef.name == "demo-igw", "the public default route must point at the internet gateway"
    _priv = _pick(_two_zone({}), "private-route").spec.forProvider
    assert _priv.routeTableIdRef.name == "demo-private-rt", "the private route must attach to the private route table"
    assert _priv.natGatewayIdRef.name == "demo-nat", "the private default route must point at the NAT gateway"
}

# Associations are one per subnet, named explicitly: a subnet selector with
# matchControllerRef would match every subnet in the composition.
test_render_route_table_associations = lambda {
    _a = _pick(_two_zone({}), "private-rta-1").spec.forProvider
    assert _a.subnetIdRef.name == "demo-private-1", "association 1 must name private subnet 1"
    assert _a.routeTableIdRef.name == "demo-private-rt", "private associations must use the private table"
    _b = _pick(_two_zone({}), "public-rta-0").spec.forProvider
    assert _b.subnetIdRef.name == "demo-public-0", "association 0 must name public subnet 0"
    assert _b.routeTableIdRef.name == "demo-public-rt", "public associations must use the public table"
}

# The NAT gateway must sit in a public subnet and take the composed EIP.
test_render_nat = lambda {
    _eip = _pick(_two_zone({}), "nat-eip").spec.forProvider
    assert _eip.domain == "vpc", "a NAT elastic IP must be VPC-scoped"
    _nat = _pick(_two_zone({}), "nat").spec.forProvider
    assert _nat.subnetIdRef.name == "demo-public-0", "the NAT gateway must live in the first public subnet"
    assert _nat.allocationIdRef.name == "demo-nat-eip", "the NAT gateway must use the composed elastic IP"
}

# ---- render: publicSubnets --------------------------------------------------

# A private-only VPC: no public subnets, no gateway, no public routing. And no
# NAT either, because a NAT gateway has nowhere to live.
test_public_subnets_disabled = lambda {
    _got = _names(_two_zone({publicSubnets = False}))
    assert _got == [
        "vpc"
        "private-0"
        "private-1"
        "private-rt"
        "private-rta-0"
        "private-rta-1"
        "sg"
        "sg-egress"
        "sg-ingress"
        "db-subnet-group"
        "cache-subnet-group"
    ], "publicSubnets=false must drop the public subnets, the IGW, the public routing and the NAT, got ${_got}"
    assert "private-route" not in _got, "a private-only VPC has no NAT, so it must have no default route either"
}

# ---- render: natGateway -----------------------------------------------------
test_nat_gateway_disabled = lambda {
    _got = _names(_two_zone({natGateway = False}))
    assert "nat" not in _got, "natGateway=false must drop the NAT gateway"
    assert "nat-eip" not in _got, "natGateway=false must drop the NAT elastic IP"
    assert "private-route" not in _got, "with no NAT the private table keeps only the implicit VPC-local route"
    assert "igw" in _got, "natGateway=false must not touch the internet gateway"
    assert "public-route" in _got, "natGateway=false must not touch the public default route"
    assert "private-rt" in _got, "the private route table exists regardless of the NAT"
}

# ---- render: security group -------------------------------------------------
test_security_group = lambda {
    _sg = _pick(_two_zone({}), "sg")
    assert _sg.kind == "SecurityGroup", "wrong kind"
    assert _sg.spec.forProvider.name == "demo-workload", "the workload group must be named after the XR"
    assert _sg.spec.forProvider.vpcIdSelector.matchControllerRef == True, "the group must live in the composed VPC"
    _eg = _pick(_two_zone({}), "sg-egress").spec.forProvider
    assert _eg.cidrIpv4 == "0.0.0.0/0", "egress must reach the whole internet"
    assert _eg.ipProtocol == "-1", "egress must cover every protocol"
    assert _eg?.fromPort == Undefined, "an all-protocol rule must not carry a port range"
    _in = _pick(_two_zone({}), "sg-ingress").spec.forProvider
    assert _in.cidrIpv4 == "10.0.0.0/16", "internal ingress must admit the whole network range"
    assert _in.ipProtocol == "-1", "internal ingress must cover every protocol"
    assert _in.securityGroupIdSelector.matchControllerRef == True, "rules must bind to the composed group"
}

test_allow_internal_ingress_disabled = lambda {
    _got = _names(_two_zone({allowInternalIngress = False}))
    assert "sg-ingress" not in _got, "allowInternalIngress=false must drop the ingress rule"
    assert "sg-egress" in _got, "allowInternalIngress must not affect egress"
    assert "sg" in _got, "the group itself survives, it is just left closed inbound"
}

# ---- render: subnet groups --------------------------------------------------

# Both groups span the private subnets only, named one by one because a
# controller-ref selector would also pull in the public subnets.
test_subnet_groups = lambda {
    _db = _pick(_two_zone({}), "db-subnet-group")
    assert _db.apiVersion == "rds.aws.m.upbound.io/v1beta1", "the DB subnet group must be the RDS one"
    assert [_r.name for _r in _db.spec.forProvider.subnetIdRefs] == ["demo-private-0", "demo-private-1"], "the DB subnet group must span the private subnets in zone order"
    # forProvider has no `name`, so the AWS-side group name is the external name.
    assert _db.metadata.annotations["crossplane.io/external-name"] == "demo-db", "the DB group name must be pinned as the external name"
    _cache = _pick(_two_zone({}), "cache-subnet-group")
    assert _cache.apiVersion == "elasticache.aws.m.upbound.io/v1beta1", "the cache subnet group must be the ElastiCache one"
    assert [_r.name for _r in _cache.spec.forProvider.subnetIdRefs] == ["demo-private-0", "demo-private-1"], "the cache subnet group must span the private subnets in zone order"
    assert _cache.metadata.annotations["crossplane.io/external-name"] == "demo-cache", "the cache group name must be pinned as the external name"
}

test_database_subnet_groups_disabled = lambda {
    _got = _names(_two_zone({databaseSubnetGroups = False}))
    assert "db-subnet-group" not in _got, "databaseSubnetGroups=false must drop the RDS subnet group"
    assert "cache-subnet-group" not in _got, "databaseSubnetGroups=false must drop the ElastiCache subnet group"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach every managed resource, not just the VPC: a half-orphaned
# network leaves the VPC behind with its subnets deleted.
test_deletion_policy = lambda {
    _orphaned = network.render(_build(_two_zone({deletionPolicy = "Orphan"})))
    assert len(_orphaned) == 21, "the two-zone render must emit 21 managed resources"
    _wrong = [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in _orphaned if _r.spec.managementPolicies != _orphan]
    assert _wrong == [], "Orphan must set the non-delete policies on every MR, missing on ${_wrong}"
    _deleted = network.render(_build(_two_zone({})))
    _kept = [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in _deleted if _r.spec.managementPolicies == _orphan]
    assert _kept == [], "Delete must not set the orphan policies, wrongly set on ${_kept}"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    _dxr = network.status(_build(_two_zone({})), {})
    assert _dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert _dxr.kind == "Network", "dxr kind must echo the composite"
    assert _dxr.metadata.name == "demo", "dxr must target the composite by name"
    assert _dxr.status.provider == "aws", "provider must be aws"
    assert _dxr.status.ready == False, "pre-creation must be not ready"
    assert _dxr.status?.id == Undefined, "no VPC id before the VPC exists"
    assert _dxr.status.privateSubnetIds == [], "no subnet ids before the subnets exist"
    assert _dxr.status.publicSubnetIds == [], "no subnet ids before the subnets exist"
    assert _dxr.status.securityGroupIds == [], "no group id before the group exists"
    assert _dxr.status.natEnabled == True, "natGateway defaults on"
    assert _dxr.status.cidr == "10.0.0.0/16", "the requested cidr is known ahead of creation"
    # Subnet group names are pinned as external names, so they are known early.
    assert _dxr.status.dbSubnetGroupName == "demo-db", "the DB subnet group name is known ahead of creation"
    assert _dxr.status.cacheSubnetGroupName == "demo-cache", "the cache subnet group name is known ahead of creation"
    assert _dxr.status?.selfLink == Undefined, "selfLink is a GCP spelling and must stay unset on aws"
    assert _dxr.status?.serviceRange == Undefined, "serviceRange is GCP-only and must stay unset on aws"
}

# Observed provider state, keyed by composition resource name, in the shape
# function-kcl hands to the module. A quoted key cannot carry a dotted path, so
# the Resource wrapper is spelled out.
_at = lambda _fields {
    {Resource.status.atProvider = _fields}
}

# A fully observed two-zone network.
_observed = {
    "vpc" = _at({id = "vpc-0abc", cidrBlock = "10.0.0.0/16", region = "us-east-1"})
    "private-0" = _at({id = "subnet-p0"})
    "private-1" = _at({id = "subnet-p1"})
    "public-0" = _at({id = "subnet-u0"})
    "public-1" = _at({id = "subnet-u1"})
    "sg" = _at({id = "sg-0def"})
    "db-subnet-group" = _at({id = "demo-db"})
    "cache-subnet-group" = _at({id = "demo-cache"})
}

test_status_observed = lambda {
    _dxr = network.status(_build(_two_zone({})), _observed)
    assert _dxr.status.ready == True, "an observed VPC id must mark the network ready"
    assert _dxr.status.id == "vpc-0abc", "the VPC id must be surfaced"
    assert _dxr.status.name == "demo", "AWS VPCs carry no name attribute, so the XR name is published"
    assert _dxr.status.region == "us-east-1", "the observed region must be surfaced"
    assert _dxr.status.cidr == "10.0.0.0/16", "the observed cidr block must be surfaced"
    assert _dxr.status.privateSubnetIds == ["subnet-p0", "subnet-p1"], "private subnet ids must come back in zone order"
    assert _dxr.status.publicSubnetIds == ["subnet-u0", "subnet-u1"], "public subnet ids must come back in zone order"
    assert _dxr.status.securityGroupIds == ["sg-0def"], "the workload group id must be surfaced"
    assert _dxr.status.dbSubnetGroupName == "demo-db", "the observed DB subnet group name must be surfaced"
    assert _dxr.status.cacheSubnetGroupName == "demo-cache", "the observed cache subnet group name must be surfaced"
    assert _dxr.status["cloud-url"] == "https://console.aws.amazon.com/vpcconsole/home?region=us-east-1#VpcDetails:VpcId=vpc-0abc", "cloud-url must address the VPC in the console, got ${_dxr.status['cloud-url']}"
}

# Halfway through creation the second zone's subnets do not exist yet; the
# lists must stay dense and ordered rather than carrying holes.
test_status_partially_observed = lambda {
    _partial = {
        "vpc" = _at({id = "vpc-0abc"})
        "private-1" = _at({id = "subnet-p1"})
    }
    _dxr = network.status(_build(_two_zone({})), _partial)
    assert _dxr.status.ready == True, "the VPC alone decides readiness"
    assert _dxr.status.privateSubnetIds == ["subnet-p1"], "unobserved subnets must be omitted, not padded"
    assert _dxr.status.publicSubnetIds == [], "no public subnet ids yet"
    assert _dxr.status.region == "us-east-1", "region falls back to the spec until the VPC reports one"
}

# publicSubnets=false forces the NAT off, and status must say so rather than
# echoing the requested flag.
test_status_nat_forced_off = lambda {
    _dxr = network.status(_build(_two_zone({publicSubnets = False, natGateway = True})), _observed)
    assert _dxr.status.natEnabled == False, "a private-only VPC cannot host a NAT gateway, so natEnabled must be false"
}

test_status_no_subnet_groups = lambda {
    _dxr = network.status(_build(_two_zone({databaseSubnetGroups = False})), _observed)
    assert _dxr.status?.dbSubnetGroupName == Undefined, "no DB subnet group name when the group is not rendered"
    assert _dxr.status?.cacheSubnetGroupName == Undefined, "no cache subnet group name when the group is not rendered"
}
