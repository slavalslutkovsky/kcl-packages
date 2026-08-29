import .network

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Network", metadata.name = "demo", spec = _spec}
}

# Composed resources keyed by their composition-resource-name annotation, which
# is the contract the status() lambda and function-auto-ready both read.
_by_name = lambda _spec {
    {_r.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _r for _r in network.render(_build(_spec))}
}

# ---- render: shape ----------------------------------------------------------

# A GCP VPC is not one object: custom-mode network, one regional subnetwork,
# router + NAT for egress, and the intra-network firewall rule. No service
# range was asked for, so no GlobalAddress.
test_render_minimal = lambda {
    items = network.render(_build({region = "us-central1"}))
    assert len(items) == 5, "the default gcp render must emit network, subnetwork, router, nat and firewall"
    names = [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in items]
    assert names == ["network", "subnetwork", "router", "nat", "firewall-internal"], "resource names must be stable: renaming one orphans its live resource"
    assert [_r.apiVersion for _r in items] == ["compute.gcp.m.upbound.io/v1beta1"] * 5, "every MR must come from provider-gcp compute"
    assert [_r.kind for _r in items] == ["Network", "Subnetwork", "Router", "RouterNAT", "Firewall"], "wrong kinds"
}

# ---- render: network --------------------------------------------------------

# Auto mode would create a /20 in every region out of 10.128.0.0/9, which would
# make spec.cidr a lie; custom mode leaves the subnetwork as the only range.
test_network_custom_mode = lambda {
    net = _by_name({region = "us-central1"})["network"]
    assert net.spec.forProvider.autoCreateSubnetworks == False, "the network must be custom mode so spec.cidr is the only range"
    assert net.spec.forProvider.routingMode == "REGIONAL", "a single-region network advertises regionally"
    assert net.metadata.name == "demo", "the network name must be the XR name so status.name is predictable"
}

# ---- render: subnetwork -----------------------------------------------------
test_subnetwork_range = lambda {
    fp = _by_name({region = "us-central1"})["subnetwork"].spec.forProvider
    assert fp.ipCidrRange == "10.0.0.0/16", "cidr must default to 10.0.0.0/16 and land whole on the subnetwork"
    assert fp.region == "us-central1", "the subnetwork is regional and takes spec.region"
    assert fp.networkSelector.matchControllerRef == True, "the subnetwork must bind to the network composed alongside it"
    fp2 = _by_name({region = "us-central1", cidr = "172.16.0.0/20"})["subnetwork"].spec.forProvider
    assert fp2.ipCidrRange == "172.16.0.0/20", "an explicit cidr must be carried verbatim"
}

test_private_google_access = lambda {
    on = _by_name({region = "us-central1"})["subnetwork"].spec.forProvider
    assert on.privateIpGoogleAccess == True, "privateGoogleAccess defaults on"
    off = _by_name({region = "us-central1", privateGoogleAccess = False})["subnetwork"].spec.forProvider
    assert off.privateIpGoogleAccess == False, "privateGoogleAccess=false must be carried, not defaulted back on"
}

# ---- render: nat ------------------------------------------------------------
test_nat_defaults_on = lambda {
    resources = _by_name({region = "us-central1"})
    assert resources["router"].spec.forProvider.region == "us-central1", "the Cloud Router is regional"
    assert resources["router"].spec.forProvider.networkSelector.matchControllerRef == True, "the router must bind to the composed network"
    fp = resources["nat"].spec.forProvider
    assert fp.routerSelector.matchControllerRef == True, "Cloud NAT hangs off the composed Cloud Router"
    assert fp.region == "us-central1", "the NAT lives in the router's region"
    assert fp.sourceSubnetworkIpRangesToNat == "ALL_SUBNETWORKS_ALL_IP_RANGES", "NAT must cover every range in the network"
    assert fp.natIpAllocateOption == "AUTO_ONLY", "egress addresses are GCP-allocated; no static egress IP is promised"
    assert fp.logConfig.enable == False, "NAT logging must be off"
    assert fp.logConfig.$filter == "ERRORS_ONLY", "filter is required whenever the logConfig block is present"
}

# No NAT means no router either: a router with nothing hanging off it is cost
# without function.
test_nat_disabled = lambda {
    resources = _by_name({region = "us-central1", natGateway = False})
    assert "nat" not in resources, "natGateway=false must drop the Cloud NAT"
    assert "router" not in resources, "a router with no NAT serves no purpose"
    assert len(resources) == 3, "network, subnetwork and firewall remain"
}

# ---- render: service range --------------------------------------------------
test_cidr_parts = lambda {
    assert network.cidr_parts("10.240.0.0/16") == {address = "10.240.0.0", prefixLength = 16}, "the prefix must split off as an integer"
    assert network.cidr_parts("192.168.16.0/24").prefixLength == 24, "prefixLength must be an int, not the '/24' suffix"
}

