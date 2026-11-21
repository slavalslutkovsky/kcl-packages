# network (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-compute and gcp-servicenetworking schema packages. A
# GCP VPC is not one object the way an AWS VPC is: the portable Network fans out
# into a custom-mode compute Network (which itself holds no address range), its
# regional Subnetworks, a Cloud Router + Cloud NAT pair per region for managed
# egress, a GlobalAddress reserving the private-service-access range (plus,
# opt-in, the servicenetworking Connection that peers it), and an ingress
# Firewall rule standing in for AWS's intra-VPC security group.
#
# Two address-plan modes:
#   - legacy (no spec.subnets): one Subnetwork owning the whole of spec.cidr in
#     spec.region. Rendered exactly as before spec.subnets existed, so live XRs
#     do not churn.
#   - subnets (spec.subnets set): spec.cidr is the address block, and every
#     spec.subnets entry becomes a named Subnetwork with optional secondary
#     ranges (GKE pods/services), validated like the infra Pulumi address plan.
#
# The AWS-only knobs of the XRD (subnetPrefixLength, availabilityZones,
# publicSubnets, databaseSubnetGroups) are deliberately ignored here: GCP
# subnetworks are regional rather than zonal, internet reachability is a matter
# of routes and NAT rather than subnet kind, and Cloud SQL / Memorystore attach
# to a network instead of to a subnet group.
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network as vpc
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_subnetwork as subnet
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router as router
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router_n_a_t as nat
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_address as address
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_firewall as firewall
import gcp_servicenetworking.models.unknown as servicenetworking

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Split a CIDR into the two fields GlobalAddress wants: `address` is the network
# address on its own and `prefixLength` is an integer, never the "/16" suffix.
# Asserting here beats emitting a GlobalAddress the API will reject with an
# opaque error several minutes into reconciliation.
cidr_parts = lambda cidr: str -> {str:any} {
    _parts = cidr.split("/")
    assert len(_parts) == 2, "CIDR must be <address>/<prefixLength>, got '${cidr}'"
    assert _parts[0] != "", "CIDR '${cidr}' has no address part"
    assert _parts[1].isdigit(), "CIDR '${cidr}' has a non-numeric prefix length"
    {address = _parts[0], prefixLength = int(_parts[1])}
}

# ---- address plan -----------------------------------------------------------

_octet_ok = lambda o: str -> bool {
    o.isdigit() and len(o) <= 3 and int(o) <= 255
}

# Parse a labelled IPv4 CIDR into its first and last address as integers
# (mirrors infra's cidr.ts). GCP rejects a range with host bits set at apply
# time; failing the render says so before the provider does.
cidr_range = lambda cidr: str, label: str -> {str:any} {
    _parts = cidr.split("/")
    _octets = _parts[0].split(".") if len(_parts) == 2 else []
    _valid = len(_octets) == 4 and all o in _octets {
        _octet_ok(o)
    } and _parts[1].isdigit() and len(_parts[1]) <= 2 and int(_parts[1]) <= 32
    assert _valid, "network-gcp: ${label} (${cidr}) is not an IPv4 CIDR"
    _bits = int(_parts[1])
    _start = ((int(_octets[0]) * 256 + int(_octets[1])) * 256 + int(_octets[2])) * 256 + int(_octets[3])
    _size = 1 << (32 - _bits)
    assert _start % _size == 0, "network-gcp: ${label} (${cidr}): host bits set; the network address is not aligned to /${_bits}"
    {label = label, cidr = cidr, start = _start, end = _start + _size - 1}
}

# Composition-resource-name suffix for a subnet name. GCP names are already
# [a-z0-9-], so this is the identity for every name the API would accept.
slug = lambda s: str -> str {
    "".join([c if c in "abcdefghijklmnopqrstuvwxyz0123456789-" else "-" for c in s.lower()])
}

# spec.subnets with every default applied; [] in legacy mode.
resolve_subnets = lambda oxr -> [{str:any}] {
    _spec = oxr.spec
    _pga = _spec?.privateGoogleAccess
    if _pga == Undefined or _pga == None:
        _pga = True
    [{
        name = _s?.name or "${oxr.metadata.name}-${_s?.region or _spec.region}"
        region = _s?.region or _spec.region
        cidr = _s?.cidr
        secondaryRanges = _s?.secondaryRanges or {}
        # `or` would clobber an explicit False (and an explicit 0 sampling).
        privateGoogleAccess = _pga if _s?.privateGoogleAccess == Undefined or _s?.privateGoogleAccess == None else _s.privateGoogleAccess
        flowLogSampling = _s?.flowLogSampling
    } for _s in _spec?.subnets or []]
}

