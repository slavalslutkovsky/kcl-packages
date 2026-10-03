# hubspoke (azure) — Crossplane Composition logic (function-kcl module).
# Azure's transit fabric is a Virtual WAN holding a Virtual Hub: the WAN is the
# global container, the hub is the regional router, and every spoke VNet is
# attached by one VirtualHubConnection. The hub is the primary resource, so it
# carries the `managed` composition-resource-name.
#
# Not composed here: the resource group (spec.resourceGroup must already
# exist), the spoke VNets (spokes[].network names ARM ids that already exist),
# Azure Firewall / secured virtual hub, VPN and ExpressRoute gateways, and
# route maps.
#
# spec.summaryCidr and spec.amazonSideAsn are AWS-only and are ignored here:
# Virtual WAN owns the connection's routing on both sides, so there is no
# spoke-side route for this module to install and no BGP ASN to pin.
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_w_a_n as vwan
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub as vhub
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_route_table as vhubrt
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_connection as vhubconn

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The only Virtual Hub sku Azure offers; pinned rather than exposed, because a
# hub with another value is not a thing that can be created.
hub_sku = "Standard"

# The isolated hub route table's own label. Azure route-table labels are the
# grouping key a connection may propagate into by name instead of by id; this
# one exists so the table is identifiable in the portal and in az output.
# It is the MR's [str] label list, not Kubernetes metadata.labels.
isolated_route_table_labels = ["isolated"]

# composition-resource-names. Renaming a composed resource makes Crossplane
# delete and recreate it, so these strings are contract, not decoration.
hub_resource = "managed"
wan_resource = "wan"
isolated_route_table_resource = "route-table-isolated"

# spokes[].name is a DNS-1123 label of at most 40 characters (the XRD enforces
# the pattern), so it is used verbatim — there is nothing to sanitize.
connection_resource = lambda spoke_name: str -> str {
    "connection-${spoke_name}"
}

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow a
# legitimate False, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Observed state of a composed resource; Undefined until the first reconcile.
_at = lambda ocds, res: str -> any {
    (ocds[res]?.Resource?.status?.atProvider) if res in (ocds or {}) else Undefined
}

# The hub's own default route table, assigned by Azure when the hub is created.
_default_route_table_id = lambda ocds -> str {
    _at(ocds, hub_resource)?.defaultRouteTableId or ""
}

