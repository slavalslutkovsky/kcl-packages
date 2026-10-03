# hubspoke (aws) — Crossplane Composition logic (function-kcl module).
# The hub is one Transit Gateway and one TransitGatewayVPCAttachment per spoke
# VPC. The VPCs themselves already exist and are never touched: spokes[].network
# is an existing vpc-… id, so detaching a spoke leaves the network running.
#
# Two topologies, and the difference is entirely in the routing:
#
#   mesh     — the gateway's own default route table does the association and
#              the propagation for every attachment, which is what makes every
#              spoke reach every other spoke. Nothing else is composed.
#
#   isolated — the default table cannot express "these may talk, those may
#              not", so it is switched off on the gateway and on every
#              attachment, and two route tables are wired by hand instead.
#
# Nothing here resolves through observed state: every cross-resource reference
# is a selector, which is why render() takes no ocds. Two route tables and n
# attachments belong to the same composite, so matchControllerRef alone is
# ambiguous — each of them carries a distinguishing label and every selector
# matches on it.
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway as tgw
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_v_p_c_attachment as tgw_attachment
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table as tgw_route_table
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table_association as tgw_association
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table_propagation as tgw_propagation
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route as ec2_route

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Label that tells the two composed hub route tables apart. Both are owned by
# the same composite, so a selector that only matched the controller reference
# would resolve to whichever of them upjet happened to list first.
hub_table_label = "cloud.example.org/hub-table"

# Label that ties an attachment to its spoke, for the same reason: there is one
# attachment per spoke and every association and propagation must find exactly
# the one it was composed for.
spoke_label = "cloud.example.org/spoke"

# The route table a spoke's own traffic is looked up in: shared spokes use the
# table everything propagates into, workload spokes the table only shared
# spokes propagate into.
shared_table = "shared"
isolated_table = "isolated"

# XRD defaults. They only exist on an XR that went through the API server; a
# locally rendered example or a unit test carries none.
default_topology = "mesh"
default_summary_cidr = "10.0.0.0/8"
default_amazon_side_asn = 64512

# `or` would also swallow an explicit false, so presence — not truthiness —
# decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Observed state of a composed resource; Undefined until the first reconcile.
_at = lambda ocds, res: str -> any {
    (ocds[res]?.Resource?.status?.atProvider) if res in (ocds or {}) else Undefined
}

