import json
import .landing

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_html = "<!doctype html><html><body><h1>demo</h1></body></html>"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "LandingPage"
        metadata = {name = "demo", namespace = "apps"}
        spec = {region = "eu-west-1", content = {html = _html}} | extra
    }
}

_render = lambda extra: any, ocds: any -> any {
    landing.render(_build(extra), ocds)
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
    _pick(_render(extra, {}), name)
}

# A site with a custom domain: the shape the XRD defaults to.
_site = {
    domain = "www.example.com"
    content.files = [
        {path = "styles.css", content = "body{}"}
        {path = "404.html", content = "<h1>gone</h1>"}
    ]
}

# Observed state, one composed resource at a time.
_observed_cert = {
    certificate.Resource.status.atProvider = {
        arn = "arn:aws:acm:us-east-1:111122223333:certificate/c-1"
        status = "ISSUED"
        domainValidationOptions = [{
            domainName = "www.example.com"
            resourceRecordName = "_a1b2.www.example.com."
            resourceRecordType = "CNAME"
            resourceRecordValue = "_c3d4.acm-validations.aws."
        }]
    }
}
_observed_dist = {
    distribution.Resource.status.atProvider = {
        id = "E2QWERTY"
        arn = "arn:aws:cloudfront::111122223333:distribution/E2QWERTY"
        domainName = "d111abc.cloudfront.net"
        status = "Deployed"
    }
}
_observed_bucket = {
    managed.Resource.status.atProvider = {id = "demo", arn = "arn:aws:s3:::demo"}
}

# ---- render: resource set ----------------------------------------------------

# Content only: a bucket, its access settings, the index object and the edge.
# No domain -> no certificate; no observed distribution -> no bucket policy yet.
test_render_minimal = lambda {
    items = _render({}, {})
    assert _names(items) == ["managed", "public-access-block", "ownership", "object-index", "oac", "distribution"], "a content-only LandingPage renders the bucket, its access settings, the index object, the OAC and the distribution"
    assert all i in items {
        i.metadata?.namespace == Undefined
    }, "composed resources must carry no namespace — Crossplane places them"
    bucket = _pick(items, "managed")
    assert bucket.kind == "Bucket", "the content store must be an S3 bucket"
    assert bucket.metadata.annotations["crossplane.io/external-name"] == "demo", "the bucket name must be pinned to the XR name: the CloudFront origin host and the policy ARN are derived from it before the bucket exists"
    assert bucket.spec.forProvider.region == "eu-west-1", "the bucket must live in spec.region"
    assert bucket.spec.forProvider?.tags == Undefined, "no tags unless asked for"
}

# The default case: custom domain, TLS, companion files.
test_render_default_case = lambda {
    items = _render(_site, {})
    assert _names(items) == [
        "managed"
        "public-access-block"
        "ownership"
        "object-index"
        "object-styles-css"
        "object-404-html"
        "oac"
        "certificate"
        "distribution"
    ], "a custom domain adds the ACM certificate, and every content file adds one object"
    cert = _pick(items, "certificate")
    assert cert.kind == "Certificate", "the custom domain needs an ACM certificate"
    assert cert.spec.forProvider.region == "us-east-1", "a CloudFront viewer certificate must be issued in us-east-1, not in spec.region"
    assert cert.spec.forProvider.domainName == "www.example.com", "the certificate must cover spec.domain"
    assert cert.spec.forProvider.validationMethod == "DNS", "DNS validation is what makes the certificate issuable from a DnsZone"
}

# Nothing public is needed when CloudFront reads the bucket through the OAC.
test_public_access_is_blocked_behind_the_cdn = lambda {
    fp = _res({}, "public-access-block").spec.forProvider
    assert [fp.blockPublicAcls, fp.blockPublicPolicy, fp.ignorePublicAcls, fp.restrictPublicBuckets] == [True, True, True, True], "with the CDN in front, nothing about the bucket is public"
    assert _res({}, "ownership").spec.forProvider.rule.objectOwnership == "BucketOwnerEnforced", "ACLs are disabled; access is decided by the bucket policy alone"
}