# Check the subnets-mode address plan and return every subnet range (primary
# then secondaries, in spec order). Mirrors infra's assertDisjoint/assertWithin:
# GCP rejects an overlapping secondary range at apply time, but happily accepts
# overlaps with the peering range that only fail once a service routes there.
validate_plan = lambda oxr, subs: [{str:any}] -> [{str:any}] {
    _spec = oxr.spec
    _missing = [_s.name for _s in subs if not _s.cidr]
    assert not _missing, "network-gcp: subnets ${', '.join(_missing)} have no cidr (the primary range is required)"
    _names = [_s.name for _s in subs]
    _dupes = [_n for _i, _n in _names if _n in _names[:_i]]
    assert not _dupes, "network-gcp: subnet names must be unique; duplicated: ${', '.join(_dupes)}"
    _slugs = [slug(_n) for _n in _names]
    _clashes = [_n for _i, _n in _slugs if _n in _slugs[:_i]]
    assert not _clashes, "network-gcp: subnet names collide after slugging into composition-resource-names: ${', '.join(_clashes)}"
    _bad_sampling = [_s.name for _s in subs if _s.flowLogSampling != Undefined and _s.flowLogSampling != None and (_s.flowLogSampling < 0 or _s.flowLogSampling > 1)]
    assert not _bad_sampling, "network-gcp: flowLogSampling must be in [0, 1] (subnets ${', '.join(_bad_sampling)})"
    _block = cidr_range(_spec?.cidr or "10.0.0.0/16", "address block cidr")
    _ranges = [_r for _s in subs for _r in [cidr_range(_s.cidr, "subnet ${_s.name} primary")] + [cidr_range(_c, "subnet ${_s.name} ${_k}") for _k, _c in _s.secondaryRanges]]
    _outside = ["${_r.label} (${_r.cidr})" for _r in _ranges if _r.start < _block.start or _r.end > _block.end]
    assert not _outside, "network-gcp: address plan: ${', '.join(_outside)} outside the address block cidr (${_block.cidr})"
    _all = _ranges + ([cidr_range(_spec.serviceRange, "serviceRange")] if _spec?.serviceRange else [])
    _overlaps = ["${_a.label} (${_a.cidr}) overlaps ${_b.label} (${_b.cidr})" for _i, _a in _all for _j, _b in _all if _i < _j and _a.start <= _b.end and _b.start <= _a.end]
    assert not _overlaps, "network-gcp: address plan: ${'; '.join(_overlaps)}"
    _ranges
}

# One named Subnetwork of the subnets mode.
subnetwork_mr = lambda s: {str:any}, mp -> subnet.Subnetwork {
    _f = s.flowLogSampling
    subnet.Subnetwork {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "subnetwork-${slug(s.name)}"
            # Pin the GCP name, so GKE and other stacks can refer to it by name.
            "crossplane.io/external-name" = s.name
        }
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            region = s.region
            ipCidrRange = s.cidr
            stackType = "IPV4_ONLY"
            privateIpGoogleAccess = s.privateGoogleAccess
            networkSelector = {matchControllerRef = True}
            if s.secondaryRanges:
                secondaryIpRange = [{rangeName = _k, ipCidrRange = _c} for _k, _c in s.secondaryRanges]
            # Unset: nothing sent, whatever GCP (or the org policy) has stays.
            # 0: flow logs explicitly off — logConfig fields may only be sent
            # while logging is on, so the off switch is enableFlowLogs.
            if _f != Undefined and _f != None and _f > 0:
                logConfig = {aggregationInterval = "INTERVAL_5_MIN", flowSampling = float(_f), metadata = "INCLUDE_ALL_METADATA"}
            elif _f != Undefined and _f != None:
                enableFlowLogs = False
        }
    }
}

# Cloud Router + Cloud NAT for one region. Legacy mode passes the historical
# composition-resource-names `router` / `nat` and no labels.
#
# With several routers under one XR, matchControllerRef alone would let a NAT
# resolve to any of them, so subnets mode labels each router with its region
# and the NAT selects on that label as well.
nat_mrs = lambda region: str, router_name: str, nat_name: str, mp, labels -> [any] {
    [
        router.Router {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = router_name}
            if labels:
                metadata.labels = labels
            if mp:
                spec.managementPolicies = mp
            spec.forProvider.region = region
            spec.forProvider.networkSelector = {matchControllerRef = True}
            # Router has no `labels` field — spec.tags is dropped.
        }
        nat.RouterNAT {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = nat_name}
            if mp:
                spec.managementPolicies = mp
            spec.forProvider.region = region
            if labels:
                spec.forProvider.routerSelector = {matchControllerRef = True, matchLabels = labels}
            else:
                spec.forProvider.routerSelector = {matchControllerRef = True}
            # Cover every range of every subnetwork in the region, secondaries
            # included: GKE pods egress from the pods range, and primary-only
            # NAT would leave every pod without internet access.
            spec.forProvider.sourceSubnetworkIpRangesToNat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
            # Let GCP allocate and rotate the external addresses; reserving
            # them would mean extra Address MRs and a static egress IP
            # contract the portable Network does not promise.
            spec.forProvider.natIpAllocateOption = "AUTO_ONLY"
            # Logging off. `filter` is still required whenever the block is
            # present, so it is set to the cheapest value rather than omitted.
            spec.forProvider.logConfig = {enable = False, $filter = "ERRORS_ONLY"}
            # RouterNAT has no `labels` field — spec.tags is dropped.
        }
    ]
}

