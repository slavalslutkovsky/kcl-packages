import runtime
import .network

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
_build = lambda _spec {
  {apiVersion = "cloud.example.org/v1alpha1", kind = "Network", metadata.name = "demo", spec = _spec}
}

_base = {region = "westeurope", resourceGroup = "rg-net", cidr = "10.20.0.0/16"}

_names = lambda _spec {
  [_r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _r in network.render(_build(_spec))]
}

_by_name = lambda _spec {
  {_r.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _r for _r in network.render(_build(_spec))}
}

# ---- render: shape ----------------------------------------------------------
test_render_legacy = lambda {
  assert _names(_base) == ["managed", "subnet", "public-ip", "nat-gateway", "nat-gateway-public-ip", "subnet-nat-gateway", "security-group", "subnet-security-group"], "legacy resource names are contract"
  r = _by_name(_base)
  vn = r["managed"]
  assert vn.apiVersion == "network.azure.m.upbound.io/v1beta1", "azure network MRs"
  assert vn.metadata.annotations["crossplane.io/external-name"] == "demo", "VNet named after the XR"
  assert vn.spec.forProvider.addressSpace == ["10.20.0.0/16"], "addressSpace = cidr"
  assert vn.spec.forProvider.location == "westeurope", "location = region"
  assert vn.spec.forProvider.resourceGroupName == "rg-net", "resourceGroupName = spec.resourceGroup"
  sn = r["subnet"]
  assert sn.metadata.annotations["crossplane.io/external-name"] == "demo-westeurope", "legacy subnet is <xr>-<region>"
  assert sn.spec.forProvider.addressPrefixes == ["10.20.0.0/16"], "legacy subnet covers the whole cidr"
  assert sn.spec.forProvider.virtualNetworkNameSelector.matchControllerRef == True, "subnet binds the composed VNet"
}

test_render_subnets = lambda {
  _s = _base | {subnets = [{name = "nodes", cidr = "10.20.0.0/22"}, {name = "Data", cidr = "10.20.4.0/24", secondaryRanges = {pods = "192.168.0.0/16"}}]}
  assert _names(_s) == ["managed", "subnet-nodes", "subnet-data", "public-ip", "nat-gateway", "nat-gateway-public-ip", "subnet-nat-gateway-nodes", "subnet-nat-gateway-data", "security-group", "subnet-security-group-nodes", "subnet-security-group-data"], "subnets-mode resource names are contract"
  r = _by_name(_s)
  assert r["subnet-data"].metadata.annotations["crossplane.io/external-name"] == "Data", "explicit names pinned"
  assert r["subnet-data"].spec.forProvider.addressPrefixes == ["10.20.4.0/24"], "addressPrefixes = [cidr]"
  assert r["subnet-nat-gateway-data"].spec.forProvider.subnetIdSelector.matchLabels == {"network.cloud.example.org/subnet" = "data"}, "association selects its own subnet"
  assert r["subnet-security-group-nodes"].spec.forProvider.subnetIdSelector.matchLabels == {"network.cloud.example.org/subnet" = "nodes"}, "association selects its own subnet"
  assert r["subnet-nodes"].metadata.labels == {"network.cloud.example.org/subnet" = "nodes"}, "subnet carries its selector label"
}

# ---- render: nat ------------------------------------------------------------
test_nat = lambda {
  r = _by_name(_base | {
    tags = {team = "platform"}
  })
  assert r["public-ip"].spec.forProvider.sku == "Standard" and r["public-ip"].spec.forProvider.allocationMethod == "Static", "NAT needs a Standard static IP"
  assert r["nat-gateway"].spec.forProvider.skuName == "Standard", "Standard NAT gateway"
  assert r["nat-gateway"].spec.forProvider.tags == {team = "platform"}, "tags carried"
  assert r["nat-gateway-public-ip"].spec.forProvider.natGatewayIdSelector.matchControllerRef == True, "binds composed NAT"
  off = _names(_base | {natGateway = False})
  assert off == ["managed", "subnet", "security-group", "subnet-security-group"], "natGateway=false drops IP, NAT and associations"
}

