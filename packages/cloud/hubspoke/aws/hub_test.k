import .hub

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# One shared-services spoke, one workload spoke with two of its own route
# tables, one workload spoke with none.
_spokes = [
    {
        name = "shared-services"
        network = "vpc-0sh11bb22cc33dd44"
        subnets = ["subnet-0sh1", "subnet-0sh2"]
        routeTableIds = ["rtb-0sh1"]
        shared = True
    }
    {
        name = "team-a"
        network = "vpc-0aa11bb22cc33dd44"
        subnets = ["subnet-0aa1"]
        routeTableIds = ["rtb-0aa1", "rtb-0aa2"]
    }
    {
        name = "team-b"
        network = "vpc-0bb11bb22cc33dd44"
        subnets = ["subnet-0bb1"]
    }
]

_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "NetworkHub"
        metadata = {name = "demo", namespace = "apps"}
        spec = {region = "eu-west-1", spokes = _spokes} | extra
    }
}

_render = lambda extra: any -> any {
    hub.render(_build(extra))
}

# The composition-resource-names of a render, in render order.
_names = lambda items: any -> any {
    [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in items]
}

# One composed resource by its composition-resource-name.
_pick = lambda items: any, name: str -> any {
    _hits = [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name]
    _hits[0] if _hits else Undefined
}

_res = lambda extra: any, name: str -> any {
    _pick(_render(extra), name)
}

# Composed resources of `kind` that a selector's matchLabels would find.
_candidates = lambda items: any, kind: str, labels: any -> int {
    len([i for i in items if i.kind == kind and all _k, _v in labels {
        i.metadata?.labels?[_k] == _v
    }])
}

# Who a spoke can reach, derived from the render alone: the hub route table its
# association points at, and every spoke whose attachment propagates into that
# same table.
_reach = lambda items: any, name: str -> any {
    _table = _pick(items, "association-${name}").spec.forProvider.transitGatewayRouteTableIdSelector.matchLabels[hub.hub_table_label]
    sorted([i.spec.forProvider.transitGatewayAttachmentIdSelector.matchLabels[hub.spoke_label] for i in items if i.kind == "TransitGatewayRouteTablePropagation" and i.spec.forProvider.transitGatewayRouteTableIdSelector.matchLabels[hub.hub_table_label] == _table])
}

# Observed state of one composed resource, in the shape function-kcl hands over.
_observed = lambda name: str, at: any -> any {
    {
        "${name}" = {Resource.status.atProvider = at}
    }
}

_observed_hub = _observed("managed", {
    id = "tgw-0abc123"
    arn = "arn:aws:ec2:eu-west-1:111122223333:transit-gateway/tgw-0abc123"
    associationDefaultRouteTableId = "tgw-rtb-0default"
})
_observed_tables = _observed("route-table-shared", {id = "tgw-rtb-0shared"}) | _observed("route-table-isolated", {id = "tgw-rtb-0isolated"})
_observed_attachments = _observed("attachment-shared-services", {id = "tgw-attach-0sh"}) | _observed("attachment-team-a", {id = "tgw-attach-0aa"}) | _observed("attachment-team-b", {id = "tgw-attach-0bb"})

# ---- render: mesh ------------------------------------------------------------

# mesh composes no routing of its own: the gateway's default route table
# associates and propagates every attachment, which is what makes every spoke
# reach every other spoke.
test_mesh_resource_set = lambda {
    items = _render({})
    names = _names(items)
    assert names == [
        "managed"
        "attachment-shared-services"
        "attachment-team-a"
        "attachment-team-b"
        "route-shared-services-0"
        "route-team-a-0"
        "route-team-a-1"
    ], "mesh renders the gateway, one attachment per spoke and one route per spokes[].routeTableIds entry — and nothing else"
    assert all i in items {
        i.metadata?.namespace == Undefined
    }, "composed resources must carry no namespace — Crossplane places them"
    assert all n in names {
        not n.startswith("route-table-") and not n.startswith("association-") and not n.startswith("propagation-")
    }, "mesh must compose no hub route table: the default one already associates and propagates everything"
}

test_mesh_gateway = lambda {
    gw = _res({}, "managed")
    assert gw.kind == "TransitGateway", "the hub is a Transit Gateway"
    fp = gw.spec.forProvider
    assert fp.region == "eu-west-1", "the gateway must live in spec.region — it can only attach VPCs there"
    assert fp.amazonSideAsn == 64512, "amazonSideAsn defaults to 64512"
    assert fp.description == "demo hub", "the description must name the XR the gateway belongs to"
    assert fp.dnsSupport == "enable", "private hostnames must resolve across the hub"
    assert fp.defaultRouteTableAssociation == "enable", "mesh leaves the default association on — that is the whole topology"
    assert fp.defaultRouteTablePropagation == "enable", "mesh leaves the default propagation on, so every spoke learns every other"
    assert fp.tags == {Name = "demo-hub"}, "the console labels a gateway by its Name tag"
    assert _res({amazonSideAsn = 65001}, "managed").spec.forProvider.amazonSideAsn == 65001, "an explicit amazonSideAsn must reach the gateway"
}