# ---- render: origin access control ------------------------------------------
# NOTE: a local must not take the name of a module landing.k imports (`oac`,
# `acm`, `backend`, ...) — an import alias is visible package-wide, and the
# module wins over the local.
test_oac_wiring = lambda {
    items = _render(_site, {})
    ctrl = _pick(items, "oac")
    assert ctrl.kind == "OriginAccessControl", "the CDN reads the private bucket through an OAC"
    assert ctrl.spec.forProvider.name == "demo-oac", "the OAC is named after the XR"
    assert ctrl.spec.forProvider.originAccessControlOriginType == "s3", "the origin is a bucket"
    assert ctrl.spec.forProvider.signingBehavior == "always", "every origin request must be signed, or the private bucket returns 403"
    assert ctrl.spec.forProvider.signingProtocol == "sigv4", "S3 authenticates SigV4"
    origin = _pick(items, "distribution").spec.forProvider.origin[0]
    assert origin.domainName == "demo.s3.eu-west-1.amazonaws.com", "the origin must be the REST endpoint in spec.region — an OAC signs requests to the website endpoint nowhere"
    assert origin.originId == "s3-demo", "the origin id is derived from the XR name"
    assert origin.originAccessControlIdSelector.matchControllerRef == True, "the distribution must bind the OAC it was composed with"
}

# ---- render: cache behaviour -------------------------------------------------
test_default_cache_behavior = lambda {
    dcb = _res(_site, "distribution").spec.forProvider.defaultCacheBehavior
    assert dcb.targetOriginId == "s3-demo", "the default behaviour must target the composed origin"
    assert dcb.viewerProtocolPolicy == "redirect-to-https", "TLS on -> plain HTTP is redirected"
    assert dcb.allowedMethods == ["GET", "HEAD"] and dcb.cachedMethods == ["GET", "HEAD"], "a static page is read-only"
    assert dcb.compress == True, "text assets must be compressed at the edge"
    assert [dcb.minTtl, dcb.defaultTtl, dcb.maxTtl] == [0, 3600, 31536000], "cdn.ttlSeconds defaults to 3600 and only moves the default TTL"
    assert dcb.forwardedValues.queryString == False, "forwardedValues is mandatory without a cache policy, and a landing page varies on no query string"
    assert dcb.forwardedValues.cookies.forward == "none", "no cookie may reach the origin or the cache key"
    assert _res({cdn.ttlSeconds = 60} | _site, "distribution").spec.forProvider.defaultCacheBehavior.defaultTtl == 60, "an explicit ttlSeconds must reach the edge"
}

# tls is what decides whether HTTP is redirected; with no domain it is the
# CloudFront endpoint's own protocol policy.
test_tls_disabled_allows_plain_http = lambda {
    dcb = _res({tls.enabled = False}, "distribution").spec.forProvider.defaultCacheBehavior
    assert dcb.viewerProtocolPolicy == "allow-all", "tls.enabled=false must stop redirecting HTTP to HTTPS"
}

test_price_class_mapping = lambda {
    fp = lambda p: str -> any {
        _res({cdn.priceClass = p} | _site, "distribution").spec.forProvider
    }
    assert _res(_site, "distribution").spec.forProvider.priceClass == "PriceClass_100", "priceClass defaults to cheapest"
    assert fp("cheapest").priceClass == "PriceClass_100", "cheapest -> PriceClass_100"
    assert fp("most").priceClass == "PriceClass_200", "most -> PriceClass_200"
    assert fp("all").priceClass == "PriceClass_All", "all -> PriceClass_All"
    assert _res(_site, "distribution").spec.forProvider.restrictions.geoRestriction.restrictionType == "none", "the page is served everywhere the price class reaches"
    assert _res(_site, "distribution").spec.forProvider.waitForDeployment == False, "the MR must not block a reconcile for the ~15 minutes a distribution takes to deploy"
}

# ---- render: viewer certificate (second pass) --------------------------------

# The Distribution schema carries acmCertificateArn as a plain string with no
# ref/selector, so the alias and its certificate can only be attached once ACM
# has been observed — and CloudFront refuses an alias the attached certificate
# does not cover, so the two must appear together.
test_viewer_certificate_before_observation = lambda {
    fp = _res(_site, "distribution").spec.forProvider
    assert fp.viewerCertificate.cloudfrontDefaultCertificate == True, "without an observed certificate the distribution serves its own *.cloudfront.net certificate"
    assert fp.viewerCertificate?.acmCertificateArn == Undefined, "there is no certificate ARN to attach yet"
    assert fp?.aliases == Undefined, "no alias may be attached before the certificate that covers it"
}