render = lambda oxr {
    _spec = oxr.spec

    # The compute Network is named after the XR so the GCP network name is
    # predictable (external-name defaults to metadata.name) and status.name can
    # be published before the provider has observed anything.
    _name = oxr.metadata.name

    _cidr = _spec?.cidr or "10.0.0.0/16"

    # `or` would clobber an explicit False, so default only when unset.
    _nat = _spec?.natGateway
    if _nat == Undefined:
        _nat = True

    _pga = _spec?.privateGoogleAccess
    if _pga == Undefined:
        _pga = True

    _internal = _spec?.allowInternalIngress
    if _internal == Undefined:
        _internal = True

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _subs = resolve_subnets(oxr)
    # Every subnet range, validated; empty in legacy mode.
    _ranges = validate_plan(oxr, _subs) if _subs else []

    _items: [any] = [
        vpc.Network {
            metadata.name = _name
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "network"}
            if _mp:
                spec.managementPolicies = _mp
            # Custom mode: no per-region /20s auto-created out of 10.128.0.0/9,
            # so the subnetworks below are the only ranges in the network and
            # the address plan means exactly what it says.
            spec.forProvider.autoCreateSubnetworks = False
            # REGIONAL keeps Cloud Router advertisements scoped to the region
            # each subnetwork lives in.
            spec.forProvider.routingMode = "REGIONAL"
            # compute Network has no `labels` field (only resourceManagerTags,
            # which takes tagValues/<id> references, not free-form key/values),
            # so spec.tags is dropped here.
        }
    ]

    if _subs:
        _items += [subnetwork_mr(_s, _mp) for _s in _subs]
    else:
        _items += [subnet.Subnetwork {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "subnetwork"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _spec.region
            # The whole of spec.cidr becomes the primary range: GCP subnetworks
            # are regional, so there is nothing to carve per availability zone.
            spec.forProvider.ipCidrRange = _cidr
            # Reach *.googleapis.com from instances with no external IP.
            spec.forProvider.privateIpGoogleAccess = _pga
            # Bind to the Network composed above rather than by name: the
            # controller reference is the only stable link inside one XR.
            spec.forProvider.networkSelector = {matchControllerRef = True}
            # Subnetwork has no `labels` field either — spec.tags is dropped.
        }]

    # Managed egress for instances without external IPs. Cloud NAT is not a
    # standalone object: it hangs off a Cloud Router in the same region, so
    # there is one pair per distinct subnet region.
    if _nat:
        if _subs:
            _all_regions = [_s.region for _s in _subs]
            _regions = [_r for _i, _r in _all_regions if _r not in _all_regions[:_i]]
            _items += [_mr for _r in _regions for _mr in nat_mrs(_r, "router-${_r}", "nat-${_r}", _mp, {"network.cloud.example.org/region" = _r})]
        else:
            _items += nat_mrs(_spec.region, "router", "nat", _mp, Undefined)

    # Private service access: the range Google-managed services (Cloud SQL
    # private IP, Memorystore) draw their addresses from. The reservation is
    # always managed; the servicenetworking.googleapis.com peering that
    # consumes it is opt-in (spec.servicePeering), because networks created
    # before it existed did that peering out of band and a second
    # CreateConnection would fight it.
    if _spec?.serviceRange:
        _range = cidr_parts(_spec.serviceRange)
        _items += [address.GlobalAddress {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "service-range"}
            if _mp:
                spec.managementPolicies = _mp
            # VPC_PEERING + INTERNAL is what marks the block as a peering
            # allocation instead of an ordinary global IP.
            spec.forProvider.purpose = "VPC_PEERING"
            spec.forProvider.addressType = "INTERNAL"
            spec.forProvider.address = _range.address
            spec.forProvider.prefixLength = _range.prefixLength
            spec.forProvider.networkSelector = {matchControllerRef = True}
            # GlobalAddress is the one resource in this composition that accepts
            # labels, so spec.tags lands here and nowhere else.
            if _spec?.tags:
                spec.forProvider.labels = _spec.tags
        }]
        if _spec?.servicePeering:
            _items += [servicenetworking.Connection {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "service-peering"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.service = "servicenetworking.googleapis.com"
                # The composed Network is the only Network and the composed
                # GlobalAddress the only GlobalAddress under this XR, so the
                # controller reference picks exactly one of each.
                spec.forProvider.networkSelector = {matchControllerRef = True}
                spec.forProvider.reservedPeeringRangesSelector = {matchControllerRef = True}
                # Connection has no `labels` field — spec.tags is dropped.
            }]

    # GCP has no security group, so intra-network reachability is a firewall
    # rule over the address space instead of a group membership. Dropping the
    # rule leaves the implied deny-all ingress in place. In subnets mode the
    # sources are every primary and secondary range, so pods reach nodes too.
    if _internal:
        _items += [firewall.Firewall {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "firewall-internal"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.direction = "INGRESS"
            spec.forProvider.sourceRanges = [_r.cidr for _r in _ranges] if _subs else [_cidr]
            # protocol "all" with no ports is the every-protocol rule, the
            # closest equivalent to an AWS self-referencing -1 security group.
            spec.forProvider.allow = [{$protocol = "all"}]
            spec.forProvider.networkSelector = {matchControllerRef = True}
            # Firewall has no `labels` field — spec.tags is dropped.
        }]

    _items
}

