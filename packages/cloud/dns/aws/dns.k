# dns (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-route53 schema package. The portable DnsZone maps onto
# a Route53 Zone plus one Record MR per records[] entry. Route53 is global:
# neither the Zone nor the Record model carries a forProvider.region, so
# spec.region is accepted for portability but ignored here — the provider
# talks to the global Route53 API regardless.
import aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_zone as zone
import aws_route53.models.v1beta1.route53_awsm_upbound_io_v1beta1_record as rec

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

_label_chars = "abcdefghijklmnopqrstuvwxyz0123456789-"

# Record name -> stable composition-resource-name fragment: "@"/"" address the
# apex, "*" spells out as wildcard, and anything else outside [a-z0-9-] (dots
# mostly) flattens to "-". Shared with the gcp backend — keep them in lockstep.
sanitize = lambda name: str -> str {
    _l = name.lower()
    "apex" if _l == "" or _l == "@" else "".join(["wildcard" if _c == "*" else (_c if _c in _label_chars else "-") for _c in _l])
}

# Stable composition-resource-name for a records[] entry, unique per
# (name, type) pair — exactly the uniqueness the XRD asks callers for.
res_name = lambda r: any -> str {
    "record-${sanitize(r.name)}-" + r["type"].lower()
}

# Relative record name -> FQDN inside the zone: "@"/"" mean the apex itself,
# wildcards pass through ("*.dev" -> "*.dev.example.com").
fqdn = lambda name: str, domain: str -> str {
    domain if name == "" or name == "@" else "${name}.${domain}"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _domain = _spec.domain
    _records = _spec?.records or []

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [zone.Zone {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        # The apex NS/SOA record sets are created and managed by Route53
        # itself — records[] must not declare them.
        spec.forProvider.name = _domain
        spec.forProvider.comment = "DnsZone ${_name} (managed by Crossplane)"
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # aws_route53_record carries no tags argument, so spec.tags stops at the zone.
    _items += [rec.Record {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = res_name(_r)}
        if _mp:
            spec.managementPolicies = _mp
        # Bind to the zone by controller ref, not by id, so records wait for
        # it instead of racing its creation.
        spec.forProvider.zoneIdSelector = {matchControllerRef = True}
        spec.forProvider.name = fqdn(_r.name, _domain)
        spec.forProvider.$type = _r["type"]
        spec.forProvider.ttl = _r?.ttl or 300
        # Route53 takes rdata in native zone-file form: MX/SRV priorities stay
        # inline in the value and TXT needs no extra quoting — pass verbatim.
        spec.forProvider.records = _r["values"]
    } for _r in _records]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _ns = _at?.nameServers or []
    _zone_id = (_at?.zoneId) or (_at?.id)

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "DnsZone"
        metadata.name = _name
        status = {
            provider = "aws"
            # The zone only answers once Route53 hands back its delegation set.
            ready = len(_ns) > 0
            nameServers = _ns
            if _zone_id:
                zoneId = _zone_id
                "cloud-url" = "https://console.aws.amazon.com/route53/v2/hostedzones#ListRecordSets/${_zone_id}"
            if _at?.arn:
                arn = _at.arn
            if _at?.id:
                id = _at.id
        }
    }
}