test_viewer_certificate_after_observation = lambda {
    fp = _pick(_render(_site, _observed_cert), "distribution").spec.forProvider
    assert fp.aliases == ["www.example.com"], "the observed certificate lets the custom domain be attached"
    assert fp.viewerCertificate.acmCertificateArn == "arn:aws:acm:us-east-1:111122223333:certificate/c-1", "the observed ACM certificate must be the one served"
    assert fp.viewerCertificate.sslSupportMethod == "sni-only", "a dedicated IP costs money no landing page needs"
    assert fp.viewerCertificate.minimumProtocolVersion == "TLSv1.2_2021", "the protocol floor must be a modern one"
    assert fp.viewerCertificate?.cloudfrontDefaultCertificate == Undefined, "the default certificate does not cover the custom domain"
}

# No domain -> no certificate to wait for, and the default certificate stays.
test_no_domain_keeps_the_default_certificate = lambda {
    items = _render({}, _observed_cert)
    assert "certificate" not in _names(items), "no domain, no certificate"
    fp = _pick(items, "distribution").spec.forProvider
    assert fp?.aliases == Undefined, "no domain, no alias"
    assert fp.viewerCertificate.cloudfrontDefaultCertificate == True, "no domain, the CloudFront certificate is the only one"
}

# ---- render: content objects -------------------------------------------------
test_index_object = lambda {
    idx = _res(_site, "object-index").spec.forProvider
    assert idx.key == "index.html", "content.index defaults to index.html"
    assert idx.content == _html, "content.html is the index document, verbatim"
    assert idx.contentType == "text/html", "the index document is always HTML"
    assert idx.bucketSelector.matchControllerRef == True, "objects must bind the bucket they were composed with"
    assert idx.region == "eu-west-1", "objects live in the bucket's region"
    assert _res({content.index = "home.html"}, "object-index").spec.forProvider.key == "home.html", "an explicit content.index must be the object key"
}

test_content_type_derivation = lambda {
    items = _render({content.files = [
        {path = "styles.css", content = "body{}"}
        {path = "assets/logo.SVG", content = "<svg/>"}
        {path = "data.bin", content = "x"}
        {path = "app.js", content = "//", contentType = "application/javascript"}
    ]}, {})
    assert _pick(items, "object-styles-css").spec.forProvider.contentType == "text/css", "css -> text/css"
    assert _pick(items, "object-assets-logo-svg").spec.forProvider.contentType == "image/svg+xml", "the extension is matched case-insensitively"
    assert _pick(items, "object-data-bin").spec.forProvider.contentType == "application/octet-stream", "an unknown extension falls back to the catch-all"
    assert _pick(items, "object-app-js").spec.forProvider.contentType == "application/javascript", "an explicit contentType wins over the derived one"
    assert _pick(items, "object-assets-logo-svg").spec.forProvider.key == "assets/logo.SVG", "the object key is the path verbatim — only the resource name is sanitized"
}

# The slug is part of the contract: renaming a composed resource deletes and
# recreates the object it names.
test_resource_name_slug = lambda {
    items = _render({content.files = [
        {path = "assets/Logo_2x.png", content = "x"}
        {path = "robots.txt", content = "x"}
    ]}, {})
    assert _names(items)[4:6:] == ["object-assets-logo-2x-png", "object-robots-txt"], "a file's resource name is its path lowercased with everything outside [a-z0-9-] replaced by a dash"
}

# ---- render: custom error response -------------------------------------------

# CloudFront would answer every 404 with a 404 for the error page itself if the
# key were never uploaded, so the mapping follows the files, not the field.
test_custom_error_response = lambda {
    with_page = _res(_site, "distribution").spec.forProvider
    err = with_page.customErrorResponse
    assert len(err) == 1, "one mapping for the one error document"
    assert err[0].errorCode == 404 and err[0].responseCode == 404, "a missing key stays a 404 — the error page is not a redirect"
    assert err[0].responsePagePath == "/404.html", "a 404.html file must be served for 404s"
    without_page = _res({content.files = [{path = "styles.css", content = "body{}"}]}, "distribution").spec.forProvider
    assert without_page?.customErrorResponse == Undefined, "no file matching content.errorDocument -> nothing to serve for a 404"
    renamed = _res({
        content = {errorDocument = "oops.html", files = [{path = "oops.html", content = "x"}]}
    }, "distribution").spec.forProvider
    assert renamed.customErrorResponse[0].responsePagePath == "/oops.html", "an explicit content.errorDocument must be the served page"
}

