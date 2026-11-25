import runtime
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

# ---- subnets mode -------------------------------------------------------------

# The infra mgmt host plan plus a second region: block, two subnets, GKE ranges.
_gke = {
  region = "me-west1"
  cidr = "10.10.0.0/16"
  serviceRange = "10.10.128.0/20"
  subnets = [
    {name = "mgmt-me-west1", cidr = "10.10.0.0/24", secondaryRanges = {pods = "10.10.32.0/19", services = "10.10.16.0/22"}, flowLogSampling = 0}
    {region = "europe-west1", cidr = "10.10.1.0/24", privateGoogleAccess = False, flowLogSampling = 0.25}
  ]
}

# Without spec.subnets the render must not move: same names, kinds and order as
# before the field existed, so live XRs do not churn.
test_subnets_absent_is_legacy = lambda {
  names = [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in network.render(_build({region = "us-central1", serviceRange = "10.240.0.0/16", subnets = []}))]
  assert names == ["network", "subnetwork", "router", "nat", "service-range", "firewall-internal"], "an empty subnets list must render the legacy shape"
  router = _by_name({region = "us-central1"})["router"]
  assert not router.metadata?.labels, "legacy routers must not gain labels"
  sel = _by_name({region = "us-central1"})["nat"].spec.forProvider.routerSelector
  assert sel.matchControllerRef == True and not sel?.matchLabels, "legacy NAT selector must stay as it was"
}

test_subnets_render_shape = lambda {
  names = [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in network.render(_build(_gke))]
  assert names == ["network", "subnetwork-mgmt-me-west1", "subnetwork-demo-europe-west1", "router-me-west1", "nat-me-west1", "router-europe-west1", "nat-europe-west1", "service-range", "firewall-internal"], "one subnetwork per entry, one router + NAT per distinct region"
}

test_subnets_subnetwork_fields = lambda {
  resources = _by_name(_gke)
  a = resources["subnetwork-mgmt-me-west1"]
  assert a.metadata.annotations["crossplane.io/external-name"] == "mgmt-me-west1", "the GCP name must be the subnet name"
  fp = a.spec.forProvider
  assert fp.region == "me-west1", "region defaults to spec.region"
  assert fp.ipCidrRange == "10.10.0.0/24", "cidr is the primary range"
  assert fp.stackType == "IPV4_ONLY", "IPv4-only stack"
  assert fp.privateIpGoogleAccess == True, "privateGoogleAccess defaults to spec.privateGoogleAccess"
  assert [[_x.rangeName, _x.ipCidrRange] for _x in fp.secondaryIpRange] == [["pods", "10.10.32.0/19"], ["services", "10.10.16.0/22"]], "secondary ranges map to rangeName/ipCidrRange in spec order"
  assert not fp?.logConfig, "flowLogSampling 0 sends no logConfig"
  assert fp.enableFlowLogs == False, "flowLogSampling 0 turns flow logs explicitly off"
  assert fp.networkSelector.matchControllerRef == True, "binds to the composed network"
  b = resources["subnetwork-demo-europe-west1"]
  assert b.metadata.annotations["crossplane.io/external-name"] == "demo-europe-west1", "name defaults to <xr-name>-<region>"
  fpb = b.spec.forProvider
  assert fpb.region == "europe-west1", "an explicit subnet region wins"
  assert fpb.privateIpGoogleAccess == False, "an explicit privateGoogleAccess=false is carried"
  assert not fpb?.secondaryIpRange, "no secondary ranges, no field"
  assert fpb?.enableFlowLogs not in [True, False], "sampling > 0 configures logConfig, not the switch"
  assert [fpb.logConfig.aggregationInterval, fpb.logConfig.flowSampling, fpb.logConfig.metadata] == ["INTERVAL_5_MIN", 0.25, "INCLUDE_ALL_METADATA"], "flow-log sampling config"
  c = _by_name({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0/24"}]})["subnetwork-demo-me-west1"].spec.forProvider
  assert not c?.logConfig and c?.enableFlowLogs not in [True, False], "unset sampling sends nothing"
}

test_subnets_nat_per_region = lambda {
  resources = _by_name(_gke)
  regions = ["me-west1", "europe-west1"]
  assert all _r in regions {resources["router-${_r}"].spec.forProvider.region == _r}, "each router lives in its region"
  assert all _r in regions {resources["router-${_r}"].metadata.labels == {"network.cloud.example.org/region" = _r}}, "each router is labelled with its region"
  assert all _r in regions {resources["nat-${_r}"].spec.forProvider.region == _r}, "each NAT lives in its router's region"
  assert all _r in regions {resources["nat-${_r}"].spec.forProvider.routerSelector.matchControllerRef == True and resources["nat-${_r}"].spec.forProvider.routerSelector.matchLabels == {"network.cloud.example.org/region" = _r}}, "each NAT must select its own region's router"
  assert all _r in regions {resources["nat-${_r}"].spec.forProvider.sourceSubnetworkIpRangesToNat == "ALL_SUBNETWORKS_ALL_IP_RANGES"}, "pods egress from secondary ranges"
  off = _by_name(_gke | {natGateway = False})
  assert not any _k in off {_k.startswith("router") or _k.startswith("nat")}, "natGateway=false drops every router and NAT"
}

test_subnets_firewall_sources = lambda {
  fp = _by_name(_gke)["firewall-internal"].spec.forProvider
  assert fp.sourceRanges == ["10.10.0.0/24", "10.10.32.0/19", "10.10.16.0/22", "10.10.1.0/24"], "every primary and secondary range, in spec order"
}

# ---- address plan -------------------------------------------------------------
test_cidr_range = lambda {
  r = network.cidr_range("10.10.32.0/19", "pods")
  assert r.start == 168435712, "10.10.32.0 as an integer"
  assert r.end == 168435712 + 8191, "a /19 spans 8192 addresses"
  assert network.cidr_range("0.0.0.0/0", "all").end == 4294967295, "/0 covers the whole space"
}

test_plan_rejects_invalid = lambda {
  assert "is not an IPv4 CIDR" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.300/24"}]}))
  }), "an octet over 255 must be rejected"
  assert "is not an IPv4 CIDR" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0"}]}))
  }), "a missing prefix must be rejected"
}

