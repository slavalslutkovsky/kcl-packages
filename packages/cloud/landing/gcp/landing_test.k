# Unit tests for the landing (gcp) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (GCS bucket + objects, optional CDN load balancer)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
import .landing

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_html = "<!doctype html><html><body><h1>demo</h1></body></html>"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "LandingPage"
        metadata = {name = "demo", namespace = "apps"}
        spec = {region = "europe-west1", content = {html = _html}} | extra
    }
}

# The composition-resource-names of a render(), in order.
_names = lambda extra: any -> [str] {
    [r.metadata.annotations["krm.kcl.dev/composition-resource-name"] for r in landing.render(_build(extra))]
}

# The composed resource carrying the given composition-resource-name.
_res = lambda extra: any, name: str -> any {
    _hits = [r for r in landing.render(_build(extra)) if r.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name]
    assert len(_hits) == 1, "expected exactly one resource named ${name}, got ${len(_hits)}"
    _hits[0]
}

# ---- render: default resource set -------------------------------------------

# Defaults (no domain, CDN on): the bucket, its public binding, the index
# object, and the load balancer terminating plain HTTP on the anycast IP.
test_render_minimal = lambda {
    items = landing.render(_build({}))
    assert _names({}) == [
        "managed"
        "iam-public"
        "object-index"
        "backend-bucket"
        "url-map"
        "address"
        "http-proxy"
        "forwarding-rule"
    ], "the default render must compose the bucket, its objects and the HTTP load balancer, in that order"
    assert all r in items {
        r.metadata?.namespace == Undefined
    }, "composed resources carry no namespace — Crossplane places them"
    assert items[0].apiVersion == "storage.gcp.m.upbound.io/v1beta1", "the content store is a GCS Bucket"
    assert items[0].kind == "Bucket", "the content store is a GCS Bucket"
}

# ---- render: the bucket ------------------------------------------------------
test_bucket = lambda {
    _fp = _res({
        tags = {team = "platform"}
    }, "managed").spec.forProvider
    assert _fp.location == "europe-west1", "spec.region is the GCS location"
    assert _fp.uniformBucketLevelAccess == True, "object ACLs are off; the IAM binding is the only grant"
    assert _fp.publicAccessPrevention == "inherited", "an allUsers binding cannot be applied to a bucket that enforces public access prevention"
    assert _fp.forceDestroy == True, "the XR owns every object, so deleting it must not wedge on a non-empty bucket"
    assert _fp.labels == {team = "platform"}, "tags become GCS labels"
    assert _res({}, "managed").spec.forProvider?.labels == Undefined, "no labels unless tags are asked for"
    assert _res({}, "managed").metadata.annotations["crossplane.io/external-name"] == "demo", "the globally unique bucket name is pinned to the XR name"
}

# The website block is where the index and the 404 document are recorded.
test_bucket_website = lambda {
    _default = _res({}, "managed").spec.forProvider.website
    assert _default.mainPageSuffix == "index.html", "content.index must default to index.html"
    assert _default.notFoundPage == "404.html", "content.errorDocument must default to 404.html"
    _custom = _res({
        content = {html = _html, index = "home.html", errorDocument = "oops.html"}
    }, "managed").spec.forProvider.website
    assert _custom.mainPageSuffix == "home.html", "content.index is the directory index"
    assert _custom.notFoundPage == "oops.html", "content.errorDocument is served for a 404"
}

# Public reads are an IAM binding on the composed bucket, nothing else.
test_public_binding = lambda {
    _fp = _res({}, "iam-public").spec.forProvider
    assert _fp.bucketSelector.matchControllerRef == True, "the binding must attach to this XR's own bucket"
    assert _fp.role == "roles/storage.objectViewer", "reading objects is the only grant a landing page needs"
    assert _fp.member == "allUsers", "a landing page is public"
}

# ---- render: content objects -------------------------------------------------