# Whether a spoke is shared services (reachable by, and reaching, everything).
_shared = lambda spoke -> bool {
    _flag(spoke?.shared, False)
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _topology = _spec?.topology or default_topology
    _isolated = _topology == "isolated"
    _spokes = _spec?.spokes or []
    _summary = _spec?.summaryCidr or default_summary_cidr
    _asn = _spec?.amazonSideAsn or default_amazon_side_asn
    _tags = _spec?.tags or {}
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently building a hub that is not the one asked for.
    assert len({_s.name: "" for _s in _spokes}) == len(_spokes), "hubspoke-aws: spokes[].name must be unique — two spokes sharing a name collapse onto one attachment and one of the networks is silently never attached; rename the duplicate"
    assert all _s in _spokes {
        len(_s?.subnets or []) > 0
    }, "hubspoke-aws: every spoke needs at least one entry in spokes[].subnets — the attachment places one ENI per listed subnet, and traffic from an availability zone without an ENI never reaches the Transit Gateway"
    assert not _isolated or any _s in _spokes {
        _shared(_s)
    }, "hubspoke-aws: topology=isolated needs at least one spoke with shared=true — workload spokes reach shared spokes only, so a hub without one is a hub where nothing may reach anything; mark a shared-services spoke, or use topology=mesh"

    _annos = lambda res: str -> {str:str} {
        {"krm.kcl.dev/composition-resource-name" = res}
    }

    # A Name tag is how the console labels an EC2 resource; explicit user tags
    # win, so an operator can still override it.
    _tag = lambda resource_name: str -> {str:str} {
        {Name = resource_name} | _tags
    }

    # 1) The hub. defaultRouteTableAssociation / defaultRouteTablePropagation
    # are "enable"/"disable" strings on this MR, not booleans: in mesh they are
    # the whole topology, in isolated they must be off or every attachment
    # would land in the default table as well as in the one chosen for it.
    _items: [any] = [tgw.TransitGateway {
        metadata.annotations = _annos("managed")
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.amazonSideAsn = _asn
        spec.forProvider.description = "${_name} hub"
        spec.forProvider.dnsSupport = "enable"
        spec.forProvider.defaultRouteTableAssociation = "disable" if _isolated else "enable"
        spec.forProvider.defaultRouteTablePropagation = "disable" if _isolated else "enable"
        spec.forProvider.tags = _tag("${_name}-hub")
    }]

    # 2) One attachment per spoke. Here the same two switches are booleans (a
    # different MR, a different spelling in the provider schema).
    _items += [tgw_attachment.TransitGatewayVPCAttachment {
        metadata.annotations = _annos("attachment-${_s.name}")
        metadata.labels = {"${spoke_label}" = _s.name}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.vpcId = _s.network
        spec.forProvider.subnetIds = _s.subnets
        # Exactly one Transit Gateway belongs to this XR.
        spec.forProvider.transitGatewayIdSelector = {matchControllerRef = True}
        spec.forProvider.transitGatewayDefaultRouteTableAssociation = not _isolated
        spec.forProvider.transitGatewayDefaultRouteTablePropagation = not _isolated
        # Lets a spoke resolve private hostnames of the VPCs it reaches.
        spec.forProvider.dnsSupport = "enable"
        spec.forProvider.tags = _tag("${_name}-${_s.name}")
    } for _s in _spokes]

    # 3) Isolation, wired by hand. An association decides which table a spoke's
    # outbound traffic is looked up in; a propagation decides which tables learn
    # that spoke's VPC CIDR.
    if _isolated:
        _items += [tgw_route_table.TransitGatewayRouteTable {
            metadata.annotations = _annos("route-table-${_t}")
            metadata.labels = {"${hub_table_label}" = _t}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.transitGatewayIdSelector = {matchControllerRef = True}
            spec.forProvider.tags = _tag("${_name}-rt-${_t}")
        } for _t in [shared_table, isolated_table]]

        # A shared spoke looks its traffic up in the shared table, a workload
        # spoke in the isolated one. The attachment selector must find that
        # spoke's attachment and no other, hence the per-spoke label.
        _items += [tgw_association.TransitGatewayRouteTableAssociation {
            metadata.annotations = _annos("association-${_s.name}")
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.transitGatewayAttachmentIdSelector = {
                matchControllerRef = True
                matchLabels = {"${spoke_label}" = _s.name}
            }
            spec.forProvider.transitGatewayRouteTableIdSelector = {
                matchControllerRef = True
                matchLabels = {"${hub_table_label}" = shared_table if _shared(_s) else isolated_table}
            }
        } for _s in _spokes]

        # EVERY attachment propagates into the shared table, so the shared
        # table holds a route to every spoke.
        _items += [tgw_propagation.TransitGatewayRouteTablePropagation {
            metadata.annotations = _annos("propagation-${_s.name}-${shared_table}")
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.transitGatewayAttachmentIdSelector = {
                matchControllerRef = True
                matchLabels = {"${spoke_label}" = _s.name}
            }
            spec.forProvider.transitGatewayRouteTableIdSelector = {
                matchControllerRef = True
                matchLabels = {"${hub_table_label}" = shared_table}
            }
        } for _s in _spokes]

        # ONLY shared spokes additionally propagate into the isolated table, so
        # that table holds routes to shared spokes and to nothing else. That is
        # what isolation is: a workload spoke sees shared spokes but not other
        # workload spokes, while a shared spoke — looked up in the shared table
        # — sees everything.
        _items += [tgw_propagation.TransitGatewayRouteTablePropagation {
            metadata.annotations = _annos("propagation-${_s.name}-${isolated_table}")
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.transitGatewayAttachmentIdSelector = {
                matchControllerRef = True
                matchLabels = {"${spoke_label}" = _s.name}
            }
            spec.forProvider.transitGatewayRouteTableIdSelector = {
                matchControllerRef = True
                matchLabels = {"${hub_table_label}" = isolated_table}
            }
        } for _s in _spokes if _shared(_s)]

    # 4) The spoke side. A Transit Gateway only routes what already reached it,
    # and nothing reaches it until a route table inside the spoke VPC sends
    # summaryCidr at the gateway — so an attachment with no routeTableIds is
    # attached and carries no traffic, which is what an empty list asks for.
    _items += [ec2_route.Route {
        metadata.annotations = _annos("route-${_s.name}-${_i}")
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        # The spoke's own route table, named by the caller: it belongs to the
        # Network XR, not to this one, so it is an id and not a reference.
        spec.forProvider.routeTableId = _s.routeTableIds[_i]
        spec.forProvider.destinationCidrBlock = _summary
        spec.forProvider.transitGatewayIdSelector = {matchControllerRef = True}
    } for _s in _spokes for _i in range(len(_s?.routeTableIds or []))]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _topology = _spec?.topology or default_topology
    _spokes = _spec?.spokes or []

    _hub = _at(ocds, "managed")
    _hub_id = _hub?.id

    # One row per spec spoke, in spec order, whether or not it exists yet.
    _row = lambda spoke -> any {
        _id = _at(ocds, "attachment-${spoke.name}")?.id
        {
            name = spoke.name
            network = spoke.network
            shared = _shared(spoke)
            attached = (_id or "") != ""
            if _id:
                id = _id
        }
    }
    _rows = [_row(_s) for _s in _spokes]
    _attached = len([_r for _r in _rows if _r.attached])

    # The two composed hub route tables, once they exist. Mesh composes none —
    # the gateway's own default table does the work.
    _table_ids = [_id for _id in [
        _at(ocds, "route-table-${shared_table}")?.id
        _at(ocds, "route-table-${isolated_table}")?.id
    ] if _id]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "NetworkHub"
        metadata.name = _name
        status = {
            provider = "aws"
            topology = _topology
            hubName = _name
            # No hubState: TransitGateway.status.atProvider carries no state
            # field in the generated schema (only ids, the ASN and the flags),
            # so there is nothing truthful to report here.
            spokeCount = len(_spokes)
            attachedCount = _attached
            # Half a topology is not a topology: the gateway must exist and
            # every spoke must be attached.
            ready = (_hub_id or "") != "" and _attached == len(_spokes)
            if _hub_id:
                hubId = _hub_id
            if _hub?.associationDefaultRouteTableId:
                defaultRouteTableId = _hub.associationDefaultRouteTableId
            if _rows:
                spokes = _rows
            if _table_ids:
                routeTableIds = _table_ids
            # Transit Gateways are listed per region and the list page needs no
            # id, so this link is derivable before anything exists.
            "cloud-url" = "https://${_region}.console.aws.amazon.com/vpcconsole/home?region=${_region}#TransitGateways:"
        }
    }
}