# One status.subnets entry. id / selfLink only once observed: a self link
# embeds the project id, which this composition never learns.
subnet_status = lambda s: {str:any}, ocd -> {str:any} {
    _at = ocd?.Resource?.status?.atProvider
    _ext = ocd?.Resource?.metadata?.annotations?["crossplane.io/external-name"]
    {
        if s.name:
            name = s.name
        elif _ext:
            name = _ext
        region = s.region
        cidr = s.cidr
        secondaryRanges = s.secondaryRanges
        if _at?.id:
            id = _at.id
        if _at?.selfLink:
            selfLink = _at.selfLink
    }
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name

    _net = (ocds["network"]?.Resource?.status?.atProvider) if ("network" in ocds) else Undefined
    _sub = (ocds["subnetwork"]?.Resource?.status?.atProvider) if ("subnetwork" in ocds) else Undefined
    _sr = (ocds["service-range"]?.Resource?.status?.atProvider) if ("service-range" in ocds) else Undefined

    _nat = _spec?.natGateway
    if _nat == Undefined:
        _nat = True

    # GCP's network "id" is the provider-assigned identifier; readiness is the
    # first moment the provider has one.
    _id = _net?.id or ""

    # The subnetworks, in spec order. Legacy mode has exactly one, whose GCP
    # name is generated and only known once observed.
    _subs = resolve_subnets(oxr)
    _subnets = [subnet_status(_s, ocds["subnetwork-${slug(_s.name)}"] if "subnetwork-${slug(_s.name)}" in ocds else Undefined) for _s in _subs] if _subs else [subnet_status({name = "", region = _spec.region, cidr = _spec?.cidr or "10.0.0.0/16", secondaryRanges = {}}, ocds["subnetwork"] if "subnetwork" in ocds else Undefined)]

    # Every subnetwork is private, by the XRD's definition. Its id is what a
    # workload needs to place instances; the self link is the fallback
    # spelling when the provider only reported that.
    _subnet_refs = [(_e?.id or _e?.selfLink) for _e in _subnets if _e?.id or _e?.selfLink] if _subs else ([(_sub?.id) or (_sub?.selfLink)] if (_sub?.id) or (_sub?.selfLink) else [])

    # The reserved range as the cloud confirmed it; before the GlobalAddress is
    # observed, echo back what was requested so consumers are not blocked.
    _reserved = "${_sr.address}/${int(_sr.prefixLength)}" if (_sr?.address and _sr?.prefixLength) else (_spec?.serviceRange or "")

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Network"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _id != ""
            name = _name
            region = _spec.region
            cidr = _spec?.cidr or "10.0.0.0/16"
            natEnabled = _nat
            "cloud-url" = "https://console.cloud.google.com/networking/networks/details/${_name}"
            if _id != "":
                id = _id
            # A GCP self link embeds the project id, which this composition never
            # learns (the provider config owns it). Publish only what was
            # actually observed; never synthesise projects/<p>/global/networks/<n>.
            if _net?.selfLink:
                selfLink = _net.selfLink
            privateSubnetIds = _subnet_refs
            subnets = _subnets
            if _spec?.serviceRange and _reserved != "":
                serviceRange = _reserved
            # publicSubnetIds, securityGroupIds, dbSubnetGroupName and
            # cacheSubnetGroupName stay unset: they describe AWS constructs with
            # no GCP counterpart (no public/private split, firewall rules
            # instead of security groups, and data services attach by network
            # rather than by subnet group).
        }
    }
}