test_mesh_attachments = lambda {
    att = _res({}, "attachment-team-a")
    assert att.kind == "TransitGatewayVPCAttachment", "a spoke is attached with a VPC attachment"
    fp = att.spec.forProvider
    assert fp.region == "eu-west-1", "an attachment lives in the gateway's region"
    assert fp.vpcId == "vpc-0aa11bb22cc33dd44", "spokes[].network is an existing VPC id, attached as it stands"
    assert fp.subnetIds == ["subnet-0aa1"], "the attachment places one ENI per listed subnet"
    assert fp.transitGatewayIdSelector.matchControllerRef == True, "the attachment must bind the gateway it was composed with"
    assert fp.dnsSupport == "enable", "DNS support must be on for private hostnames to resolve over the attachment"
    assert fp.transitGatewayDefaultRouteTableAssociation == True, "in mesh the attachment uses the gateway's default table"
    assert fp.transitGatewayDefaultRouteTablePropagation == True, "in mesh the attachment propagates into the gateway's default table"
    assert fp.tags == {Name = "demo-team-a"}, "an attachment is labelled after the XR and its spoke"
    assert _res({}, "attachment-shared-services").spec.forProvider.vpcId == "vpc-0sh11bb22cc33dd44", "every spec spoke gets its own attachment"
    assert _res({}, "attachment-team-b").spec.forProvider.subnetIds == ["subnet-0bb1"], "every spec spoke gets its own subnets"
}

# ---- render: isolated --------------------------------------------------------

# render() asserts that isolated carries at least one shared spoke, and that
# every spoke names at least one subnet, and that spoke names are unique. A
# failing KCL assert aborts the run rather than something a test can catch, so
# what is asserted here is the accepted shape; the rejected ones are
# [{name: a}, {name: a}], a spoke with subnets: [], and an isolated hub whose
# spokes are all shared: false.
test_isolated_resource_set = lambda {
    items = _render({topology = "isolated"})
    assert _names(items) == [
        "managed"
        "attachment-shared-services"
        "attachment-team-a"
        "attachment-team-b"
        "route-table-shared"
        "route-table-isolated"
        "association-shared-services"
        "association-team-a"
        "association-team-b"
        "propagation-shared-services-shared"
        "propagation-team-a-shared"
        "propagation-team-b-shared"
        "propagation-shared-services-isolated"
        "route-shared-services-0"
        "route-team-a-0"
        "route-team-a-1"
    ], "isolated adds two hub route tables, one association per spoke, a propagation into the shared table per spoke and one into the isolated table per shared spoke"
    fp = _pick(items, "managed").spec.forProvider
    assert fp.defaultRouteTableAssociation == "disable", "the default table must be off, or every attachment would land in it as well as in the table chosen for it"
    assert fp.defaultRouteTablePropagation == "disable", "the default table must learn nothing, or it would carry the routes isolation exists to withhold"
    attachments = [i for i in items if i.kind == "TransitGatewayVPCAttachment"]
    assert all a in attachments {
        a.spec.forProvider.transitGatewayDefaultRouteTableAssociation == False and a.spec.forProvider.transitGatewayDefaultRouteTablePropagation == False
    }, "no attachment may fall back to the default table in isolated — it must use only the table its association names"
    tbl = _pick(items, "route-table-shared")
    assert tbl.kind == "TransitGatewayRouteTable", "isolation is expressed with Transit Gateway route tables"
    assert tbl.spec.forProvider.region == "eu-west-1", "a hub route table lives in the gateway's region"
    assert tbl.spec.forProvider.transitGatewayIdSelector.matchControllerRef == True, "a hub route table must bind the gateway it was composed with"
    assert tbl.spec.forProvider.tags == {Name = "demo-rt-shared"}, "the console labels a route table by its Name tag"
}

# The association decides which table a spoke's own traffic is looked up in.
test_isolated_associations = lambda {
    items = _render({topology = "isolated"})
    table_of = lambda name: str -> str {
        _pick(items, "association-${name}").spec.forProvider.transitGatewayRouteTableIdSelector.matchLabels[hub.hub_table_label]
    }
    assert table_of("shared-services") == "shared", "a shared spoke is looked up in the table every spoke propagates into"
    assert table_of("team-a") == "isolated", "a workload spoke is looked up in the table only shared spokes propagate into"
    assert table_of("team-b") == "isolated", "every workload spoke shares the isolated table"
    assoc = _pick(items, "association-team-a").spec.forProvider
    assert assoc.transitGatewayAttachmentIdSelector.matchLabels[hub.spoke_label] == "team-a", "an association must find its own spoke's attachment, not another's"
    assert assoc.region == "eu-west-1", "an association lives in the gateway's region"
}