test_plan_rejects_misaligned = lambda {
  assert "host bits set" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0/24", secondaryRanges = {pods = "10.10.33.0/19"}}]}))
  }), "a secondary range with host bits set must be rejected"
}

test_plan_rejects_overlap = lambda {
  msg = runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0/24", secondaryRanges = {pods = "10.10.0.0/19"}}]}))
  })
  assert "network-gcp: address plan" in msg and "overlaps" in msg, "a secondary range overlapping its primary must be rejected"
  assert "overlaps serviceRange" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", serviceRange = "10.10.0.0/20", subnets = [{cidr = "10.10.0.0/24"}]}))
  }), "a subnet range overlapping the peering range must be rejected"
}

test_plan_rejects_outside_block = lambda {
  assert "outside the address block" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0/24", secondaryRanges = {pods = "10.20.0.0/19"}}]}))
  }), "a range outside spec.cidr must be rejected"
}

test_plan_rejects_duplicate_names = lambda {
  assert "subnet names must be unique" in runtime.catch(lambda {
    network.render(_build({region = "me-west1", cidr = "10.10.0.0/16", subnets = [{cidr = "10.10.0.0/24"}, {cidr = "10.10.1.0/24"}]}))
  }), "two subnets defaulting to the same <xr>-<region> name must be rejected"
}

# ---- service peering ----------------------------------------------------------
test_service_peering = lambda {
  resources = _by_name(_gke | {servicePeering = True})
  conn = resources["service-peering"]
  assert conn.apiVersion == "servicenetworking.gcp.m.upbound.io/v1beta1" and conn.kind == "Connection", "the peering is a servicenetworking Connection"
  fp = conn.spec.forProvider
  assert fp.service == "servicenetworking.googleapis.com", "peer to Google's service producers"
  assert fp.networkSelector.matchControllerRef == True, "peers the composed network"
  assert fp.reservedPeeringRangesSelector.matchControllerRef == True, "consumes the composed GlobalAddress"
  legacy = _by_name({region = "us-central1", serviceRange = "10.240.0.0/16", servicePeering = True})
  assert "service-peering" in legacy, "servicePeering works in legacy mode too"
}

test_service_peering_needs_range = lambda {
  assert "service-peering" not in _by_name({region = "us-central1", servicePeering = True}), "no serviceRange, nothing to peer"
  assert "service-peering" not in _by_name({region = "us-central1", serviceRange = "10.240.0.0/16"}), "servicePeering defaults off"
}

# ---- status: subnets ----------------------------------------------------------
test_status_subnets_observed = lambda {
  ocds = {
    "subnetwork-mgmt-me-west1" = {
      Resource.status.atProvider = {
        id = "projects/p/regions/me-west1/subnetworks/mgmt-me-west1"
        selfLink = "https://www.googleapis.com/compute/v1/projects/p/regions/me-west1/subnetworks/mgmt-me-west1"
      }
    }
  }
  dxr = network.status(_build(_gke), ocds)
  assert dxr.status.privateSubnetIds == ["projects/p/regions/me-west1/subnetworks/mgmt-me-west1"], "only observed subnetworks are listed"
  subs = dxr.status.subnets
  assert len(subs) == 2, "one entry per subnet, in spec order"
  assert subs[0] == {name = "mgmt-me-west1", region = "me-west1", cidr = "10.10.0.0/24", secondaryRanges = {pods = "10.10.32.0/19", services = "10.10.16.0/22"}, id = "projects/p/regions/me-west1/subnetworks/mgmt-me-west1", selfLink = "https://www.googleapis.com/compute/v1/projects/p/regions/me-west1/subnetworks/mgmt-me-west1"}, "observed subnet entry"
  assert subs[1] == {name = "demo-europe-west1", region = "europe-west1", cidr = "10.10.1.0/24", secondaryRanges = {}}, "unobserved subnets carry no id or selfLink"
}

test_status_subnets_legacy = lambda {
  pre = network.status(_build({region = "us-central1"}), {})
  assert pre.status.subnets == [{region = "us-central1", cidr = "10.0.0.0/16", secondaryRanges = {}}], "the legacy subnetwork, name unknown until observed"
  ocds = {
    subnetwork.Resource = {
      metadata.annotations = {"crossplane.io/external-name" = "demo-abcde"}
      status.atProvider = {id = "projects/p/regions/us-central1/subnetworks/demo-abcde"}
    }
  }
  obs = network.status(_build({region = "us-central1"}), ocds)
  assert obs.status.subnets == [{name = "demo-abcde", region = "us-central1", cidr = "10.0.0.0/16", secondaryRanges = {}, id = "projects/p/regions/us-central1/subnetworks/demo-abcde"}], "the observed legacy subnetwork"
  assert obs.status.privateSubnetIds == ["projects/p/regions/us-central1/subnetworks/demo-abcde"], "legacy privateSubnetIds unchanged"
}