# ---- render: nsg ------------------------------------------------------------
test_internal_ingress = lambda {
  assert "security-rule-deny-vnet-inbound" not in _names(_base), "AllowVnetInBound already allows internal traffic"
  r = _by_name(_base | {allowInternalIngress = False})
  fp = r["security-rule-deny-vnet-inbound"].spec.forProvider
  assert fp.access == "Deny" and fp.direction == "Inbound", "deny inbound"
  assert fp.priority == 4000, "priority 4000"
  assert fp.sourceAddressPrefix == "VirtualNetwork", "from the VNet"
  assert fp.networkSecurityGroupNameSelector.matchControllerRef == True, "on the composed NSG"
}

# ---- render: rejections -----------------------------------------------------
test_missing_resource_group = lambda {
  _r = runtime.catch(lambda {
    network.render(_build({region = "westeurope"}))
  })
  assert "spec.resourceGroup is required" in _r, "missing resourceGroup must fail: ${_r}"
}

test_overlap_fails = lambda {
  _r = runtime.catch(lambda {
    network.render(_build(_base | {subnets = [{name = "a", cidr = "10.20.0.0/22"}, {name = "b", cidr = "10.20.2.0/24"}]}))
  })
  assert "network-azure: address plan" in _r and "overlaps" in _r, "overlapping subnets must fail: ${_r}"
}

test_outside_cidr_fails = lambda {
  _r = runtime.catch(lambda {
    network.render(_build(_base | {subnets = [{name = "a", cidr = "10.30.0.0/24"}]}))
  })
  assert "outside the address space" in _r, "subnet outside cidr must fail: ${_r}"
}

test_unaligned_and_duplicate_fail = lambda {
  _a = runtime.catch(lambda {
    network.render(_build(_base | {subnets = [{name = "a", cidr = "10.20.0.1/24"}]}))
  })
  assert "host bits set" in _a, "unaligned cidr must fail: ${_a}"
  _d = runtime.catch(lambda {
    network.render(_build(_base | {subnets = [{name = "a", cidr = "10.20.0.0/24"}, {name = "a", cidr = "10.20.1.0/24"}]}))
  })
  assert "must be unique" in _d, "duplicate names must fail: ${_d}"
}

# ---- render: deletion policy ------------------------------------------------
test_orphan = lambda {
  items = network.render(_build(_base | {deletionPolicy = "Orphan", allowInternalIngress = False}))
  assert all _r in items {
    _r.spec.managementPolicies == _orphan
  }, "Orphan must set managementPolicies on every MR"
  plain = network.render(_build(_base))
  assert all _r in plain {
    _r.spec.managementPolicies == ["*"]
  }, "Delete keeps the default policies"
}

# ---- status -----------------------------------------------------------------
test_status_unobserved = lambda {
  s = network.status(_build(_base), {}).status
  assert s.provider == "azure" and s.ready == False, "not ready until observed"
  assert s?.id == Undefined, "no id before observation"
  assert s.privateSubnetIds == [] and s.securityGroupIds == [] and s.publicSubnetIds == [], "empty lists"
  assert s.subnets == [{name = "demo-westeurope", region = "westeurope", cidr = "10.20.0.0/16"}], "legacy subnet listed"
  assert s.natEnabled == True and s.selfLink == "", "defaults"
}

test_status_observed = lambda {
  _vid = "/subscriptions/s/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/demo"
  _ocds = {
    managed = {Resource.status.atProvider.id = _vid}
    "subnet-nodes" = {Resource.status.atProvider.id = "${_vid}/subnets/nodes"}
    "subnet-data" = {Resource.status.atProvider.id = "${_vid}/subnets/data"}
    "security-group" = {Resource.status.atProvider.id = "/nsg"}
  }
  _s = _base | {natGateway = False, subnets = [{name = "nodes", cidr = "10.20.0.0/22"}, {name = "data", cidr = "10.20.4.0/24"}]}
  s = network.status(_build(_s), _ocds).status
  assert s.ready == True and s.id == _vid, "ready once the VNet has an id"
  assert s.privateSubnetIds == ["${_vid}/subnets/nodes", "${_vid}/subnets/data"], "subnet ids in spec order"
  assert s.subnets[1] == {name = "data", region = "westeurope", cidr = "10.20.4.0/24", id = "${_vid}/subnets/data"}, "subnet entry"
  assert s.securityGroupIds == ["/nsg"], "nsg id"
  assert s.natEnabled == False, "natEnabled"
  assert s["cloud-url"] == "https://portal.azure.com/#@/resource${_vid}", "portal url"
}
