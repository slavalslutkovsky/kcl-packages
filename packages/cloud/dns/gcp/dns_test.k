import .dns

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "DnsZone", metadata.name = "demo", spec = _spec}
}

# The record MRs from a render() (everything after the leading zone).
_recs = lambda _spec {
    dns.render(_build(_spec))[1::]
}

# ---- render: shape ----------------------------------------------------------

# No records -> exactly the ManagedZone.
test_render_minimal = lambda {
    items = dns.render(_build({region = "europe-west1", domain = "example.com"}))
    assert len(items) == 1, "no records must render exactly one ManagedZone"
    assert items[0].apiVersion == "dns.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "ManagedZone", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the zone name is the external-name, pinned to the XR name"
    fp = items[0].spec.forProvider
    assert fp.dnsName == "example.com.", "dnsName must be the apex with a trailing dot"
    assert fp.description == "DnsZone demo (managed by Crossplane)", "description must be deterministic"
    assert fp?.labels == Undefined, "no labels unless tags are asked for"
}

# ---- render: records fan-out ------------------------------------------------

# One RecordSet per entry; every record name is an FQDN with a trailing dot.
test_records_fan_out = lambda {
    recs = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "@", "type" = "TXT", values = ["v=spf1 -all"]}
        {name = "api", "type" = "A", values = ["203.0.113.7"]}
        {name = "*.dev", "type" = "CNAME", values = ["ghs.googlehosted.com"]}
    ]})
    assert len(recs) == 3, "one RecordSet per records entry"
    assert all r in recs {
        r.kind == "RecordSet"
    }, "records must render RecordSets"
    assert recs[0].spec.forProvider.name == "example.com.", "@ must address the apex, trailing dot included"
    assert recs[1].spec.forProvider.name == "api.example.com.", "relative names get the apex appended, trailing dot included"
    assert recs[2].spec.forProvider.name == "*.dev.example.com.", "wildcard names get the apex appended, trailing dot included"
    assert all r in recs {
        r.spec.forProvider.managedZoneSelector.matchControllerRef == True
    }, "records must bind the zone by controller ref"
}

# "" is the other apex spelling.
test_empty_name_is_apex = lambda {
    rec = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "", "type" = "A", values = ["203.0.113.7"]}
    ]})[0]
    assert rec.spec.forProvider.name == "example.com.", "an empty name must address the apex"
    assert rec.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "record-apex-a", "empty name sanitizes to apex"
}

# ---- render: type, ttl, rdata -----------------------------------------------
test_type_and_ttl = lambda {
    recs = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "api", "type" = "A", values = ["203.0.113.7"]}
        {name = "api", "type" = "AAAA", ttl = 60, values = ["2001:db8::7"]}
    ]})
    assert recs[0].spec.forProvider["type"] == "A", "record type must be carried"
    assert recs[0].spec.forProvider.ttl == 300, "ttl must default to 300"
    assert recs[1].spec.forProvider["type"] == "AAAA", "record type must be carried"
    assert recs[1].spec.forProvider.ttl == 60, "an explicit ttl must be carried"
}

# MX/SRV priorities stay inline — native zone-file form on Cloud DNS.
test_multi_value_rdata = lambda {
    rec = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "@", "type" = "MX", values = ["10 mx1.example.com.", "20 mx2.example.com."]}
    ]})[0]
    assert rec.spec.forProvider.rrdatas == ["10 mx1.example.com.", "20 mx2.example.com."], "multiple values become one multi-value record set"
}

# Cloud DNS splits unquoted TXT rdata on spaces; quoting is added exactly once.
test_txt_quoting = lambda {
    rec = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "@", "type" = "TXT", values = ["v=spf1 include:_spf.google.com ~all", "\"already quoted\""]}
    ]})[0]
    assert rec.spec.forProvider.rrdatas == ["\"v=spf1 include:_spf.google.com ~all\"", "\"already quoted\""], "TXT values must be quoted once"
    plain = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "www", "type" = "CNAME", values = ["ghs.googlehosted.com"]}
    ]})[0]
    assert plain.spec.forProvider.rrdatas == ["ghs.googlehosted.com"], "non-TXT rdata must pass verbatim"
}

# ---- render: resource-name sanitization --------------------------------------
test_resource_name_sanitization = lambda {
    assert dns.resource_name_for("@", "TXT") == "record-apex-txt", "@ -> apex"
    assert dns.resource_name_for("", "A") == "record-apex-a", "empty -> apex"
    assert dns.resource_name_for("api", "A") == "record-api-a", "plain names pass through"
    assert dns.resource_name_for("*", "A") == "record-wildcard-a", "* -> wildcard"
    assert dns.resource_name_for("*.dev", "CNAME") == "record-wildcard-dev-cname", "wildcard subdomains sanitize the dot"
    assert dns.resource_name_for("_dmarc", "TXT") == "record--dmarc-txt", "underscores sanitize to dashes"
    assert dns.resource_name_for("API.Sub", "MX") == "record-api-sub-mx", "names are lowercased and dots become dashes"
    recs = _recs({region = "europe-west1", domain = "example.com", records = [
        {name = "*.dev", "type" = "CNAME", values = ["ghs.googlehosted.com"]}
    ]})
    assert recs[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "record-wildcard-dev-cname", "the annotation must carry the sanitized name"
}

# ---- render: labels ----------------------------------------------------------

# Tags land on the zone only. That records carry no labels is enforced by the
# schema, not here: RecordSetSpecForProvider has no `labels` attribute at all,
# so even `items[1].spec.forProvider?.labels` is a compile error ("attribute
# 'labels' not found") rather than an assertion that can pass.
test_tags_zone_only = lambda {
    items = dns.render(_build({region = "europe-west1", domain = "example.com", tags = {team = "platform"}, records = [
        {name = "api", "type" = "A", values = ["203.0.113.7"]}
    ]}))
    assert items[0].spec.forProvider.labels == {team = "platform"}, "tags -> zone labels"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _spec = {region = "europe-west1", domain = "example.com", deletionPolicy = "Orphan", records = [
        {name = "api", "type" = "A", values = ["203.0.113.7"]}
    ]}
    _orphaned = dns.render(_build(_spec))
    assert all r in _orphaned {
        r.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every MR"
    _deleted = dns.render(_build({region = "europe-west1", domain = "example.com", records = _spec.records}))
    assert all r in _deleted {
        not (r.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = dns.status(_build({region = "europe-west1", domain = "example.com"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "DnsZone", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "no observed name servers -> not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.zoneId == "demo", "the zone id is the zone name, known ahead of creation"
    assert dxr.status.nameServers == [], "no name servers before the zone exists"
    assert dxr.status?.id == Undefined, "no id before the zone exists"
    assert dxr.status?.arn == Undefined, "arn is AWS-only"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/net-services/dns/zones/demo/details", "cloud-url must point at the Cloud DNS console"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        id = "projects/p/managedZones/demo"
                        project = "p"
                        nameServers = ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com."]
                    }
                }
            }
        }
    }
    dxr = dns.status(_build({region = "europe-west1", domain = "example.com"}), ocds)
    assert dxr.status.ready == True, "observed name servers must mark the zone ready"
    assert dxr.status.zoneId == "demo", "the zone id is the zone name"
    assert dxr.status.nameServers == ["ns-cloud-a1.googledomains.com.", "ns-cloud-a2.googledomains.com."], "name servers must be surfaced"
    assert dxr.status.id == "projects/p/managedZones/demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/net-services/dns/zones/demo/details?project=p", "an observed project must land in the console URL"
}
