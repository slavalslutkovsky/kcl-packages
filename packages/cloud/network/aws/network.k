# network (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-ec2, aws-rds and aws-elasticache schema packages. AWS
# has no single "network" resource: the portable Network fans out into a VPC,
# one private (and optionally one public) Subnet per availability zone, an
# Internet Gateway, a NAT Gateway with its Elastic IP, a route table per subnet
# tier, a workload Security Group with its rules, and the RDS/ElastiCache
# subnet groups the data services attach to.
#
# Two shapes here are forced by the generated provider types rather than
# chosen: provider-upjet-aws exposes neither RouteTable.spec.forProvider.route
# nor SecurityGroup.spec.forProvider.ingress/egress (both are status-only,
# computed attributes), so routes and security group rules are emitted as their
# own MRs (Route, SecurityGroupIngressRule, SecurityGroupEgressRule).
#
# Cross-resource wiring uses upjet's reference fields, never literal ids:
# `<field>Selector.matchControllerRef = True` where exactly one candidate of
# that kind exists in this composition (the VPC), and `<field>Ref.name` where
# several do (two route tables, 2n subnets). That is why every MR gets a
# deterministic metadata.name derived from the XR name.
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c as ec2_vpc
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_subnet as ec2_subnet
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_internet_gateway as ec2_igw
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_n_a_t_gateway as ec2_nat
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_ip as ec2_eip
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route_table as ec2_rt
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route as ec2_route
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route_table_association as ec2_rta
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group as ec2_sg
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group_ingress_rule as ec2_sg_in
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group_egress_rule as ec2_sg_eg
import aws_rds.models.v1beta1.rds_awsm_upbound_io_v1beta1_subnet_group as rds_subnet_group
import aws_elasticache.models.v1beta1.elasticache_awsm_upbound_io_v1beta1_subnet_group as cache_subnet_group

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The whole address space, in both directions.
_ANY = "0.0.0.0/0"

# `-1` is the EC2 spelling of "every protocol", and it forbids a port range.
_ALL_PROTOCOLS = "-1"

# A missing optional boolean must fall back to the XRD default; an explicitly
# false one must survive. `or` cannot tell those apart, and re-assigning inside
# an `if` does not reliably escape the branch in a KCL lambda, so this is the
# one place the defaulting happens.
_flag = lambda value: any, fallback: bool -> bool {
    fallback if value in [Undefined, None] else bool(value)
}

# Dotted quad <-> 32-bit integer. KCL has no CIDR arithmetic, so subnet carving
# is done by hand on plain integers.
_ip_to_int = lambda ip: str -> int {
    _octets = [int(_o) for _o in ip.split(".")]
    assert len(_octets) == 4, "not an IPv4 address: ${ip}"
    _octets[0] * 16777216 + _octets[1] * 65536 + _octets[2] * 256 + _octets[3]
}

_int_to_ip = lambda value: int -> str {
    "${value // 16777216}.${(value // 65536) % 256}.${(value // 256) % 256}.${value % 256}"
}