# ---- render: bucket policy (second pass) -------------------------------------
test_bucket_policy_needs_the_distribution_arn = lambda {
    assert "bucket-policy" not in _names(_render(_site, {})), "no distribution ARN, no policy: the objects stay unreadable, which is the safe state"
    assert "bucket-policy" not in _names(_render(_site, _observed_cert)), "an observed certificate is not enough — the policy condition names the distribution"
    items = _render(_site, _observed_dist)
    assert "bucket-policy" in _names(items), "an observed distribution ARN must produce the policy that lets it read the bucket"
    pol = _pick(items, "bucket-policy")
    assert pol.spec.forProvider.bucketSelector.matchControllerRef == True, "the policy must bind the composed bucket"
    doc = json.decode(pol.spec.forProvider.policy)
    stmt = doc.Statement[0]
    assert stmt.Effect == "Allow" and stmt.Action == "s3:GetObject", "CloudFront may read the objects and nothing else"
    assert stmt.Principal == {Service = "cloudfront.amazonaws.com"}, "the grant is to the CloudFront service principal, not to the world"
    assert stmt.Resource == "arn:aws:s3:::demo/*", "the grant covers the objects, not the bucket itself"
    assert stmt.Condition.StringEquals["AWS:SourceArn"] == "arn:aws:cloudfront::111122223333:distribution/E2QWERTY", "only this distribution may read the bucket"
}

# ---- render: no CDN ----------------------------------------------------------