test_service_range = lambda {
    resources = _by_name({region = "us-central1", serviceRange = "10.240.0.0/16", tags = {team = "platform"}})
    fp = resources["service-range"].spec.forProvider
    assert resources["service-range"].kind == "GlobalAddress", "a private-service-access reservation is a GlobalAddress"
    assert fp.purpose == "VPC_PEERING", "VPC_PEERING is what marks the block as a peering allocation"
    assert fp.addressType == "INTERNAL", "a peering range is internal"
    assert fp.address == "10.240.0.0", "address must be the network address alone"
    assert fp.prefixLength == 16, "prefixLength must be split out of the CIDR"
    assert fp.networkSelector.matchControllerRef == True, "the reservation belongs to the composed network"
    assert fp.labels == {team = "platform"}, "GlobalAddress is the only resource here that accepts labels"
}

test_service_range_absent = lambda {
    assert "service-range" not in _by_name({region = "us-central1"}), "no serviceRange must mean no GlobalAddress"
}

# ---- render: internal ingress ----------------------------------------------
test_internal_ingress = lambda {
    fp = _by_name({region = "us-central1", cidr = "10.1.0.0/16"})["firewall-internal"].spec.forProvider
    assert fp.direction == "INGRESS", "the rule admits traffic into the network"
    assert fp.sourceRanges == ["10.1.0.0/16"], "the source range is the network's own address space"
    assert len(fp.allow) == 1, "one allow rule"
    assert fp.allow[0].$protocol == "all", "all protocols — the security-group equivalent"
    assert fp.allow[0]?.ports == Undefined, "no port restriction: 'all' covers protocols that have no ports"
    assert fp.networkSelector.matchControllerRef == True, "the rule applies to the composed network"
}

test_internal_ingress_disabled = lambda {
    resources = _by_name({region = "us-central1", allowInternalIngress = False})
    assert "firewall-internal" not in resources, "allowInternalIngress=false must drop the rule, leaving the implied deny-all"
    assert len(resources) == 4, "network, subnetwork, router and nat remain"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan has to reach every MR: one Delete-managed resource in the set is enough
# to tear the network down.
test_deletion_policy = lambda {
    orphaned = network.render(_build({region = "us-central1", serviceRange = "10.240.0.0/16", deletionPolicy = "Orphan"}))
    assert len(orphaned) == 6, "all six resources under test"
    assert [_r.spec.managementPolicies for _r in orphaned] == [_orphan] * 6, "Orphan must set the non-delete policies on every MR"
    deleted = network.render(_build({region = "us-central1", serviceRange = "10.240.0.0/16"}))
    assert [_r.spec.managementPolicies == _orphan for _r in deleted] == [False] * 6, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = network.status(_build({region = "us-central1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Network", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.name == "demo", "the network name is known ahead of creation"
    assert dxr.status.cidr == "10.0.0.0/16", "the configured address space must be published"
    assert dxr.status.natEnabled == True, "natGateway defaults on"
    assert dxr.status?.id == Undefined, "no id before the network exists"
    assert dxr.status?.selfLink == Undefined, "a self link embeds a project id and must never be synthesised"
    assert dxr.status.privateSubnetIds == [], "no subnetwork observed yet"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/networking/networks/details/demo", "cloud-url must point at the VPC network console"
}

test_status_observed = lambda {
    ocds = {
        network = {
            Resource = {
                status = {
                    atProvider = {
                        id = "projects/p/global/networks/demo"
                        selfLink = "https://www.googleapis.com/compute/v1/projects/p/global/networks/demo"
                    }
                }
            }
        }
        subnetwork = {
            Resource.status.atProvider = {
                id = "projects/p/regions/us-central1/subnetworks/demo-subnet"
                ipCidrRange = "10.0.0.0/16"
            }
        }
        "service-range" = {
            Resource.status.atProvider = {address = "10.240.0.0", prefixLength = 16}
        }
    }
    dxr = network.status(_build({region = "us-central1", serviceRange = "10.240.0.0/16"}), ocds)
    assert dxr.status.ready == True, "an observed network id must mark the network ready"
    assert dxr.status.id == "projects/p/global/networks/demo", "observed id must be surfaced"
    assert dxr.status.selfLink == "https://www.googleapis.com/compute/v1/projects/p/global/networks/demo", "the observed self link must be surfaced verbatim"
    assert dxr.status.privateSubnetIds == ["projects/p/regions/us-central1/subnetworks/demo-subnet"], "the single regional subnetwork is the private subnet"
    assert dxr.status.serviceRange == "10.240.0.0/16", "the reserved range must be reassembled from the observed GlobalAddress"
    assert dxr.status.natEnabled == True, "natEnabled must reflect the requested egress"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/networking/networks/details/demo", "cloud-url must point at the VPC network console"
    assert dxr.status?.publicSubnetIds == Undefined, "public subnets are an AWS construct"
    assert dxr.status?.securityGroupIds == Undefined, "GCP filters by firewall rule, not security group"
    assert dxr.status?.dbSubnetGroupName == Undefined, "subnet groups are an AWS construct"
    assert dxr.status?.cacheSubnetGroupName == Undefined, "subnet groups are an AWS construct"
}

# Before the reservation is observed, echo the requested range rather than
# leaving consumers (Cloud SQL private IP, Memorystore) with nothing.
test_status_service_range_requested = lambda {
    dxr = network.status(_build({region = "us-central1", serviceRange = "10.240.0.0/16", natGateway = False}), {})
    assert dxr.status.serviceRange == "10.240.0.0/16", "the requested range must be published until the GlobalAddress is observed"
    assert dxr.status.natEnabled == False, "natGateway=false must be reflected"
}