# `count` consecutive /prefix_length blocks taken from the front of `cidr`, in
# order. Block size is 2^(32-prefix_length) addresses, so block i starts at
# base + i * size and the blocks tile without gaps or overlap. AWS wants the
# derived prefix between /16 and /28; the XRD already bounds it there.
subnet_cidrs = lambda cidr: str, prefix_length: int, count: int -> [str] {
    _parts = cidr.split("/")
    assert len(_parts) == 2, "cidr must be written a.b.c.d/p, got: ${cidr}"
    _base_prefix = int(_parts[1])
    assert prefix_length >= _base_prefix, "subnetPrefixLength /${prefix_length} is wider than cidr ${cidr}; subnets cannot be larger than the network"
    _capacity = 2 ** (prefix_length - _base_prefix)
    assert count <= _capacity, "${count} /${prefix_length} subnets do not fit in ${cidr}, which holds ${_capacity}; widen cidr or raise subnetPrefixLength"
    _base = _ip_to_int(_parts[0])
    _size = 2 ** (32 - prefix_length)
    ["${_int_to_ip(_base + _i * _size)}/${prefix_length}" for _i in range(count)]
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    _cidr = _spec?.cidr or "10.0.0.0/16"
    _prefix = _spec?.subnetPrefixLength or 20

    # Subnets are per-zone on AWS, so with no zones there is no network to
    # build. The XRD documents availabilityZones as required by this backend.
    _zones = _spec?.availabilityZones or []
    assert len(_zones) > 0, "spec.availabilityZones must name at least one zone: the aws backend carves one subnet per zone, and RDS and ElastiCache subnet groups need them"
    _n = len(_zones)

    _public = _flag(_spec?.publicSubnets, True)

    # A NAT Gateway can only live in a public subnet, so a private-only VPC
    # cannot host one. publicSubnets=false therefore forces natGateway off
    # rather than emitting a NAT Gateway with nowhere to attach; status
    # publishes natEnabled=false so the caller sees what actually happened.
    _nat = _flag(_spec?.natGateway, True) and _public
    _internal = _flag(_spec?.allowInternalIngress, True)
    _groups = _flag(_spec?.databaseSubnetGroups, True)

    _tags = _spec?.tags or {}
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Private subnets take blocks 0..n-1 and public subnets blocks n..2n-1, and
    # both halves are carved unconditionally: turning publicSubnets on later
    # must not renumber — and so recreate — the private subnets.
    _blocks = subnet_cidrs(_cidr, _prefix, 2 * _n)
    _private_cidrs = _blocks[0:_n:]
    _public_cidrs = _blocks[_n:2 * _n:]

    # A Name tag is how the console labels a VPC resource; explicit user tags
    # win, so an operator can still override it.
    _tag = lambda resource_name: str -> {str:str} {
        {Name = resource_name} | _tags
    }

    _items: [any] = [ec2_vpc.VPC {
        metadata.name = "${_name}-vpc"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "vpc"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.cidrBlock = _cidr
        # Both DNS attributes are on unconditionally: RDS and ElastiCache hand
        # out private hostnames, and without VPC DNS support and hostnames
        # those names do not resolve from inside the network.
        spec.forProvider.enableDnsSupport = True
        spec.forProvider.enableDnsHostnames = True
        spec.forProvider.tags = _tag("${_name}-vpc")
    }]

    _items += [ec2_subnet.Subnet {
        metadata.name = "${_name}-private-${_i}"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "private-${_i}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.availabilityZone = _zones[_i]
        spec.forProvider.cidrBlock = _private_cidrs[_i]
        # Exactly one VPC belongs to this XR, so matchControllerRef resolves
        # unambiguously without naming the VPC MR.
        spec.forProvider.vpcIdSelector = {matchControllerRef = True}
        spec.forProvider.mapPublicIpOnLaunch = False
        spec.forProvider.tags = _tag("${_name}-private-${_i}")
    } for _i in range(_n)]

    if _public:
        _items += [ec2_subnet.Subnet {
            metadata.name = "${_name}-public-${_i}"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "public-${_i}"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.availabilityZone = _zones[_i]
            spec.forProvider.cidrBlock = _public_cidrs[_i]
            spec.forProvider.vpcIdSelector = {matchControllerRef = True}
            # What makes the subnet public, together with the IGW default route
            # below: instances launched here get a public IPv4 address.
            spec.forProvider.mapPublicIpOnLaunch = True
            spec.forProvider.tags = _tag("${_name}-public-${_i}")
        } for _i in range(_n)]

        _items += [ec2_igw.InternetGateway {
            metadata.name = "${_name}-igw"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "igw"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.vpcIdSelector = {matchControllerRef = True}
            spec.forProvider.tags = _tag("${_name}-igw")
        }]

        _items += [ec2_rt.RouteTable {
            metadata.name = "${_name}-public-rt"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "public-rt"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.vpcIdSelector = {matchControllerRef = True}
            spec.forProvider.tags = _tag("${_name}-public-rt")
        }]

        # RouteTable.spec.forProvider carries no inline `route` block (it is a
        # computed, status-only attribute in provider-upjet-aws), so the default
        # route is a Route MR. Both route tables hang off the same XR, hence a
        # named routeTableIdRef instead of matchControllerRef.
        _items += [ec2_route.Route {
            metadata.name = "${_name}-public-route"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "public-route"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.destinationCidrBlock = _ANY
            spec.forProvider.routeTableIdRef = {name = "${_name}-public-rt"}
            spec.forProvider.gatewayIdRef = {name = "${_name}-igw"}
        }]

        _items += [ec2_rta.RouteTableAssociation {
            metadata.name = "${_name}-public-rta-${_i}"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "public-rta-${_i}"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.routeTableIdRef = {name = "${_name}-public-rt"}
            spec.forProvider.subnetIdRef = {name = "${_name}-public-${_i}"}
        } for _i in range(_n)]

    if _nat:
        _items += [ec2_eip.EIP {
            metadata.name = "${_name}-nat-eip"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "nat-eip"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            # `vpc` marks the address as VPC-scoped rather than EC2-Classic.
            spec.forProvider.domain = "vpc"
            spec.forProvider.tags = _tag("${_name}-nat-eip")
        }]

        # One NAT Gateway, in the first public subnet. A per-zone NAT would be
        # more available but costs one gateway plus one EIP per zone; a single
        # gateway is the right default for a portable abstraction.
        _items += [ec2_nat.NATGateway {
            metadata.name = "${_name}-nat"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "nat"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.allocationIdRef = {name = "${_name}-nat-eip"}
            spec.forProvider.subnetIdRef = {name = "${_name}-public-0"}
            spec.forProvider.tags = _tag("${_name}-nat")
        }]

    _items += [ec2_rt.RouteTable {
        metadata.name = "${_name}-private-rt"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "private-rt"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.vpcIdSelector = {matchControllerRef = True}
        spec.forProvider.tags = _tag("${_name}-private-rt")
    }]

    # Without a NAT Gateway the private table keeps only the VPC-local route
    # AWS creates implicitly, which is exactly what natGateway=false asks for.
    if _nat:
        _items += [ec2_route.Route {
            metadata.name = "${_name}-private-route"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "private-route"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.destinationCidrBlock = _ANY
            spec.forProvider.routeTableIdRef = {name = "${_name}-private-rt"}
            spec.forProvider.natGatewayIdRef = {name = "${_name}-nat"}
        }]

    _items += [ec2_rta.RouteTableAssociation {
        metadata.name = "${_name}-private-rta-${_i}"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "private-rta-${_i}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.routeTableIdRef = {name = "${_name}-private-rt"}
        spec.forProvider.subnetIdRef = {name = "${_name}-private-${_i}"}
    } for _i in range(_n)]

    _items += [ec2_sg.SecurityGroup {
        metadata.name = "${_name}-workload"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "sg"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.name = "${_name}-workload"
        spec.forProvider.description = "Workload security group for Network ${_name}"
        spec.forProvider.vpcIdSelector = {matchControllerRef = True}
        spec.forProvider.tags = _tag("${_name}-workload")
    }]

    # SecurityGroup.spec.forProvider has no inline ingress/egress either, so
    # rules are their own MRs. There is one SecurityGroup per XR, so the rules
    # bind to it with matchControllerRef.
    _items += [ec2_sg_eg.SecurityGroupEgressRule {
        metadata.name = "${_name}-workload-egress"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "sg-egress"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.securityGroupIdSelector = {matchControllerRef = True}
        spec.forProvider.cidrIpv4 = _ANY
        # An all-protocol rule must not carry a port range.
        spec.forProvider.ipProtocol = _ALL_PROTOCOLS
        spec.forProvider.description = "All outbound traffic"
        spec.forProvider.tags = _tag("${_name}-workload-egress")
    }]

    # Security groups deny by default and are not transitive, so without this
    # rule two workloads in the same network cannot reach each other.
    if _internal:
        _items += [ec2_sg_in.SecurityGroupIngressRule {
            metadata.name = "${_name}-workload-ingress"
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "sg-ingress"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.securityGroupIdSelector = {matchControllerRef = True}
            # The whole VPC range, not the group itself: this also admits
            # traffic from addresses inside the network that are not members
            # of the workload group.
            spec.forProvider.cidrIpv4 = _cidr
            spec.forProvider.ipProtocol = _ALL_PROTOCOLS
            spec.forProvider.description = "All traffic from inside ${_cidr}"
            spec.forProvider.tags = _tag("${_name}-workload-ingress")
        }]

    # RDS and ElastiCache both refuse to place an instance without a subnet
    # group spanning the private subnets, so the Network owns them and
    # publishes their names for PostgresInstance and RedisInstance to attach.
    # Neither generated forProvider carries a `name`: the AWS-side group name is
    # the Crossplane external name, pinned here so status can publish it before
    # the group is observed. subnetIdSelector.matchControllerRef is unusable —
    # it would match the public subnets too — so the private Subnet MRs are
    # named one by one.
    if _groups:
        _private_refs = [{name = "${_name}-private-${_i}"} for _i in range(_n)]

        _items += [rds_subnet_group.SubnetGroup {
            metadata.name = "${_name}-db"
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "db-subnet-group"
                "crossplane.io/external-name" = "${_name}-db"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.description = "Private subnets of Network ${_name}"
            spec.forProvider.subnetIdRefs = _private_refs
            spec.forProvider.tags = _tag("${_name}-db")
        }]

        _items += [cache_subnet_group.SubnetGroup {
            metadata.name = "${_name}-cache"
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "cache-subnet-group"
                "crossplane.io/external-name" = "${_name}-cache"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.description = "Private subnets of Network ${_name}"
            spec.forProvider.subnetIdRefs = _private_refs
            spec.forProvider.tags = _tag("${_name}-cache")
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name

    _zones = _spec?.availabilityZones or []
    _n = len(_zones)

    _public = _flag(_spec?.publicSubnets, True)
    _nat = _flag(_spec?.natGateway, True) and _public
    _groups = _flag(_spec?.databaseSubnetGroups, True)

    # Observed provider state of one composed resource, by composition resource
    # name; Undefined until the provider has created it.
    _obs = lambda resource_name: str -> any {
        (ocds[resource_name]?.Resource?.status?.atProvider) if (resource_name in ocds) else Undefined
    }

    _vpc = _obs("vpc")
    _id = _vpc?.id or ""

    # Subnet ids in zone order, dropping the ones the provider has not created
    # yet: a half-filled list is honest, a list with holes is not indexable.
    _private_ids = [_s for _s in [_obs("private-${_i}")?.id or "" for _i in range(_n)] if _s != ""]
    _public_ids = [_s for _s in [_obs("public-${_i}")?.id or "" for _i in range(_n)] if _s != ""]

    _sg_id = _obs("sg")?.id or ""
    _region = _vpc?.region or _spec.region

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Network"
        metadata.name = _name
        status = {
            provider = "aws"
            # The VPC is the network; everything else hangs off it.
            ready = _id != ""
            # AWS VPCs have no name attribute — the console shows the Name tag,
            # which render() sets from the XR name.
            name = _name
            region = _region
            cidr = _vpc?.cidrBlock or _spec?.cidr or "10.0.0.0/16"
            privateSubnetIds = _private_ids
            publicSubnetIds = _public_ids
            securityGroupIds = [_sg_id] if _sg_id != "" else []
            natEnabled = _nat
            "cloud-url" = "https://console.aws.amazon.com/vpcconsole/home?region=${_region}#VpcDetails:VpcId=${_id}"
            if _id != "":
                id = _id
            # For both subnet group kinds the provider id IS the group name;
            # before observation the pinned external name is already correct.
            if _groups:
                dbSubnetGroupName = _obs("db-subnet-group")?.id or "${_name}-db"
                cacheSubnetGroupName = _obs("cache-subnet-group")?.id or "${_name}-cache"
            # selfLink and serviceRange are GCP-only spellings; AWS leaves them
            # unset rather than inventing a value.
        }
    }
}