# render() asserts `not domain or cdn`, and a failing KCL assert aborts the run
# rather than something a test can catch — so what is asserted here is the
# rejecting condition itself: with the CDN off nothing in the render can reach
# a custom domain (no edge, no alias, no certificate) and the only address is
# the bucket's own HTTP website endpoint. spec.domain is rejected for exactly
# that reason.
test_cdn_disabled_serves_the_website_endpoint = lambda {
    items = _render({cdn.enabled = False} | _site | {domain = Undefined}, {})
    assert _names(items) == [
        "managed"
        "public-access-block"
        "ownership"
        "object-index"
        "object-styles-css"
        "object-404-html"
        "website"
        "bucket-policy"
    ], "with no CDN the bucket serves itself: a website configuration and a public policy replace the edge"
    assert "distribution" not in _names(items) and "oac" not in _names(items) and "certificate" not in _names(items), "no edge means no alias and no certificate, which is why spec.domain is rejected here"
    web = _pick(items, "website").spec.forProvider
    assert web.indexDocument.suffix == "index.html", "the website endpoint resolves directory requests to content.index"
    assert web.errorDocument.key == "404.html", "the website endpoint serves content.errorDocument for a 404"
    fp = _pick(items, "public-access-block").spec.forProvider
    assert [fp.blockPublicAcls, fp.blockPublicPolicy, fp.ignorePublicAcls, fp.restrictPublicBuckets] == [False, False, False, False], "a blocked bucket policy would turn every website request into a 403"
    doc = json.decode(_pick(items, "bucket-policy").spec.forProvider.policy)
    assert doc.Statement[0].Principal == "*", "the website endpoint authenticates nothing, so the read must be anonymous"
    assert doc.Statement[0].Resource == "arn:aws:s3:::demo/*", "anonymous read covers the objects only"
    assert doc.Statement[0]?.Condition == Undefined, "there is no distribution to condition the grant on"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy = lambda {
    orphaned = _render({deletionPolicy = "Orphan"} | _site, _observed_dist)
    assert all r in orphaned {
        r.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every composed managed resource"
    deleted = _render(_site, _observed_dist)
    assert all r in deleted {
        not (r.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- render: tags ------------------------------------------------------------
test_tags = lambda {
    items = _render({
        tags = {team = "platform"}
    } | _site, {})
    assert _pick(items, "managed").spec.forProvider.tags == {team = "platform"}, "tags must reach the bucket"
    assert _pick(items, "distribution").spec.forProvider.tags == {team = "platform"}, "tags must reach the distribution"
    assert _pick(items, "certificate").spec.forProvider.tags == {team = "platform"}, "tags must reach the certificate"
}

# ---- status ------------------------------------------------------------------
test_status_pre_observation = lambda {
    dxr = landing.status(_build(_site), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "LandingPage", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr name must echo the composite"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.ready == False, "nothing is deployed before the distribution is observed"
    assert dxr.status.cdn == True, "the CDN is on by default"
    assert dxr.status.bucketName == "demo", "the bucket name is known ahead of creation — it is pinned to the XR name"
    assert dxr.status.url == "https://www.example.com", "the custom domain is the address the page will answer on"
    assert dxr.status?.host == Undefined, "no edge hostname before the distribution exists"
    assert dxr.status?.dnsTarget == Undefined, "nothing to point DNS at yet"
    assert dxr.status?.dnsRecordType == Undefined, "no target, no record type"
    assert dxr.status?.arn == Undefined and dxr.status?.id == Undefined, "no distribution, no identifiers"
    assert dxr.status?["cloud-url"] == Undefined, "a distribution is listed in the console by id, which does not exist yet"
    assert dxr.status?.validationRecords == Undefined, "ACM publishes its validation records only once the certificate is requested"
    assert dxr.status?.certificateStatus == Undefined, "no certificate, no certificate status"
}

test_status_observed = lambda {
    dxr = landing.status(_build(_site), _observed_bucket | _observed_dist | _observed_cert)
    assert dxr.status.ready == True, "a Deployed distribution means the page is being served"
    assert dxr.status.host == "d111abc.cloudfront.net", "the edge hostname is the distribution's"
    assert dxr.status.dnsTarget == "d111abc.cloudfront.net", "a DnsZone must point spec.domain at the distribution"
    assert dxr.status.dnsRecordType == "CNAME", "a CloudFront domain is reachable by CNAME"
    assert dxr.status.url == "https://www.example.com", "the custom domain stays the advertised address"
    assert dxr.status.arn == "arn:aws:cloudfront::111122223333:distribution/E2QWERTY", "the distribution ARN must be surfaced"
    assert dxr.status.id == "E2QWERTY", "the distribution id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.aws.amazon.com/cloudfront/v4/home#/distributions/E2QWERTY", "cloud-url must point at the distribution in the console"
    assert dxr.status.validationRecords == [{
        name = "_a1b2.www.example.com."
        type = "CNAME"
        value = "_c3d4.acm-validations.aws."
    }], "the ACM validation options must be surfaced as records a DnsZone can create"
    assert dxr.status.certificateStatus == "ISSUED", "the certificate state must be surfaced"
}

# A distribution that exists but is still rolling out is not serving yet.
test_status_distribution_in_progress = lambda {
    ocds = {
        distribution.Resource.status.atProvider = {
            id = "E2QWERTY"
            domainName = "d111abc.cloudfront.net"
            status = "InProgress"
        }
    }
    dxr = landing.status(_build(_site), ocds)
    assert dxr.status.ready == False, "only a Deployed distribution is ready"
    assert dxr.status.dnsTarget == "d111abc.cloudfront.net", "the DNS target is known before the rollout finishes"
}

# Without a domain the distribution's own hostname is the address.
test_status_without_domain = lambda {
    dxr = landing.status(_build({}), _observed_dist)
    assert dxr.status.url == "https://d111abc.cloudfront.net", "no custom domain -> the CloudFront domain is the address"
    assert dxr.status.host == "d111abc.cloudfront.net", "the host is the CloudFront domain"
}

test_status_without_cdn = lambda {
    spec = {cdn.enabled = False}
    pre = landing.status(_build(spec), {})
    assert pre.status.cdn == False, "no distribution was composed"
    assert pre.status.ready == False, "the bucket has not been observed yet"
    assert pre.status.host == "demo.s3-website-eu-west-1.amazonaws.com", "the website endpoint is derivable from the pinned bucket name and region"
    assert pre.status.dnsTarget == "demo.s3-website-eu-west-1.amazonaws.com", "the website endpoint is the only thing DNS could point at"
    assert pre.status.dnsRecordType == "CNAME", "an S3 website endpoint is reachable by CNAME"
    assert pre.status.url == "http://demo.s3-website-eu-west-1.amazonaws.com", "an S3 website endpoint serves plain HTTP only"
    assert pre.status["cloud-url"] == "https://s3.console.aws.amazon.com/s3/buckets/demo?region=eu-west-1", "cloud-url must point at the bucket in the console"
    assert pre.status?.arn == Undefined, "arn reports the distribution, of which there is none"
    obs = landing.status(_build(spec), _observed_bucket)
    assert obs.status.ready == True, "an observed bucket is all there is to be ready"
    assert obs.status.id == "demo", "the observed bucket id is the id of the thing serving the page"
}
