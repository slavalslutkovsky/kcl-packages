# network (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-network schema package. The portable Network becomes
# a VirtualNetwork over spec.cidr in an existing resource group, its Subnets,
# a NAT Gateway (with one Standard static Public IP) associated with every
# subnet for managed egress, and one Network Security Group associated with
# every subnet. The VirtualNetwork is the primary resource, so it carries the
# `managed` composition-resource-name; a NetworkHub attaches it by the ARM id
# published as status.id.
#
# Two address-plan modes, as on gcp:
#   - legacy (no spec.subnets): one Subnet `<xr-name>-<region>` over the whole
#     of spec.cidr.
#   - subnets (spec.subnets set): spec.cidr is the VNet address space, and
#     every spec.subnets entry becomes a named Subnet over its primary cidr,
#     validated (aligned IPv4, inside cidr, no overlaps, unique names).
#
# Not composed here: the resource group (spec.resourceGroup must exist).
#
# Ignored on Azure (documented, never failed on): subnetPrefixLength,
# availabilityZones, publicSubnets, databaseSubnetGroups (AWS subnet carving
# and subnet groups; Azure subnets are regional and data services delegate or
# use private endpoints), serviceRange, servicePeering, privateGoogleAccess
# (GCP private service access), subnets[].secondaryRanges (AKS Azure CNI
# Overlay takes pod/service CIDRs outside the VNet, so they are neither
# composed nor checked against cidr) and subnets[].flowLogSampling (VNet flow
# logs need a Network Watcher and storage account this XR does not own).
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network as vnet
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet as subnet
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_public_ip as pip
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_n_a_t_gateway as natgw
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_n_a_t_gateway_public_ip_association as natpip
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_n_a_t_gateway_association as subnatgw
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_security_group as nsg
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_security_rule as nsgrule
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_network_security_group_association as subnsg
import network_xrd.models.unknown as xrd

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# composition-resource-names. Renaming a composed resource makes Crossplane
# delete and recreate it, so these strings are contract, not decoration.
_vnet_resource = "managed"
_public_ip_resource = "public-ip"
_nat_gateway_resource = "nat-gateway"
_nat_gateway_public_ip_resource = "nat-gateway-public-ip"
_security_group_resource = "security-group"
_deny_vnet_inbound_resource = "security-rule-deny-vnet-inbound"

# Priority of the rule that overrides AllowVnetInBound (65000) when
# allowInternalIngress is off. Low enough to leave 100..3999 for operators.
_deny_vnet_inbound_priority = 4000

# Label each Subnet carries so the per-subnet associations select exactly one:
# with several Subnets under one XR, matchControllerRef alone is ambiguous.
_subnet_label = "network.cloud.example.org/subnet"

# ---- address plan -----------------------------------------------------------
_octet_ok = lambda o: str -> bool {
  o.isdigit() and len(o) <= 3 and int(o) <= 255
}

# Parse a labelled IPv4 CIDR into its first and last address as integers.
# Azure rejects a prefix with host bits set at apply time; failing the render
# says so before the provider does.
cidr_range = lambda cidr: str, label: str -> {str:any} {
  _parts = cidr.split("/")
  _octets = _parts[0].split(".") if len(_parts) == 2 else []
  _valid = len(_octets) == 4 and all o in _octets {
    _octet_ok(o)
  } and _parts[1].isdigit() and len(_parts[1]) <= 2 and int(_parts[1]) <= 32
  assert _valid, "network-azure: ${label} (${cidr}) is not an IPv4 CIDR"
  _bits = int(_parts[1])
  _start = ((int(_octets[0]) * 256 + int(_octets[1])) * 256 + int(_octets[2])) * 256 + int(_octets[3])
  _size = 1 << (32 - _bits)
  assert _start % _size == 0, "network-azure: ${label} (${cidr}): host bits set; the network address is not aligned to /${_bits}"
  {label = label, cidr = cidr, start = _start, end = _start + _size - 1}
}

# Composition-resource-name suffix / label value for a subnet name.
slug = lambda s: str -> str {
  "".join([c if c in "abcdefghijklmnopqrstuvwxyz0123456789-" else "-" for c in s.lower()])
}

# The XR spec, typed against the network-xrd schemas (XRD defaults, enums and
# bounds apply). spec.crossplane is left out: Crossplane writes fields there
# the generated schema does not declare, and this module never reads it.
typed_spec = lambda oxr -> xrd.NetworkSpec {
  {_k: _v for _k, _v in oxr.spec if _k != "crossplane"}
}