# The custom table composed for isolated topology, once it exists.
_isolated_route_table_id = lambda ocds -> str {
    _at(ocds, isolated_route_table_resource)?.id or ""
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _spokes = _spec.spokes
    _topology = _spec?.topology or "mesh"
    _mesh = _topology == "mesh"
    _rg = _spec?.resourceGroup
    _cidr = _spec?.hubCidr
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently pretending a field took effect.
    assert _rg, "hubspoke-azure: spec.resourceGroup is required — name the existing resource group the Virtual WAN and the Virtual Hub are created in; this XR does not create it"
    assert _cidr, "hubspoke-azure: spec.hubCidr is required — a Virtual Hub runs routers that need their own addresses; give it a /23 or larger that overlaps no spoke"

    # Two spokes sharing a name would collapse onto one composed resource and
    # one of them would silently never be attached.
    assert len({_s.name: "" for _s in _spokes}) == len(_spokes), "hubspoke-azure: spokes[].name must be unique — two spokes with the same name become one connection and the other VNet is never attached; rename the duplicate"
    # Isolated with no shared spoke is a hub where nothing may reach anything.
    assert _mesh or any _s in _spokes {
        _flag(_s?.shared, False)
    }, "hubspoke-azure: topology 'isolated' needs at least one spoke with shared: true — otherwise no spoke may reach any other; mark the shared-services VNet, or use topology 'mesh'"

    # 1) The Virtual WAN. Branch-to-branch is the WAN-wide switch that lets
    # anything attached to the hub reach anything else attached to it; in
    # isolated topology the route tables do the deciding, so it stays off.
    _items: [any] = [vwan.VirtualWAN {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = wan_resource}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.allowBranchToBranchTraffic = _mesh
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) The Virtual Hub — the router every spoke connects to, and the
    # resource this XR's status is read from.
    _items += [vhub.VirtualHub {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = hub_resource}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.virtualWanIdSelector.matchControllerRef = True
        spec.forProvider.addressPrefix = _cidr
        spec.forProvider.sku = hub_sku
        spec.forProvider.branchToBranchTrafficEnabled = _mesh
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 3) Isolated topology composes one extra hub route table. Workload spokes
    # associate with it instead of the default one, so the only routes they
    # learn are the ones this table carries.
    if not _mesh:
        _items += [vhubrt.VirtualHubRouteTable {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = isolated_route_table_resource}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.virtualHubIdSelector.matchControllerRef = True
            spec.forProvider.labels = isolated_route_table_labels
        }]

    # 4) One connection per spoke VNet. internetSecurityEnabled would send the
    # spoke's default route into the hub for inspection, which needs a secured
    # hub (Azure Firewall) this XR does not compose.
    _default_rt = _default_route_table_id(ocds)
    _isolated_rt = _isolated_route_table_id(ocds)

    # Reachability, and why the two route tables produce it:
    #   workload (shared: false) associates with the isolated table — so it
    #   learns only what propagates into that table, which is the shared
    #   spokes — and propagates its own routes into the default table.
    #   shared (shared: true) associates with the default table — so it learns
    #   every spoke — and propagates into both tables, which is what puts the
    #   shared prefixes in front of the workload spokes.
    # Nothing propagates a workload spoke into the isolated table, so two
    # workload spokes never learn a route to each other.
    _routing = lambda shared: bool -> any {
        {
            associatedRouteTableId = _default_rt if shared else _isolated_rt
            propagatedRouteTable.routeTableIds = [_default_rt, _isolated_rt] if shared else [_default_rt]
        }
    }

    _connection = lambda spoke: any -> any {
        vhubconn.VirtualHubConnection {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = connection_resource(spoke.name)}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.virtualHubIdSelector.matchControllerRef = True
            spec.forProvider.remoteVirtualNetworkId = spoke.network
            spec.forProvider.internetSecurityEnabled = False
            # mesh carries no routing block on purpose: a connection with none
            # associates with the hub's default route table and propagates
            # into it, which is Azure's own full mesh.
            if not _mesh:
                spec.forProvider.routing = _routing(_flag(spoke?.shared, False))
        }
    }

    # SECOND PASS. Both route table ids are assigned by Azure — the default
    # one when the hub is created, the custom one when the table is — so in
    # isolated topology the connections cannot be written until both have been
    # observed. Rendering them early without a routing block is not a harmless
    # approximation: Azure would read that as the default association and
    # propagation, and every spoke would briefly reach every other one.
    if _mesh or (_default_rt and _isolated_rt):
        _items += [_connection(_s) for _s in _spokes]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _spokes = _spec.spokes
    _topology = _spec?.topology or "mesh"
    _o = ocds or {}

    _hub = _at(_o, hub_resource)
    _hub_id = _hub?.id or ""
    _default_rt = _hub?.defaultRouteTableId or ""
    _isolated_rt = _isolated_route_table_id(_o)

    # One row per spec spoke, in spec order — a spoke that has no connection
    # yet still has to appear, otherwise a half-built hub looks smaller than
    # it was asked to be.
    _row = lambda spoke: any -> any {
        _id = _at(_o, connection_resource(spoke.name))?.id or ""
        {
            name = spoke.name
            network = spoke.network
            shared = _flag(spoke?.shared, False)
            attached = _id != ""
            if _id:
                id = _id
        }
    }
    _rows = [_row(_s) for _s in _spokes]
    _attached = len([_r for _r in _rows if _r.attached])

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "NetworkHub"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            topology = _topology
            # A hub with half its spokes attached is not a topology.
            ready = _hub_id != "" and _attached == len(_spokes)
            hubName = oxr.metadata.name
            if _hub_id:
                hubId = _hub_id
            # status.hubState is omitted: the generated VirtualHub schema
            # observes no provisioning state, and inventing one would be a lie.
            if _default_rt:
                defaultRouteTableId = _default_rt
            # Hub-side tables this XR composed. Mesh composes none — the
            # hub's own default table does the work.
            if _isolated_rt:
                routeTableIds = [_isolated_rt]
            spokeCount = len(_spokes)
            attachedCount = _attached
            spokes = _rows
            "cloud-url" = "https://portal.azure.com/#@/resource${_hub_id}/overview" if _hub_id else "https://portal.azure.com/#browse/Microsoft.Network%2FvirtualWans"
        }
    }
}
