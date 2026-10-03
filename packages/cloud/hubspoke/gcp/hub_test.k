import .hub

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_hub_uri = "projects/acme-prod/locations/global/hubs/demo"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it — nor
# with the `hub` module this file imports.
_spokes = [
    {name = "shared-services", network = "projects/acme-prod/global/networks/shared-vpc", shared = True}
    {name = "team-a", network = "projects/acme-prod/global/networks/team-a-vpc"}
    {name = "team-b", network = "projects/acme-prod/global/networks/team-b-vpc"}
]

_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "NetworkHub"
        metadata = {name = "demo", namespace = "apps"}
        spec = {region = "europe-west1", spokes = _spokes} | extra
    }
}

_render = lambda extra: any, ocds: any -> any {
    hub.render(_build(extra), ocds)
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

_res = lambda extra: any, ocds: any, name: str -> any {
    _pick(_render(extra, ocds), name)
}

_isolated = {topology = "isolated"}

# Observed state, one composed resource at a time.
_observed_hub = {
    managed.Resource.status.atProvider = {
        id = _hub_uri
        name = _hub_uri
        state = "ACTIVE"
        project = "acme-prod"
        presetTopology = "STAR"
    }
}

# The same hub as an older provider build reports it: `name` carries the bare
# hub id and only `id` carries the full resource path.
_observed_hub_bare_name = {
    managed.Resource.status.atProvider = {
        id = _hub_uri
        name = "demo"
        state = "ACTIVE"
        project = "acme-prod"
    }
}

_observed_spoke = lambda name: str, state: str -> any {
    {
        "spoke-${name}" = {
            Resource.status.atProvider = {
                id = "projects/acme-prod/locations/global/spokes/demo-${name}"
                name = "demo-${name}"
                state = state
            }
        }
    }
}

_all_spokes_active = _observed_spoke("shared-services", "ACTIVE") | _observed_spoke("team-a", "ACTIVE") | _observed_spoke("team-b", "ACTIVE")

# ---- render: mesh ------------------------------------------------------------

# A MESH hub needs nothing observed: the hub and every spoke go out on the
# first reconcile, and no spoke belongs to a group.
test_mesh_render = lambda {
    items = _render({}, {})
    assert _names(items) == ["managed", "spoke-shared-services", "spoke-team-a", "spoke-team-b"], "mesh must render the hub and one spoke per spokes[] entry, in spec order"
    assert all i in items {
        i.metadata?.namespace == Undefined
    }, "composed resources must carry no namespace — Crossplane places them"
    center = _pick(items, "managed")
    assert center.kind == "Hub", "the transit fabric is an NCC Hub"
    assert center.spec.forProvider.presetTopology == "MESH", "topology defaults to mesh, which NCC spells MESH"
    assert center.spec.forProvider.policyMode == "PRESET", "presetTopology is only read under policyMode PRESET"
    assert all i in items[1::] {
        i.kind == "Spoke" and i.spec.forProvider?.group == Undefined
    }, "a MESH hub has no groups, so no spoke may name one"
}

# The hub name is part of every group URI and of status.hubId, so it may not
# be left to Crossplane's generated external-name.
test_hub_naming = lambda {
    center = _res({}, {}, "managed")
    assert center.metadata.annotations["crossplane.io/external-name"] == "demo", "the hub name must be pinned to the XR name: the spokes' group URIs and status.hubId are derived from it before the hub exists"
    assert center.spec.forProvider.description == "NetworkHub demo (managed by Crossplane)", "the description must be deterministic"
    assert center.spec.forProvider?.labels == Undefined, "no labels unless tags are asked for"

    # An NCC hub is global — HubSpecForProvider has no location attribute at
    # all — so spec.region reaches nothing on this backend.
    assert center.spec.forProvider?.project == Undefined, "the hub's project must come from the ProviderConfig, not from the XR — spec.region is ignored here and no project is pinned"
}

# Per-spoke fan-out. Three entries become three Spokes, each bound to the
# composed hub and to its own existing network. Two entries sharing a name
# would collapse onto one composed resource and silently drop a network, so
# render() rejects that outright — a failing KCL assert aborts the run rather
# than something a test can catch, so what is asserted here is the accepted
# shape: distinct names, distinct resources, one network each.
test_spoke_fan_out = lambda {
    items = _render({}, {})
    assert len(items) == 4, "three spokes plus the hub"
    assert [i.metadata.annotations["crossplane.io/external-name"] for i in items[1::]] == [
        "demo-shared-services"
        "demo-team-a"
        "demo-team-b"
    ], "each spoke's provider name must be pinned to <xr>-<spoke>, so it is stable and readable"
    assert [i.spec.forProvider.linkedVpcNetwork.uri for i in items[1::]] == [
        "projects/acme-prod/global/networks/shared-vpc"
        "projects/acme-prod/global/networks/team-a-vpc"
        "projects/acme-prod/global/networks/team-b-vpc"
    ], "every spoke must attach the network its spec entry names, verbatim — this XR never creates one"
    assert all i in items[1::] {
        i.spec.forProvider.location == "global"
    }, "a VPC spoke is global; its region comes from the network it links"
    assert all i in items[1::] {
        i.spec.forProvider.hubSelector.matchControllerRef == True
    }, "every spoke must attach to the hub it was composed with"
    one = _res({spokes = [_spokes[1]]}, {}, "spoke-team-a")
    assert one.spec.forProvider.linkedVpcNetwork.uri == "projects/acme-prod/global/networks/team-a-vpc", "a single-spoke hub renders that one spoke under its own name"
}

# ---- render: isolated (second pass) ------------------------------------------

# Spoke.forProvider.group is a plain string URI embedding the project number,
# so it cannot be derived from the spec: the STAR hub goes out alone and the
# spokes wait for it to report its own resource name. A spoke rendered now
# would either land in no group (reachable by everything, which is the
# opposite of isolated) or name a hub path that does not exist.
test_isolated_before_observation = lambda {
    items = _render(_isolated, {})
    assert _names(items) == ["managed"], "with no observed hub the isolated render is the hub alone — a group URI embeds the project number, which the spec does not carry"
    assert _pick(items, "managed").spec.forProvider.presetTopology == "STAR", "isolated must switch the hub to the STAR preset"
}

# Once the hub reports its resource name every spoke follows, each in the
# group that decides what it may reach.
test_isolated_after_observation = lambda {
    items = _render(_isolated, _observed_hub)
    assert _names(items) == ["managed", "spoke-shared-services", "spoke-team-a", "spoke-team-b"], "an observed hub must release every spoke"
    assert _pick(items, "spoke-shared-services").spec.forProvider.group == "${_hub_uri}/groups/center", "a shared spoke belongs to the center group, which every spoke reaches"
    assert _pick(items, "spoke-team-a").spec.forProvider.group == "${_hub_uri}/groups/edge", "a workload spoke belongs to the edge group, which reaches the center only"
    assert _pick(items, "spoke-team-b").spec.forProvider.group == "${_hub_uri}/groups/edge", "every unmarked spoke is a workload spoke"
    assert _pick(items, "spoke-shared-services").spec.forProvider.group != _pick(items, "spoke-team-a").spec.forProvider.group, "isolation is exactly this: a workload spoke must not share the shared spoke's reachability"
    # The two groups are the hub's own: composing them would fight the API.
    assert all i in items {
        i.kind in ["Hub", "Spoke"]
    }, "a STAR hub creates center and edge itself — no Group may be composed"
}

# Only the full projects/<p>/locations/global/hubs/<h> path can carry a group
# URI, and the provider may report it as either atProvider field.
test_isolated_group_uri_from_either_observed_field = lambda {
    items = _render(_isolated, _observed_hub_bare_name)
    assert _pick(items, "spoke-shared-services").spec.forProvider.group == "${_hub_uri}/groups/center", "the group URI must be built from whichever observed field carries the hub's full resource path"
}

# An isolated hub with no shared spoke is rejected by render(): the edge group
# reaches only the center, so nothing would reach anything. A failing KCL
# assert aborts the run, so what is asserted here is the accepted shape — at
# least one center member.
test_isolated_requires_a_reachable_center = lambda {
    items = _render(_isolated | {spokes = [_spokes[0], _spokes[1]]}, _observed_hub)
    center = [i for i in items[1::] if i.spec.forProvider.group.endswith("/groups/center")]
    assert len(center) == 1, "isolated needs at least one shared spoke, or the edge group has nothing to reach"
}

# Observation changes nothing in mesh: a MESH hub has no groups to join.
test_mesh_ignores_the_observed_hub = lambda {
    items = _render({}, _observed_hub | _all_spokes_active)
    assert all i in items[1::] {
        i.spec.forProvider?.group == Undefined
    }, "a group may never leak into a MESH hub — its spokes already reach each other"
}

# ---- render: tags ------------------------------------------------------------
test_tags_become_labels = lambda {
    items = _render({
        tags = {team = "platform"}
    }, {})
    assert all i in items {
        i.spec.forProvider.labels == {team = "platform"}
    }, "tags must reach the hub and every spoke as GCP labels"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy = lambda {
    orphaned = _render(_isolated | {deletionPolicy = "Orphan"}, _observed_hub)
    assert len(orphaned) == 4, "the policy must be checked on a full render, not just the hub"
    assert all r in orphaned {
        r.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every composed managed resource"
    deleted = _render(_isolated, _observed_hub)
    assert all r in deleted {
        not (r.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------
test_status_unobserved = lambda {
    dxr = hub.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "NetworkHub", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr name must echo the composite"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.topology == "mesh", "topology must default to mesh, as the XRD does"
    assert dxr.status.ready == False, "nothing is attached before the hub is observed"
    assert dxr.status.hubName == "demo", "the hub name is known ahead of creation — it is pinned to the XR name"
    assert dxr.status.spokeCount == 3, "spokeCount counts the spec, so it is known immediately"
    assert dxr.status.attachedCount == 0, "nothing has been confirmed attached"
    assert dxr.status.spokes == [
        {name = "shared-services", network = "projects/acme-prod/global/networks/shared-vpc", shared = True, attached = False}
        {name = "team-a", network = "projects/acme-prod/global/networks/team-a-vpc", shared = False, attached = False}
        {name = "team-b", network = "projects/acme-prod/global/networks/team-b-vpc", shared = False, attached = False}
    ], "every spec spoke must be reported in spec order, with no id until one is observed"
    assert dxr.status?.hubId == Undefined, "the hub resource name is assigned by GCP"
    assert dxr.status?.hubState == Undefined, "an unobserved hub has no state to report"
    assert dxr.status?.routeTableIds == Undefined and dxr.status?.defaultRouteTableId == Undefined, "NCC has no route-table object — the hub installs its routes into each attached VPC"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/hybrid/hubs/details/demo", "cloud-url must point at the hub in the console, with no project until one is observed"
}

# A live hub whose spokes are still being accepted is not a topology yet.
test_status_partially_observed = lambda {
    dxr = hub.status(_build(_isolated), _observed_hub | _observed_spoke("shared-services", "ACTIVE") | _observed_spoke("team-a", "CREATING"))
    assert dxr.status.ready == False, "a hub with one spoke still CREATING and one not yet created is not ready"
    assert dxr.status.topology == "isolated", "the configured topology must be reported"
    assert dxr.status.hubId == _hub_uri, "the observed hub resource name must be surfaced"
    assert dxr.status.hubState == "ACTIVE", "the hub state must be surfaced as the provider reports it"
    assert dxr.status.attachedCount == 1, "only the ACTIVE spoke counts as attached"
    assert dxr.status.spokeCount == 3, "spokeCount stays the number asked for"
    assert dxr.status.spokes[0].attached == True, "an ACTIVE spoke is attached"
    assert dxr.status.spokes[0].id == "projects/acme-prod/locations/global/spokes/demo-shared-services", "an observed spoke must report its provider id"
    assert dxr.status.spokes[1].attached == False, "a CREATING spoke exists but carries no traffic yet"
    assert dxr.status.spokes[1].id == "projects/acme-prod/locations/global/spokes/demo-team-a", "a spoke that exists has an id even before it is active"
    assert dxr.status.spokes[2]?.id == Undefined, "an unobserved spoke has no id"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/hybrid/hubs/details/demo?project=acme-prod", "an observed project must land in the console URL"
}

test_status_fully_observed = lambda {
    dxr = hub.status(_build({}), _observed_hub | _all_spokes_active)
    assert dxr.status.ready == True, "an ACTIVE hub with every spoke ACTIVE is the topology that was asked for"
    assert dxr.status.attachedCount == 3, "every spoke is confirmed attached"
    assert all s in dxr.status.spokes {
        s.attached
    }, "every row must report its spoke attached"
    assert [s.shared for s in dxr.status.spokes] == [True, False, False], "shared must be reported per spoke, defaulting to false"
}

# A hub that is still CREATING holds the whole topology back, however many
# spokes already reported.
test_status_hub_not_active = lambda {
    ocds = {
        managed.Resource.status.atProvider = {id = _hub_uri, name = _hub_uri, state = "CREATING", project = "acme-prod"}
    }
    dxr = hub.status(_build({}), ocds | _all_spokes_active)
    assert dxr.status.ready == False, "only an ACTIVE hub is ready"
    assert dxr.status.hubState == "CREATING", "the hub state must be reported while it is being created"
    assert dxr.status.attachedCount == 3, "the spokes' own state is reported independently of the hub's"
}
