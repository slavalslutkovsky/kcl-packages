# dns (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-dns schema package. The portable DnsZone maps onto a
# Cloud DNS ManagedZone plus one RecordSet per records[] entry. The zone name
# has no forProvider field — it is the upjet external-name. spec.region is
# ignored: Cloud DNS is global and the provider needs no API region (the XRD
# documents this).
import regex
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone as zone
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_record_set as rs

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Stable composition-resource-name per record, shared verbatim with dns/aws:
# lowercase; "@"/"" -> "apex"; "*" -> "wildcard"; anything outside [a-z0-9-]
# (dots, underscores) -> "-".
resource_name_for = lambda name: str, rtype: str -> str {
    _n = name.lower()
    _base = "apex" if _n in ["", "@"] else regex.replace(_n.replace("*", "wildcard"), "[^a-z0-9-]", "-")
    "record-${_base}-${rtype.lower()}"
}

# Relative record name -> FQDN with the trailing dot Cloud DNS requires;
# "@"/"" addresses the zone apex itself.
fqdn_for = lambda name: str, apex: str -> str {
    "${apex}." if name in ["", "@"] else "${name}.${apex}."
}

# Cloud DNS splits unquoted TXT rdata on spaces (see the RecordSet model's
# rrdatas doc), so quote each value once, leaving pre-quoted values alone.
txt_value = lambda value: str -> str {
    value if value.startswith("\"") else "\"${value}\""
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    # The XRD forbids a trailing dot on the apex, but strip one defensively.
    _apex = _spec.domain.rstrip(".")

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _zone = zone.ManagedZone {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            # forProvider carries no name field; the zone name is the
            # external-name. Cloud DNS wants [a-z][-a-z0-9]* and XR names
            # (RFC 1123 labels) already satisfy that, so the XR name is
            # used verbatim.
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        # Cloud DNS stores the apex as an FQDN — the trailing dot is required.
        spec.forProvider.dnsName = "${_apex}."
        spec.forProvider.description = "DnsZone ${_name} (managed by Crossplane)"
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
    }

    # One multi-value RecordSet per (name, type) entry. MX/SRV priorities stay
    # inline in the rdata — that is Cloud DNS's native zone-file form. The
    # RecordSet model carries no labels field, so spec.tags cannot reach it.
    _records = [rs.RecordSet {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = resource_name_for(r.name, r["type"])}
        if _mp:
            spec.managementPolicies = _mp
        # Bind the zone by controller ref, not by name, so the record waits
        # for it instead of racing its creation.
        spec.forProvider.managedZoneSelector = {matchControllerRef = True}
        spec.forProvider.name = fqdn_for(r.name, _apex)
        spec.forProvider.$type = r["type"]
        spec.forProvider.ttl = r?.ttl or 300
        spec.forProvider.rrdatas = [txt_value(v) for v in r["values"]] if r["type"] == "TXT" else r["values"]
    } for r in _spec?.records or []]

    [_zone] + _records
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _ns = _at?.nameServers or []
    _project = _at?.project

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "DnsZone"
        metadata.name = _name
        status = {
            provider = "gcp"
            # The zone only answers once it reports the name servers to
            # delegate to.
            ready = len(_ns) > 0
            # The Cloud DNS zone identifier is its name, pinned by render()
            # to the XR name — deterministic ahead of creation.
            zoneId = _name
            nameServers = _ns
            # arn is intentionally absent — AWS-only per the XRD.
            # Without an observed project the console URL stays on the zone
            # path and the console falls back to the caller's default project.
            "cloud-url" = "https://console.cloud.google.com/net-services/dns/zones/${_name}/details" + ("?project=${_project}" if _project else "")
            if _at?.id:
                id = _at.id
        }
    }
}