# The index document is always text/html under content.index; every companion
# file becomes its own object, named by its sanitized path.
test_content_objects = lambda {
    _spec = {
        content = {
            html = _html
            index = "home.html"
            files = [
                {path = "styles.css", content = "body{}"}
                {path = "assets/Logo.SVG", content = "<svg/>"}
                {path = "data.bin", content = "raw"}
                {path = "manifest.json", content = "{}", contentType = "application/manifest+json"}
            ]
        }
    }
    assert _names(_spec)[2:6:] == [
        "object-index"
        "object-styles-css"
        "object-assets-logo-svg"
        "object-data-bin"
    ], "the index leads, then one object per file, each keyed by its path lowercased with every other character turned into a dash"
    _index = _res(_spec, "object-index").spec.forProvider
    assert _index.name == "home.html", "the index document lands under content.index"
    assert _index.content == _html, "the index document is content.html verbatim"
    assert _index.contentType == "text/html", "content.html is always served as text/html"
    assert _index.bucketSelector.matchControllerRef == True, "objects must land in this XR's own bucket"
    assert _res(_spec, "object-styles-css").spec.forProvider.contentType == "text/css", "a .css file derives text/css"
    assert _res(_spec, "object-assets-logo-svg").spec.forProvider.contentType == "image/svg+xml", "the extension is matched case-insensitively"
    assert _res(_spec, "object-assets-logo-svg").spec.forProvider.name == "assets/Logo.SVG", "the object key keeps the path verbatim; only the resource name is sanitized"
    assert _res(_spec, "object-data-bin").spec.forProvider.contentType == "application/octet-stream", "an unknown extension falls back to application/octet-stream"
    assert _res(_spec, "object-manifest-json").spec.forProvider.contentType == "application/manifest+json", "an explicit contentType beats the derived one"
}

# Every object carries the CDN TTL as its Cache-Control, so the browser cache
# and the edge cache expire together.
test_object_cache_control = lambda {
    _files = [{path = "styles.css", content = "body{}"}]
    assert _res({
        content = {html = _html, files = _files}
    }, "object-index").spec.forProvider.cacheControl == "public, max-age=3600", "cdn.ttlSeconds must default to 3600"
    _tuned = {cdn = {ttlSeconds = 60}, content = {html = _html, files = _files}}
    assert _res(_tuned, "object-index").spec.forProvider.cacheControl == "public, max-age=60", "cdn.ttlSeconds must reach the index object"
    assert _res(_tuned, "object-styles-css").spec.forProvider.cacheControl == "public, max-age=60", "cdn.ttlSeconds must reach every file object"
    assert _res({cdn = {ttlSeconds = 0}, content = {html = _html}}, "object-index").spec.forProvider.cacheControl == "public, max-age=0", "a zero TTL is a legitimate value, not a missing one"
}

# ---- render: the CDN load balancer -------------------------------------------
test_backend_bucket = lambda {
    _fp = _res({
        cdn = {ttlSeconds = 1800}
    }, "backend-bucket").spec.forProvider
    assert _fp.bucketNameSelector.matchControllerRef == True, "the backend must read this XR's own bucket"
    assert _fp.enableCdn == True, "the backend bucket is what turns Cloud CDN on"
    assert _fp.cdnPolicy.cacheMode == "CACHE_ALL_STATIC", "static files are cached without asking the origin for headers"
    assert _fp.cdnPolicy.defaultTtl == 1800, "cdn.ttlSeconds is the edge TTL"
    assert _fp.cdnPolicy.clientTtl == 1800, "cdn.ttlSeconds is also what the browser is told"
    assert _fp.cdnPolicy.maxTtl == 86400, "nothing stays at the edge longer than a day"
    assert _res({}, "url-map").spec.forProvider.defaultServiceSelector.matchControllerRef == True, "every path goes to this XR's backend bucket"
    assert _res({}, "address").spec.forProvider.addressType == "EXTERNAL", "the page is served from a public anycast IP"
}