# One resolved subnet. `key` is the composition-resource-name suffix: "" for
# the legacy single subnet, "-<slug(name)>" in subnets mode.
schema Subnet:
  name: str
  region: str
  cidr: str
  key: str

# Every Subnet to compose, in spec order; legacy mode yields the one over cidr.
resolve_subnets = lambda xr_name: str, spec: xrd.NetworkSpec -> [Subnet] {
  [Subnet {
    name = _s.name or "${xr_name}-${spec.region}"
    region = _s.region or spec.region
    cidr = _s.cidr
    key = "-${slug(name)}"
  } for _s in spec.subnets] if spec.subnets else [Subnet {name = "${xr_name}-${spec.region}", region = spec.region, cidr = spec.cidr, key = ""}]
}

# Check the address plan. Only primary ranges count on Azure: secondaryRanges
# are ignored (see the header), so they are neither composed nor validated.
validate_plan = lambda spec: xrd.NetworkSpec, subs: [Subnet] -> [{str:any}] {
  _names = [_s.name for _s in subs]
  _dupes = [_n for _i, _n in _names if _n in _names[:_i:]]
  assert not _dupes, "network-azure: subnet names must be unique; duplicated: ${', '.join(_dupes)}"
  _slugs = [slug(_n) for _n in _names]
  _clashes = [_n for _i, _n in _slugs if _n in _slugs[:_i:]]
  assert not _clashes, "network-azure: subnet names collide after slugging into composition-resource-names: ${', '.join(_clashes)}"
  _elsewhere = ["${_s.name} (${_s.region})" for _s in subs if _s.region != spec.region]
  assert not _elsewhere, "network-azure: a VirtualNetwork is regional; subnets ${', '.join(_elsewhere)} must be in spec.region (${spec.region})"
  _block = cidr_range(spec.cidr, "address space cidr")
  _ranges = [cidr_range(_s.cidr, "subnet ${_s.name}") for _s in subs]
  _outside = ["${_r.label} (${_r.cidr})" for _r in _ranges if _r.start < _block.start or _r.end > _block.end]
  assert not _outside, "network-azure: address plan: ${', '.join(_outside)} outside the address space cidr (${_block.cidr})"
  _overlaps = ["${_a.label} (${_a.cidr}) overlaps ${_b.label} (${_b.cidr})" for _i, _a in _ranges for _j, _b in _ranges if _i < _j and _a.start <= _b.end and _b.start <= _a.end]
  assert not _overlaps, "network-azure: address plan: ${'; '.join(_overlaps)}"
  _ranges
}

