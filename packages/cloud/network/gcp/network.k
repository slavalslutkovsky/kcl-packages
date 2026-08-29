# network (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-compute schema package. A GCP VPC is not one object the
# way an AWS VPC is: the portable Network fans out into a custom-mode compute
# Network (which itself holds no address range), one regional Subnetwork that
# owns spec.cidr, a Cloud Router + Cloud NAT pair for managed egress, a
# GlobalAddress reserving the private-service-access range, and an ingress
# Firewall rule standing in for AWS's intra-VPC security group.
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

    _items: [any] = [
        vpc.Network {
            metadata.name = _name
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "network"}
            if _mp:
                spec.managementPolicies = _mp
            # Custom mode: no per-region /20s auto-created out of 10.128.0.0/9,
            # so the subnetwork below is the only range in the network and
            # spec.cidr means exactly what it says.
            spec.forProvider.autoCreateSubnetworks = False
            # REGIONAL keeps Cloud Router advertisements scoped to the region the
            # subnetwork lives in; the portable Network is a single-region object.
            spec.forProvider.routingMode = "REGIONAL"
            # compute Network has no `labels` field (only resourceManagerTags,
            # which takes tagValues/<id> references, not free-form key/values),
            # so spec.tags is dropped here.
        }
        subnet.Subnetwork {
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
        }
    ]

    # Managed egress for instances without external IPs. Cloud NAT is not a
    # standalone object: it hangs off a Cloud Router in the same region.
    if _nat:
        _items += [
            router.Router {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "router"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.region = _spec.region
                spec.forProvider.networkSelector = {matchControllerRef = True}
                # Router has no `labels` field — spec.tags is dropped.
            }
            nat.RouterNAT {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "nat"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.region = _spec.region
                spec.forProvider.routerSelector = {matchControllerRef = True}
                # Cover every range of every subnetwork in the network: with one
                # subnetwork this is the same as listing it, and it keeps working
                # if secondary ranges are added later.
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

    # Private service access: the range Google-managed services (Cloud SQL
    # private IP, Memorystore) draw their addresses from. Only the reservation
    # is managed here — the servicenetworking.googleapis.com peering that
    # actually consumes it is out of band, because provider-gcp ships no
    # ServiceNetworkingConnection resource. Without that one-time step the
    # reservation exists but no service can use it.
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

    # GCP has no security group, so intra-network reachability is a firewall
    # rule over the address space instead of a group membership. Dropping the
    # rule leaves the implied deny-all ingress in place.
    if _internal:
        _items += [firewall.Firewall {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "firewall-internal"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.direction = "INGRESS"
            spec.forProvider.sourceRanges = [_cidr]
            # protocol "all" with no ports is the every-protocol rule, the
            # closest equivalent to an AWS self-referencing -1 security group.
            spec.forProvider.allow = [{$protocol = "all"}]
            spec.forProvider.networkSelector = {matchControllerRef = True}
            # Firewall has no `labels` field — spec.tags is dropped.
        }]

    _items
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

    # The single regional subnetwork is the private subnet, by the XRD's
    # definition. Its id is what a workload needs to place instances; the self
    # link is the fallback spelling when the provider only reported that.
    _subnet_ref = (_sub?.id) or (_sub?.selfLink) or ""

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
            if _subnet_ref != "":
                privateSubnetIds = [_subnet_ref]
            else:
                privateSubnetIds = []
            if _spec?.serviceRange and _reserved != "":
                serviceRange = _reserved
            # publicSubnetIds, securityGroupIds, dbSubnetGroupName and
            # cacheSubnetGroupName stay unset: they describe AWS constructs with
            # no GCP counterpart (one regional subnetwork, no public/private
            # split, firewall rules instead of security groups, and data
            # services attach by network rather than by subnet group).
        }
    }
}