# A domain with TLS: Google-managed certificate on an HTTPS proxy, port 443.
test_https_path = lambda {
    _spec = {domain = "www.acme.example"}
    _names_https = _names(_spec)
    assert "certificate" in _names_https, "a domain with TLS must compose a Google-managed certificate"
    assert "https-proxy" in _names_https, "a domain with TLS terminates on an HTTPS proxy"
    assert not ("http-proxy" in _names_https), "HTTPS replaces the plain HTTP proxy; this XR composes no redirect"
    assert _res(_spec, "certificate").spec.forProvider.managed.domains == ["www.acme.example"], "the certificate covers spec.domain"
    _proxy = _res(_spec, "https-proxy").spec.forProvider
    assert _proxy.urlMapSelector.matchControllerRef == True, "the proxy must serve this XR's URL map"
    assert _proxy.sslCertificatesSelector.matchControllerRef == True, "the proxy must present this XR's certificate"
    assert _res(_spec, "forwarding-rule").spec.forProvider.portRange == "443", "HTTPS answers on 443"
    assert _res(_spec, "forwarding-rule").spec.forProvider.loadBalancingScheme == "EXTERNAL_MANAGED", "the global external Application Load Balancer is the only Cloud CDN front door"
}

# No domain, or TLS switched off: plain HTTP on 80 and no certificate, because
# a Google-managed certificate only exists for a domain.
_serves_plain_http = lambda extra: any -> bool {
    _plain = _names(extra)
    assert "http-proxy" in _plain, "without HTTPS the load balancer terminates plain HTTP"
    assert not ("certificate" in _plain), "no certificate without a domain served over TLS"
    assert not ("https-proxy" in _plain), "no HTTPS proxy without a certificate to present"
    assert _res(extra, "http-proxy").spec.forProvider.urlMapSelector.matchControllerRef == True, "the proxy must serve this XR's URL map"
    assert _res(extra, "forwarding-rule").spec.forProvider.portRange == "80", "plain HTTP answers on 80"
    True
}

test_http_path = lambda {
    assert _serves_plain_http({}), "no domain means no certificate, so plain HTTP"
    assert _serves_plain_http({domain = "www.acme.example", tls = {enabled = False}}), "tls.enabled=false drops the HTTPS proxy, leaving plain HTTP on the domain"
}

# ---- render: cdn.enabled=false -----------------------------------------------