# The propagation fan-out is what isolation actually is.
test_isolated_propagation_fanout = lambda {
    items = _render({topology = "isolated"})
    props = lambda name: str -> any {
        [n for n in _names(items) if n.startswith("propagation-${name}-")]
    }
    assert props("team-a") == ["propagation-team-a-shared"], "a workload spoke propagates into the shared table only, so no other workload spoke ever learns its CIDR"
    assert props("team-b") == ["propagation-team-b-shared"], "every workload spoke propagates exactly once"
    assert props("shared-services") == [
        "propagation-shared-services-shared"
        "propagation-shared-services-isolated"
    ], "a shared spoke propagates into both tables — that is what makes it reachable from everywhere"
}

# The observable consequence of the association/propagation wiring: a workload
# spoke reaches shared spokes only, a shared spoke reaches everything.
test_isolated_reachability = lambda {
    items = _render({topology = "isolated"})
    assert _reach(items, "team-a") == ["shared-services"], "a workload spoke's table learns shared spokes and nothing else"
    assert _reach(items, "team-b") == ["shared-services"], "two workload spokes cannot reach each other"
    assert _reach(items, "shared-services") == ["shared-services", "team-a", "team-b"], "a shared spoke's table learns every spoke"
    assert _reach(items, "team-a") != _reach(items, "shared-services"), "shared=true must change what a spoke can reach, or the flag means nothing"
}

# Two route tables and three attachments belong to the same composite, so
# matchControllerRef alone is ambiguous for anything referencing one of them.
test_selectors_resolve_to_one_candidate = lambda {
    items = _render({topology = "isolated"})
    wired = [i for i in items if i.kind in ["TransitGatewayRouteTableAssociation", "TransitGatewayRouteTablePropagation"]]
    assert len(wired) == 7, "three associations and four propagations reference a labelled candidate"
    assert all w in wired {
        w.spec.forProvider.transitGatewayAttachmentIdSelector.matchControllerRef == True and w.spec.forProvider.transitGatewayRouteTableIdSelector.matchControllerRef == True
    }, "a selector must stay scoped to this composite's resources"
    assert all w in wired {
        _candidates(items, "TransitGatewayVPCAttachment", w.spec.forProvider.transitGatewayAttachmentIdSelector.matchLabels) == 1
    }, "every attachment selector must match exactly one composed attachment — the ${hub.spoke_label} label has to be set on it"
    assert all w in wired {
        _candidates(items, "TransitGatewayRouteTable", w.spec.forProvider.transitGatewayRouteTableIdSelector.matchLabels) == 1
    }, "every route table selector must match exactly one composed route table — the ${hub.hub_table_label} label has to be set on it"
}

# ---- render: spoke-side routes -----------------------------------------------

# The Transit Gateway routes only what already reached it.
test_spoke_routes = lambda {
    items = _render({})
    assert _pick(items, "route-team-a-0").spec.forProvider.routeTableId == "rtb-0aa1", "the first routeTableIds entry gets index 0"
    assert _pick(items, "route-team-a-1").spec.forProvider.routeTableId == "rtb-0aa2", "a second route table on one spoke gets its own route"
    assert [n for n in _names(items) if n.startswith("route-team-b")] == [], "a spoke with no routeTableIds is attached and sends nothing into the hub"
    rt = _pick(items, "route-team-a-0")
    assert rt.kind == "Route", "the spoke side is a VPC route"
    assert rt.spec.forProvider.region == "eu-west-1", "the route lives in the spoke's region"
    assert rt.spec.forProvider.transitGatewayIdSelector.matchControllerRef == True, "the route must point at the gateway this XR composed"
    assert rt.spec.forProvider?.routeTableIdSelector == Undefined, "the spoke's route table belongs to its own Network XR, so it is named by id"
}

test_summary_cidr = lambda {
    assert _res({}, "route-team-a-0").spec.forProvider.destinationCidrBlock == "10.0.0.0/8", "summaryCidr defaults to 10.0.0.0/8"
    items = _render({summaryCidr = "172.16.0.0/12"})
    assert all r in items {
        r.kind != "Route" or r.spec.forProvider.destinationCidrBlock == "172.16.0.0/12"
    }, "an explicit summaryCidr must be the destination of every spoke-side route"
}