render = lambda oxr {
  _spec = typed_spec(oxr)
  _name = oxr.metadata.name
  _rg = _spec.resourceGroup
  assert _rg, "network-azure: spec.resourceGroup is required (the existing Resource Group the VirtualNetwork and its subnets, NAT Gateway and Network Security Group live in; this XR does not create it)"
  _loc = _spec.region
  _tags = _spec.tags
  _mp = _orphan_policies if _spec.deletionPolicy == "Orphan" else Undefined

  _subs = resolve_subnets(_name, _spec)
  validate_plan(_spec, _subs)

  # 1) The VNet, named after the XR so status.name is known up front.
  _items: [any] = [vnet.VirtualNetwork {
    metadata.annotations = {
      "krm.kcl.dev/composition-resource-name" = _vnet_resource
      "crossplane.io/external-name" = _name
    }
    if _mp:
      spec.managementPolicies = _mp
    spec.forProvider.location = _loc
    spec.forProvider.resourceGroupName = _rg
    spec.forProvider.addressSpace = [_spec.cidr]
    if _tags:
      spec.forProvider.tags = _tags
  }]

  # 2) Subnets. Subnet has no tags field — spec.tags is dropped.
  _items += [subnet.Subnet {
    metadata.annotations = {
      "krm.kcl.dev/composition-resource-name" = "subnet${_s.key}"
      "crossplane.io/external-name" = _s.name
    }
    metadata.labels = {"${_subnet_label}" = slug(_s.name)}
    if _mp:
      spec.managementPolicies = _mp
    spec.forProvider.resourceGroupName = _rg
    spec.forProvider.addressPrefixes = [_s.cidr]
    spec.forProvider.virtualNetworkNameSelector = {matchControllerRef = True}
  } for _s in _subs]

  # 3) Managed egress: one NAT Gateway with one static Standard Public IP,
  # associated with every subnet.
  if _spec.natGateway:
    _items += [
      pip.PublicIP {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _public_ip_resource}
        if _mp:
          spec.managementPolicies = _mp
        spec.forProvider.location = _loc
        spec.forProvider.resourceGroupName = _rg
        # A NAT Gateway only takes Standard, statically allocated addresses.
        spec.forProvider.sku = "Standard"
        spec.forProvider.allocationMethod = "Static"
        if _tags:
          spec.forProvider.tags = _tags
      }
      natgw.NATGateway {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _nat_gateway_resource}
        if _mp:
          spec.managementPolicies = _mp
        spec.forProvider.location = _loc
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.skuName = "Standard"
        if _tags:
          spec.forProvider.tags = _tags
      }
      natpip.NATGatewayPublicIPAssociation {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _nat_gateway_public_ip_resource}
        if _mp:
          spec.managementPolicies = _mp
        spec.forProvider.natGatewayIdSelector = {matchControllerRef = True}
        spec.forProvider.publicIpAddressIdSelector = {matchControllerRef = True}
      }
    ]
    _items += [subnatgw.SubnetNATGatewayAssociation {
      metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "subnet-nat-gateway${_s.key}"}
      if _mp:
        spec.managementPolicies = _mp
      spec.forProvider.natGatewayIdSelector = {matchControllerRef = True}
      spec.forProvider.subnetIdSelector = {matchControllerRef = True, matchLabels = {"${_subnet_label}" = slug(_s.name)}}
    } for _s in _subs]

  # 4) One Network Security Group for every subnet. Azure's default
  # AllowVnetInBound rule (priority 65000) already admits traffic from inside
  # the VNet, so allowInternalIngress=true needs no rule of its own; false adds
  # a deny from VirtualNetwork ahead of it.
  _items += [nsg.SecurityGroup {
    metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _security_group_resource}
    if _mp:
      spec.managementPolicies = _mp
    spec.forProvider.location = _loc
    spec.forProvider.resourceGroupName = _rg
    if _tags:
      spec.forProvider.tags = _tags
  }]
  if not _spec.allowInternalIngress:
    _items += [nsgrule.SecurityRule {
      metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _deny_vnet_inbound_resource}
      if _mp:
        spec.managementPolicies = _mp
      spec.forProvider = {
        resourceGroupName = _rg
        networkSecurityGroupNameSelector = {matchControllerRef = True}
        direction = "Inbound"
        access = "Deny"
        priority = _deny_vnet_inbound_priority
        $protocol = "*"
        sourceAddressPrefix = "VirtualNetwork"
        sourcePortRange = "*"
        destinationAddressPrefix = "VirtualNetwork"
        destinationPortRange = "*"
      }
    }]

  _items += [subnsg.SubnetNetworkSecurityGroupAssociation {
    metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "subnet-security-group${_s.key}"}
    if _mp:
      spec.managementPolicies = _mp
    spec.forProvider.networkSecurityGroupIdSelector = {matchControllerRef = True}
    spec.forProvider.subnetIdSelector = {matchControllerRef = True, matchLabels = {"${_subnet_label}" = slug(_s.name)}}
  } for _s in _subs]

  _items
}

# Observed state of a composed resource; Undefined until the first reconcile.
_at = lambda ocds, res: str -> any {
  (ocds[res]?.Resource?.status?.atProvider) if res in (ocds or {}) else Undefined
}

# One status.subnets entry; id only once the Subnet is observed.
subnet_status = lambda s: Subnet, sid: str -> {str:any} {
  {
    name = s.name
    region = s.region
    cidr = s.cidr
    if sid:
      id = sid
  }
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
  _spec = typed_spec(oxr)
  _name = oxr.metadata.name
  _o = ocds or {}

  _id = _at(_o, _vnet_resource)?.id or ""
  _nsg_id = _at(_o, _security_group_resource)?.id or ""

  _subnets = [subnet_status(_s, _at(_o, "subnet${_s.key}")?.id or "") for _s in resolve_subnets(_name, _spec)]

  {
    apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
    kind = oxr?.kind or "Network"
    metadata.name = _name
    status = {
      provider = "azure"
      ready = _id != ""
      if _id:
        id = _id
      name = _name
      # Azure has no self link; the ARM id in status.id is the reference.
      selfLink = ""
      region = _spec.region
      cidr = _spec.cidr
      privateSubnetIds = [_e.id for _e in _subnets if _e?.id]
      publicSubnetIds = []
      securityGroupIds = [_nsg_id] if _nsg_id else []
      subnets = _subnets
      natEnabled = _spec.natGateway
      "cloud-url" = "https://portal.azure.com/#@/resource${_id}" if _id else "https://portal.azure.com/#browse/Microsoft.Network%2FvirtualNetworks"
    }
  }
}