# Without the CDN there is no load balancer at all: the bucket endpoint is the
# whole service.
#
# The same spec plus spec.domain is REJECTED by render() — nothing composed here
# could carry a domain or a certificate. A KCL assert failure cannot be caught
# from a test, so what is asserted is the rejecting condition itself: the
# composed set contains no compute resource, i.e. nowhere for a domain to live.
test_cdn_disabled = lambda {
    _spec = {
        cdn = {enabled = False}
    }
    _items = landing.render(_build(_spec))
    assert _names(_spec) == ["managed", "iam-public", "object-index"], "cdn.enabled=false composes the bucket, its binding and the objects, nothing else"
    assert all r in _items {
        r.apiVersion == "storage.gcp.m.upbound.io/v1beta1"
    }, "cdn.enabled=false composes no compute resource, which is exactly why spec.domain is rejected with it"
    assert _res(_spec, "managed").spec.forProvider.website.mainPageSuffix == "index.html", "the bucket still serves a directory index of its own"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy = lambda {
    _spec = {domain = "www.acme.example", deletionPolicy = "Orphan", content = {html = _html, files = [{path = "styles.css", content = "body{}"}]}}
    _orphaned = landing.render(_build(_spec))
    assert all r in _orphaned {
        r.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every MR, including the objects and the load balancer"
    _deleted = landing.render(_build({domain = "www.acme.example"}))
    assert all r in _deleted {
        not (r.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status: before observation ----------------------------------------------
test_status_pre_creation = lambda {
    dxr = landing.status(_build({domain = "www.acme.example"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "LandingPage", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must address the composite by name"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.ready == False, "nothing is serving before the forwarding rule holds an IP"
    assert dxr.status.cdn == True, "the CDN defaults on"
    assert dxr.status.bucketName == "demo", "the bucket name is known ahead of creation — it is pinned to the XR name"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/storage/browser/demo", "cloud-url must point at the bucket in the console"
    assert dxr.status.host == "www.acme.example", "the custom domain is the host from the start"
    assert dxr.status.url == "https://www.acme.example", "a domain with TLS is served over HTTPS"
    assert dxr.status.dnsRecordType == "A", "a global address is an IP, so the domain needs an A record"
    assert dxr.status?.dnsTarget == Undefined, "no address to point the record at before the load balancer exists"
    assert dxr.status?.id == Undefined, "no edge id before the forwarding rule exists"
    assert dxr.status?.arn == Undefined, "arn is AWS-only"
}

# With no domain, the address is the only host there is — unknown until observed.
test_status_no_domain = lambda {
    dxr = landing.status(_build({}), {})
    assert dxr.status?.host == Undefined, "without a domain there is no host until the address is observed"
    assert dxr.status?.url == Undefined, "without a host there is no URL"
    assert dxr.status.dnsRecordType == "A", "whatever name is pointed here must be an A record"
}

# ---- status: after observation -----------------------------------------------
_observed = {
    managed.Resource.status.atProvider.id = "demo"
    address.Resource.status.atProvider.address = "203.0.113.10"
    "forwarding-rule" = {
        Resource.status.atProvider = {
            ipAddress = "203.0.113.10"
            id = "projects/p/global/forwardingRules/demo"
        }
    }
    certificate.Resource.status.atProvider = {
        certificateId = "12345"
        managed.domains = ["www.acme.example"]
    }
}

test_status_observed = lambda {
    dxr = landing.status(_build({domain = "www.acme.example"}), _observed)
    assert dxr.status.ready == True, "an observed forwarding rule with an IP means the page is being served"
    assert dxr.status.dnsTarget == "203.0.113.10", "the DNS record must point at the observed global address"
    assert dxr.status.dnsRecordType == "A", "an IP target is an A record"
    assert dxr.status.host == "www.acme.example", "the custom domain stays the host"
    assert dxr.status.url == "https://www.acme.example", "TLS on the domain means an https URL"
    assert dxr.status.id == "projects/p/global/forwardingRules/demo", "the edge id is the forwarding rule's"
    assert dxr.status.bucketName == "demo", "the observed bucket id is its name"
    plain = landing.status(_build({domain = "www.acme.example", tls = {enabled = False}}), _observed)
    assert plain.status.url == "http://www.acme.example", "tls.enabled=false serves the custom domain over plain HTTP"

    # Cloud DNS-style ownership proof does not exist here: Google validates the
    # managed certificate through the load balancer once the A record resolves,
    # and the generated ManagedSSLCertificate reports no provisioning state.
    assert dxr.status?.validationRecords == Undefined, "GCP needs no validation records"
    assert dxr.status?.certificateStatus == Undefined, "the managed certificate reports no state at provider"
}

# Without a domain the page answers on the observed IP, over plain HTTP.
test_status_observed_no_domain = lambda {
    dxr = landing.status(_build({}), _observed)
    assert dxr.status.host == "203.0.113.10", "the anycast IP is the only host"
    assert dxr.status.url == "http://203.0.113.10", "no domain means no certificate, so no HTTPS"
    assert dxr.status.ready == True, "the load balancer serving on an IP is ready"
}

# ---- status: cdn.enabled=false -----------------------------------------------
test_status_without_cdn = lambda {
    _spec = {cdn = {enabled = False}, content = {html = _html, index = "home.html"}}
    dxr = landing.status(_build(_spec), {})
    assert dxr.status.cdn == False, "no edge cache is in front of the content"
    assert dxr.status.ready == False, "nothing is serving before the bucket exists"
    assert dxr.status.host == "storage.googleapis.com", "the raw bucket endpoint is the host"
    assert dxr.status.url == "https://storage.googleapis.com/demo/home.html", "the page is the index object under the bucket endpoint"
    assert dxr.status?.dnsTarget == Undefined, "nothing to point a record at — a bucket endpoint serves no custom domain"
    assert dxr.status?.dnsRecordType == Undefined, "no record type either"
    observed = landing.status(_build(_spec), _observed)
    assert observed.status.ready == True, "an observed bucket is the whole service without the CDN"
    assert observed.status?.id == Undefined, "there is no edge resource to report an id for"
}
