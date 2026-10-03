import .hub

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` / `ocds`
# parameters — KCL normalizes the leading underscore, so a helper named
# `_ocds` shadows it.
_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "NetworkHub"
        metadata = {name = "demo", namespace = "apps"}
        spec = extra
    }
}

_vnet = lambda name: str -> str {
    "/subscriptions/000/resourceGroups/${name}-rg/providers/Microsoft.Network/virtualNetworks/${name}-vnet"
}

# The smallest spec the XRD accepts on this backend. XRD defaults are absent
# here on purpose: a unit-tested XR never went through the API server, so
# topology, shared and deletionPolicy must be re-defaulted by the module.
_spokes = [
    {name = "shared-services", network = _vnet("shared"), shared = True}
    {name = "team-a", network = _vnet("team-a")}
    {name = "team-b", network = _vnet("team-b")}
]
_mesh_spec = {region = "westeurope", resourceGroup = "platform-rg", hubCidr = "10.200.0.0/23", spokes = _spokes}
_iso_spec = _mesh_spec | {topology = "isolated"}

_with = lambda extra: any -> any {
    _mesh_spec | extra
}

_names = lambda items: any -> any {
    [_i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _i in items]
}

_pick = lambda items: any, name: str -> any {
    _hits = [_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name]
    _hits[0] if _hits else Undefined
}

# ---- observed state ---------------------------------------------------------
_hub_id = "/subscriptions/000/resourceGroups/platform-rg/providers/Microsoft.Network/virtualHubs/demo"
_default_rt = "${_hub_id}/hubRouteTables/defaultRouteTable"
_iso_rt = "${_hub_id}/hubRouteTables/isolated"

_conn_id = lambda name: str -> str {
    "${_hub_id}/hubVirtualNetworkConnections/${name}"
}

_observed = lambda res: str, at: any -> any {
    {
        "${res}" = {
            Resource = {
                status = {atProvider = at}
            }
        }
    }
}

# The hub, once reconciled: Azure assigns both the hub id and the id of the
# default route table it creates alongside it.
_seen_hub = _observed("managed", {id = _hub_id, defaultRouteTableId = _default_rt})

# ...and the composed isolated table, once it exists.
_seen_tables = _seen_hub | _observed("route-table-isolated", {id = _iso_rt})

_seen_connections = _seen_tables | _observed("connection-shared-services", {id = _conn_id("shared-services")}) | _observed("connection-team-a", {id = _conn_id("team-a")}) | _observed("connection-team-b", {id = _conn_id("team-b")})

# ---- render: mesh -----------------------------------------------------------

# mesh needs no observed state at all: the WAN, the hub and every connection
# are fully determined by the spec.
test_render_mesh = lambda {
    items = hub.render(_build(_mesh_spec), {})
    assert _names(items) == ["wan", "managed", "connection-shared-services", "connection-team-a", "connection-team-b"], "mesh composes the WAN, the hub and one connection per spoke, in spec order, and no route table"
    assert [_i.kind for _i in items] == ["VirtualWAN", "VirtualHub", "VirtualHubConnection", "VirtualHubConnection", "VirtualHubConnection"], "wrong kinds"
    assert all _i in items {
        _i.metadata?.namespace == Undefined
    }, "composed resources carry no namespace — Crossplane places them"
    assert _pick(items, "wan").spec.forProvider.allowBranchToBranchTraffic == True, "mesh is branch-to-branch traffic across the WAN"
    assert _pick(items, "managed").spec.forProvider.branchToBranchTrafficEnabled == True, "mesh lets the hub forward between its own connections"
    assert all _c in [_i for _i in items if _i.kind == "VirtualHubConnection"] {
        _c.spec.forProvider?.routing == Undefined
    }, "a mesh connection carries no routing block: the default association and propagation IS the full mesh, and writing it out would pin ids Azure owns"
    conn = _pick(items, "connection-team-a").spec.forProvider
    assert conn.virtualHubIdSelector.matchControllerRef == True, "a connection must bind its own hub by controller ref"
    assert conn.remoteVirtualNetworkId == _vnet("team-a"), "spokes[].network is the VNet the connection attaches"
    assert conn.internetSecurityEnabled == False, "sending the spoke's default route into the hub needs a secured hub (Azure Firewall), which this XR does not compose"
}

# The hub's own inputs, and the tags that only the WAN and the hub carry.
test_hub_mapping = lambda {
    items = hub.render(_build(_with({
        tags = {team = "platform"}
    })), {})
    wan = _pick(items, "wan").spec.forProvider
    hub_fp = _pick(items, "managed").spec.forProvider
    assert wan.location == "westeurope" and hub_fp.location == "westeurope", "region -> Virtual WAN and Virtual Hub location"
    assert wan.resourceGroupName == "platform-rg" and hub_fp.resourceGroupName == "platform-rg", "both land in the existing resource group"
    assert hub_fp.virtualWanIdSelector.matchControllerRef == True, "the hub must bind its own WAN by controller ref"
    assert hub_fp.addressPrefix == "10.200.0.0/23", "hubCidr is the address space the hub's routers live in"
    assert hub_fp.sku == "Standard", "Standard is the only Virtual Hub sku"
    assert wan.tags == {team = "platform"} and hub_fp.tags == {team = "platform"}, "tags -> WAN and hub tags"
    untagged = hub.render(_build(_mesh_spec), {})
    assert _pick(untagged, "wan").spec.forProvider?.tags == Undefined, "no tags unless asked for"
    assert _pick(untagged, "managed").spec.forProvider?.tags == Undefined, "no tags unless asked for"
}

# Rejected, and not assertable from here: a spec without resourceGroup or
# without hubCidr aborts render() with a fatal assert, because the group
# cannot be created here and the hub's routers cannot go without addresses.

# ---- render: isolated -------------------------------------------------------

# Before Azure has reported either route table id there is nothing to write a
# routing block from, and a connection without one would be a full mesh.
test_render_isolated_pre_observation = lambda {
    items = hub.render(_build(_iso_spec), {})
    assert _names(items) == ["wan", "managed", "route-table-isolated"], "isolated composes its extra hub route table immediately, but holds the connections back: rendering them now (with no routing block) would make Azure associate and propagate them into the default table and every spoke would reach every other one"
    assert _pick(items, "wan").spec.forProvider.allowBranchToBranchTraffic == False, "isolated must not let the WAN forward branch to branch behind the route tables' back"
    assert _pick(items, "managed").spec.forProvider.branchToBranchTrafficEnabled == False, "isolated must not let the hub forward between connections on its own"
    rt = _pick(items, "route-table-isolated").spec.forProvider
    assert rt.virtualHubIdSelector.matchControllerRef == True, "the route table must bind its own hub by controller ref"
    assert rt.labels == ["isolated"], "the MR's own route-table label list, which is how a connection may name a table instead of quoting its id"

    # Half-observed is still not enough: the isolated table's id is the other
    # half of every routing block.
    half = hub.render(_build(_iso_spec), _seen_hub)
    assert _names(half) == ["wan", "managed", "route-table-isolated"], "the hub's default route table id alone cannot produce a routing block — the isolated table's id is missing"
}

# Both ids observed: the connections appear, and the two roles get opposite
# associations. This is the whole topology.
test_render_isolated_observed = lambda {
    items = hub.render(_build(_iso_spec), _seen_tables)
    assert _names(items) == ["wan", "managed", "route-table-isolated", "connection-shared-services", "connection-team-a", "connection-team-b"], "with both route table ids observed every spoke gets its connection"
    workload = _pick(items, "connection-team-a").spec.forProvider.routing
    shared = _pick(items, "connection-shared-services").spec.forProvider.routing
    assert workload.associatedRouteTableId == _iso_rt, "a workload spoke associates with the isolated table, so it learns only what propagates into it"
    assert workload.propagatedRouteTable.routeTableIds == [_default_rt], "a workload spoke's own routes reach the default table only"
    assert shared.associatedRouteTableId == _default_rt, "a shared spoke associates with the default table, so it learns every spoke"
    assert shared.propagatedRouteTable.routeTableIds == [_default_rt, _iso_rt], "a shared spoke propagates into both tables — that is what puts shared prefixes in front of the workload spokes"
    assert _pick(items, "connection-team-b").spec.forProvider.routing == workload, "shared: false is the default, so an unmarked spoke is a workload spoke"

    # Reachability, read off the blocks above: team-a learns only the routes in
    # the isolated table, and only shared-services propagates into it.
    assert not (_iso_rt in workload.propagatedRouteTable.routeTableIds), "no workload spoke may propagate into the isolated table, or two workload spokes would learn each other"

    # Rejected, and not assertable from here: topology 'isolated' with every
    # spoke shared: false aborts render() — a hub where nothing may reach
    # anything is not built.
    ok = hub.render(_build(_iso_spec | {spokes = [{name = "only", network = _vnet("only"), shared = True}]}), _seen_tables)
    assert _names(ok) == ["wan", "managed", "route-table-isolated", "connection-only"], "one shared spoke is enough for isolated to be accepted"
}

# ---- render: fan-out --------------------------------------------------------
test_spoke_fanout = lambda {
    one = hub.render(_build(_with({spokes = [{name = "solo", network = _vnet("solo")}]})), {})
    assert _names(one) == ["wan", "managed", "connection-solo"], "one spoke, one connection"
    grown = hub.render(_build(_mesh_spec), {})
    assert len([_i for _i in grown if _i.kind == "VirtualHubConnection"]) == 3, "three spokes, three connections"
    assert [_i.spec.forProvider.remoteVirtualNetworkId for _i in grown if _i.kind == "VirtualHubConnection"] == [_vnet("shared"), _vnet("team-a"), _vnet("team-b")], "each connection attaches its own spoke's VNet, in spec order"
}

# Rejected, and not assertable from here: two spokes sharing a name abort
# render(), because both would want the same composition-resource-name and
# one VNet would silently never be attached.

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    orphaned = hub.render(_build(_iso_spec | {deletionPolicy = "Orphan"}), _seen_tables)
    assert len(orphaned) == 6, "the policy must be checked on the full isolated resource set"
    assert all _i in orphaned {
        _i.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every managed resource"
    deleted = hub.render(_build(_iso_spec), _seen_tables)
    assert all _i in deleted {
        not (_i.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------
test_status_pre_observation = lambda {
    dxr = hub.status(_build(_mesh_spec), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "NetworkHub", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must address the composite"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.topology == "mesh", "topology must be re-defaulted to mesh"
    assert dxr.status.ready == False, "nothing is connected before the hub exists"
    assert dxr.status.hubName == "demo", "the hub is named after the XR"
    assert dxr.status?.hubId == Undefined, "no hub id before the hub exists"
    assert dxr.status?.hubState == Undefined, "the generated VirtualHub schema observes no provisioning state"
    assert dxr.status?.defaultRouteTableId == Undefined, "Azure assigns the default route table with the hub"
    assert dxr.status?.routeTableIds == Undefined, "mesh composes no hub route table of its own"
    assert dxr.status.spokeCount == 3, "spokeCount comes from the spec and is known ahead of creation"
    assert dxr.status.attachedCount == 0, "nothing is attached yet"
    assert dxr.status.spokes == [
        {name = "shared-services", network = _vnet("shared"), shared = True, attached = False}
        {name = "team-a", network = _vnet("team-a"), shared = False, attached = False}
        {name = "team-b", network = _vnet("team-b"), shared = False, attached = False}
    ], "every spec spoke must be reported in spec order, with shared re-defaulted and no id until one is observed"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#browse/Microsoft.Network%2FvirtualWans", "without an observed hub id the console link is the Virtual WAN list"
}

test_status_partially_attached = lambda {
    dxr = hub.status(_build(_mesh_spec), _seen_hub | _observed("connection-team-a", {id = _conn_id("team-a")}))
    assert dxr.status.ready == False, "a hub with one of three spokes attached is not a topology"
    assert dxr.status.hubId == _hub_id, "the observed hub id must be surfaced"
    assert dxr.status.defaultRouteTableId == _default_rt, "the hub's own default route table must be surfaced"
    assert dxr.status.attachedCount == 1, "only the observed connection counts as attached"
    assert dxr.status.spokes[1] == {name = "team-a", network = _vnet("team-a"), shared = False, attached = True, id = _conn_id("team-a")}, "an observed connection carries its id and flips attached"
    assert dxr.status.spokes[0]?.id == Undefined, "a spoke with no observed connection reports no id"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource${_hub_id}/overview", "an observed hub id must land in the portal blade link"
}

test_status_fully_attached = lambda {
    dxr = hub.status(_build(_iso_spec), _seen_connections)
    assert dxr.status.ready == True, "the hub exists and every spoke is attached"
    assert dxr.status.topology == "isolated", "topology must be reported as configured"
    assert dxr.status.attachedCount == 3 and dxr.status.spokeCount == 3, "attachedCount equals spokeCount when ready"
    assert dxr.status.routeTableIds == [_iso_rt], "the isolated table is the only hub-side table this XR composed"
    assert [_s.id for _s in dxr.status.spokes] == [_conn_id("shared-services"), _conn_id("team-a"), _conn_id("team-b")], "every connection id must be surfaced, in spec order"
    assert [_s.shared for _s in dxr.status.spokes] == [True, False, False], "the shared flag distinguishes the shared-services spoke"
    hubless = hub.status(_build(_iso_spec), _seen_connections | _observed("managed", {defaultRouteTableId = _default_rt}))
    assert hubless.status.ready == False, "every spoke attached but no hub id is not ready — there is no hub to be attached to"
}
