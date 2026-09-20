# hubspoke (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-networkconnectivity schema package. The portable
# NetworkHub maps onto a Network Connectivity Center hub plus one VPC spoke
# per spokes[] entry. The spoke networks are never created here:
# spokes[].network is the URI of a network that already exists (what a
# Network XR publishes as status.selfLink), and detaching a spoke leaves it
# running.
#
# An NCC hub is a global resource — it takes no location at all — so
# spec.region is ignored by this backend, which the XRD documents. The same
# goes for the AWS-only knobs (summaryCidr, amazonSideAsn, spokes[].subnets,
# spokes[].routeTableIds) and the Azure-only ones (resourceGroup, hubCidr):
# NCC programs the spoke side itself by installing hub routes into every
# attached VPC, so there is no route to compose and no hub subnet to size.
#
# Not composed here: VPN, Interconnect and router-appliance spokes, producer
# VPC spokes, ServiceConnectionPolicy, and the two groups a STAR hub creates
# for itself (see the second pass in render()).
import gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_hub as ncc_hub
import gcp_networkconnectivity.models.v1beta1.networkconnectivity_gcpm_upbound_io_v1beta1_spoke as ncc_spoke

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The portable topology -> the preset NCC implements it with. MESH lets every
# spoke reach every other one; STAR splits the spokes into two groups and only
# lets the center talk to the edge.
preset_topology = {mesh = "MESH", isolated = "STAR"}

# The two groups a STAR hub creates for itself. `center` is reachable by
# everything (the shared-services spokes), `edge` reaches only center.
center_group = "center"
edge_group = "edge"

# A VPC spoke is a global resource: the region it lives in is the one of the
# network it links, which the spoke never restates (verified against
# SpokeSpecForProvider.location, "The location for the resource").
spoke_location = "global"

# The lifecycle state in which a hub or a spoke actually carries traffic; both
# atProvider schemas report it as `state`.
active_state = "ACTIVE"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow a
# legitimate False or 0, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Observed state of a composed resource; Undefined until the first reconcile.
_at = lambda ocds, res: str -> any {
    (ocds[res]?.Resource?.status?.atProvider) if res in (ocds or {}) else Undefined
}

# The hub's full resource name — projects/<project>/locations/global/hubs/<hub>
# — as the provider reports it. HubStatusAtProvider exposes both `name` and
# `id` with that documented form, and upjet fills `name` from the Terraform
# attribute, which on some builds is the bare hub id; so the path is taken
# from whichever observed value actually carries it, and is empty until one
# does.
_hub_path = lambda at -> str {
    _found = [_c for _c in [at?.name or "", at?.id or ""] if "/hubs/" in _c]
    _found[0] if _found else ""
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _topology = _spec?.topology or "mesh"
    _spokes = _spec?.spokes or []
    _tags = _spec?.tags
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _isolated = _topology == "isolated"

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently pretending a field took effect.
    _spoke_names = [_s.name for _s in _spokes]
    assert len(_spoke_names) == len({_n: "" for _n in _spoke_names}), "hubspoke-gcp: spokes[].name must be unique — two entries sharing a name collapse onto one composed Spoke, so one of the networks is never attached; rename the duplicate"
    assert not _isolated or any _s in _spokes {
        _flag(_s?.shared, False)
    }, "hubspoke-gcp: topology: isolated needs at least one spoke with shared: true — in a STAR hub the edge group only reaches the center group, so with no shared spoke nothing may reach anything; mark the shared-services spoke shared: true, or use topology: mesh"

    # 1) The hub. Its name is part of every spoke's group URI and of
    # status.hubId, so it is pinned to the XR name instead of being left to
    # Crossplane's generated external-name.
    _items: [any] = [ncc_hub.Hub {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        # PRESET pinned explicitly: presetTopology is only read under it, and
        # a CUSTOM hub would route by a policy this XR does not compose.
        spec.forProvider.policyMode = "PRESET"
        spec.forProvider.presetTopology = preset_topology[_topology]
        spec.forProvider.description = "NetworkHub ${_name} (managed by Crossplane)"
        if _tags:
            spec.forProvider.labels = _tags
    }]

    # SECOND PASS (isolated only). Spoke.forProvider.group is a plain string
    # URI — projects/<project>/locations/global/hubs/<hub>/groups/{center,edge}
    # — with no ref or selector, and it embeds the project number, which is
    # nowhere in the spec. So a STAR spoke can only be rendered once the hub
    # has been observed: the first reconcile emits the hub alone, the next one
    # adds the spokes. A MESH hub has no groups at all, so its spokes are
    # rendered straight away.
    #
    # The two groups are never composed: a STAR hub creates `center` and
    # `edge` itself, and a Group MR for either would fight the API over a
    # resource it did not create.
    _hub_uri = _hub_path(_at(ocds, "managed"))

    # 2) One spoke per network, in spec order.
    _spoke = lambda s -> any {
        ncc_spoke.Spoke {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "spoke-${s.name}"
                "crossplane.io/external-name" = "${_name}-${s.name}"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.location = spoke_location
            spec.forProvider.hubSelector.matchControllerRef = True
            spec.forProvider.linkedVpcNetwork.uri = s.network
            if _isolated:
                spec.forProvider.group = "${_hub_uri}/groups/${center_group if _flag(s?.shared, False) else edge_group}"
            if _tags:
                spec.forProvider.labels = _tags
        }
    }
    if not _isolated or _hub_uri:
        _items += [_spoke(_s) for _s in _spokes]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _topology = _spec?.topology or "mesh"
    _spokes = _spec?.spokes or []

    _hub_at = _at(ocds, "managed")
    _hub_uri = _hub_path(_hub_at)
    _hub_state = _hub_at?.state or ""

    # One row per spec spoke, in spec order — a row exists before its Spoke
    # does, so the caller can see which network is still waiting.
    _row = lambda s -> any {
        _sat = _at(ocds, "spoke-${s.name}")

        # SpokeStatusAtProvider.id is the full resource name
        # (projects/<p>/locations/global/spokes/<spoke>); `name` is the bare
        # spoke name and is the fallback when only it is populated.
        _id = _sat?.id or _sat?.name or ""
        {
            name = s.name
            network = s.network
            shared = _flag(s?.shared, False)
            # A spoke exists long before it carries traffic: NCC reports
            # CREATING, then ACTIVE once the hub accepted it.
            attached = (_sat?.state or "") == active_state
            if _id:
                id = _id
        }
    }
    _rows = [_row(_s) for _s in _spokes]
    _attached = [_r for _r in _rows if _r.attached]

    _project = _hub_at?.project or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "NetworkHub"
        metadata.name = _name
        status = {
            # A hub with half its spokes attached is not a topology.
            ready = _hub_state == active_state and len(_attached) == len(_spokes)
            provider = "gcp"
            topology = _topology
            hubName = _name
            spokeCount = len(_spokes)
            attachedCount = len(_attached)
            spokes = _rows
            if _hub_uri:
                hubId = _hub_uri
            if _hub_state:
                hubState = _hub_state
            # routeTableIds and defaultRouteTableId stay unset on gcp: NCC has
            # no route-table object of its own — the hub installs its routes
            # straight into each attached VPC — so there is nothing to report.
            # The hubs live in the console's hybrid-connectivity section; the
            # project only lands in the link once the hub reports it, and
            # without it the console falls back to the caller's default.
            "cloud-url" = "https://console.cloud.google.com/hybrid/hubs/details/${_name}" + ("?project=${_project}" if _project else "")
        }
    }
}