# ---- render: tags and deletion policy ----------------------------------------
test_tags = lambda {
    items = _render({topology = "isolated", tags = {team = "platform"}})
    assert _pick(items, "managed").spec.forProvider.tags == {Name = "demo-hub", team = "platform"}, "tags must reach the gateway alongside its Name"
    assert _pick(items, "attachment-team-a").spec.forProvider.tags == {Name = "demo-team-a", team = "platform"}, "tags must reach every attachment"
    assert _pick(items, "route-table-isolated").spec.forProvider.tags == {Name = "demo-rt-isolated", team = "platform"}, "tags must reach every hub route table"
    assert _res({
        tags = {Name = "custom"}
    }, "managed").spec.forProvider.tags == {Name = "custom"}, "an explicit Name tag must win over the derived one"
}

test_deletion_policy = lambda {
    orphaned = _render({topology = "isolated", deletionPolicy = "Orphan"})
    assert all r in orphaned {
        r.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every composed managed resource"
    deleted = _render({topology = "isolated"})
    assert all r in deleted {
        not (r.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------
test_status_before_observation = lambda {
    dxr = hub.status(_build({topology = "isolated"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "NetworkHub", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr name must echo the composite"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.topology == "isolated", "topology must report what was configured"
    assert dxr.status.hubName == "demo", "the hub is named after the XR"
    assert dxr.status.spokeCount == 3, "spokeCount counts the spec, so it is known before anything exists"
    assert dxr.status.attachedCount == 0, "nothing is attached before the provider says so"
    assert dxr.status.ready == False, "a hub that does not exist is not ready"
    assert dxr.status?.hubId == Undefined, "no gateway, no id"
    assert dxr.status?.hubState == Undefined, "the Transit Gateway MR reports no state, so none is ever published"
    assert dxr.status?.defaultRouteTableId == Undefined, "the default route table id only exists once the gateway does"
    assert dxr.status?.routeTableIds == Undefined, "the composed route tables have no ids yet"
    assert dxr.status.spokes == [
        {name = "shared-services", network = "vpc-0sh11bb22cc33dd44", shared = True, attached = False}
        {name = "team-a", network = "vpc-0aa11bb22cc33dd44", shared = False, attached = False}
        {name = "team-b", network = "vpc-0bb11bb22cc33dd44", shared = False, attached = False}
    ], "every spec spoke must be reported in spec order, with no id until it is observed"
    assert dxr.status["cloud-url"] == "https://eu-west-1.console.aws.amazon.com/vpcconsole/home?region=eu-west-1#TransitGateways:", "the console link is derivable from the region alone"
}

# A gateway with half its spokes attached is not a topology.
test_status_partially_observed = lambda {
    dxr = hub.status(_build({topology = "isolated"}), _observed_hub | _observed("attachment-team-a", {id = "tgw-attach-0aa"}))
    assert dxr.status.hubId == "tgw-0abc123", "the observed gateway id must be surfaced"
    assert dxr.status.defaultRouteTableId == "tgw-rtb-0default", "the gateway's own default route table must be surfaced"
    assert dxr.status.attachedCount == 1, "only the observed attachment counts"
    assert dxr.status.ready == False, "a hub with two of its three spokes missing is not ready"
    assert dxr.status.spokes[1] == {
        name = "team-a"
        network = "vpc-0aa11bb22cc33dd44"
        shared = False
        attached = True
        id = "tgw-attach-0aa"
    }, "the observed attachment id must be reported on its own spoke's row"
    assert dxr.status.spokes[0]?.id == Undefined, "an unobserved spoke carries no id"
    assert dxr.status.spokes[0].attached == False, "an unobserved spoke is not attached"
}

test_status_fully_observed = lambda {
    dxr = hub.status(_build({topology = "isolated"}), _observed_hub | _observed_tables | _observed_attachments)
    assert dxr.status.ready == True, "the gateway exists and every spoke is attached"
    assert dxr.status.attachedCount == 3, "every spoke is confirmed attached"
    assert dxr.status.routeTableIds == ["tgw-rtb-0shared", "tgw-rtb-0isolated"], "the composed hub route tables must be surfaced once they exist"
    assert [s.id for s in dxr.status.spokes] == ["tgw-attach-0sh", "tgw-attach-0aa", "tgw-attach-0bb"], "every attachment id must be reported on its own spoke's row, in spec order"
}

# mesh composes no hub route table, so there is none to report.
test_status_mesh_reports_no_hub_route_tables = lambda {
    dxr = hub.status(_build({}), _observed_hub | _observed_attachments)
    assert dxr.status.topology == "mesh", "topology defaults to mesh"
    assert dxr.status.ready == True, "mesh is ready on the gateway and its attachments alone"
    assert dxr.status?.routeTableIds == Undefined, "mesh uses the gateway's default table, which this XR did not compose"
    assert dxr.status.defaultRouteTableId == "tgw-rtb-0default", "the default table is the one doing the routing in mesh, so its id matters most here"
}
