import .landing

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` / `ocds`
# parameters — KCL normalizes the leading underscore, so a helper named
# `_oxr` shadows it.
_build = lambda extra: any -> any {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "LandingPage"
        metadata = {name = "demo", namespace = "apps"}
        spec = extra
    }
}

# The smallest spec the XRD accepts on this backend. XRD defaults are absent
# here on purpose: a unit-tested XR never went through the API server.
_page = {region = "westeurope", resourceGroup = "platform-rg", content = {html = "<h1>demo</h1>"}}

_with = lambda extra: any -> any {
    _page | extra
}

_names = lambda items: any -> any {
    [_i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for _i in items]
}

_pick = lambda items: any, name: str -> any {
    _hits = [_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name]
    _hits[0] if _hits else Undefined
}

_res = lambda extra: any, name: str -> any {
    _pick(landing.render(_build(extra), {}), name)
}

_account_id = "/subscriptions/000/resourceGroups/platform-rg/providers/Microsoft.Storage/storageAccounts/demo"
_endpoint_id = "/subscriptions/000/resourceGroups/platform-rg/providers/Microsoft.Cdn/profiles/demo/afdEndpoints/demo"

# The account, once reconciled: its static-website host carries a
# region-assigned segment nothing can derive ahead of time.
_seen_account = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    primaryWebHost = "demo.z6.web.core.windows.net"
                    id = _account_id
                }
            }
        }
    }
}

_seen_edge = _seen_account | {
    "frontdoor-endpoint" = {
        Resource = {
            status = {
                atProvider = {
                    hostName = "demo-a1b2.z01.azurefd.net"
                    id = _endpoint_id
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------

# Default spec -> account, the index blob and the Front Door scaffolding.
# Origin and route wait for the account's web host; no domain, no custom domain.
test_render_minimal = lambda {
    items = landing.render(_build(_page), {})
    assert _names(items) == ["managed", "blob-index", "frontdoor-profile", "frontdoor-endpoint", "frontdoor-origin-group"], "the CDN is on by default, but the origin and the route wait for an observed web host"
    assert [_i.kind for _i in items] == ["Account", "Blob", "FrontdoorProfile", "FrontdoorEndpoint", "FrontdoorOriginGroup"], "wrong kinds"
    assert all _i in items {
        _i.metadata?.namespace == Undefined
    }, "composed resources carry no namespace — Crossplane places them"
    assert _pick(items, "frontdoor-profile").spec.forProvider.skuName == "Standard_AzureFrontDoor", "Front Door Standard is the tier that fronts a static website with a managed certificate"
    assert _pick(items, "frontdoor-profile").spec.forProvider.responseTimeoutSeconds == 60, "response timeout must be carried"
    assert _pick(items, "frontdoor-endpoint").spec.forProvider.cdnFrontdoorProfileIdSelector.matchControllerRef == True, "the endpoint must bind its profile by controller ref"
    group = _pick(items, "frontdoor-origin-group").spec.forProvider
    assert group.cdnFrontdoorProfileIdSelector.matchControllerRef == True, "the origin group must bind its profile by controller ref"
    assert group.healthProbe.path == "/" and group.healthProbe.$protocol == "Https", "a static site is probed over HTTPS on /"
    assert group.loadBalancing.sampleSize == 4, "the origin group needs a load balancing block"
}

# ---- render: the content store ----------------------------------------------
test_static_website = lambda {
    acct = _res(_page, "managed")
    assert acct.metadata.annotations["crossplane.io/external-name"] == "demo", "the account name is the blob endpoint and the Front Door origin host, so it is pinned to the XR name"
    fp = acct.spec.forProvider
    assert fp.location == "westeurope", "region -> account location"
    assert fp.resourceGroupName == "platform-rg", "the account lands in the existing resource group"
    assert fp.accountTier == "Standard" and fp.accountReplicationType == "LRS", "a landing page needs neither premium storage nor geo-replication"
    assert fp.accountKind == "StorageV2", "static websites exist on StorageV2 only"
    assert fp.staticWebsite.indexDocument == "index.html", "content.index must default to index.html"
    assert fp.staticWebsite.error404Document == "404.html", "content.errorDocument must default to 404.html"
    assert fp.allowNestedItemsToBePublic == True, "$web is unreadable unless nested items may be public"
    assert fp?.tags == Undefined, "no tags unless asked for"
    tagged = _res(_with({
        tags = {team = "platform"}
    }), "managed").spec.forProvider
    assert tagged.tags == {team = "platform"}, "tags -> account tags"
    custom = _res({region = "westeurope", resourceGroup = "platform-rg", content = {
        html = "<h1>demo</h1>"
        index = "home.html"
        errorDocument = "oops.html"
    }}, "managed").spec.forProvider
    assert custom.staticWebsite.indexDocument == "home.html", "an explicit index must reach the static website"
    assert custom.staticWebsite.error404Document == "oops.html", "an explicit error document must reach the static website"
}

# ---- render: blobs ----------------------------------------------------------
test_index_blob = lambda {
    b = _res(_page, "blob-index")
    assert b.metadata.annotations["crossplane.io/external-name"] == "index.html", "the blob key is the external name — BlobSpecForProvider carries no name"
    fp = b.spec.forProvider
    assert fp.storageAccountNameSelector.matchControllerRef == True, "blobs must bind the account by controller ref"
    assert fp.storageContainerName == "$web", "the static website is served out of $web"
    assert fp.$type == "Block", "inline content is a block blob"
    assert fp.sourceContent == "<h1>demo</h1>", "content.html is served verbatim"
    assert fp.contentType == "text/html", "the index document is always text/html"
    assert fp.cacheControl == "public, max-age=3600", "cdn.ttlSeconds defaults to 3600 and becomes the blob's Cache-Control"
    ttl = _res(_with({
        cdn = {ttlSeconds = 60}
    }), "blob-index").spec.forProvider
    assert ttl.cacheControl == "public, max-age=60", "an explicit ttl must reach the blob"
    renamed = _res({region = "westeurope", resourceGroup = "platform-rg", content = {html = "x", index = "home.html"}}, "blob-index")
    assert renamed.metadata.annotations["crossplane.io/external-name"] == "home.html", "content.index is the key the index document is written under"
}

test_file_blobs = lambda {
    items = landing.render(_build({region = "westeurope", resourceGroup = "platform-rg", content = {
        html = "<h1>demo</h1>"
        files = [
            {path = "styles.css", content = "body{}"}
            {path = "assets/Logo.SVG", content = "<svg/>"}
            {path = "data.bin", content = "raw"}
            {path = "manifest.json", content = "{}", contentType = "application/manifest+json"}
        ]
    }}), {})
    assert _names(items)[0:6:] == ["managed", "blob-index", "blob-styles-css", "blob-assets-logo-svg", "blob-data-bin", "blob-manifest-json"], "one blob per file, named after the path with everything outside [a-z0-9-] replaced"
    assert _pick(items, "blob-styles-css").spec.forProvider.contentType == "text/css", "the extension decides the MIME type"
    svg = _pick(items, "blob-assets-logo-svg")
    assert svg.spec.forProvider.contentType == "image/svg+xml", "the extension is matched case-insensitively"
    assert svg.metadata.annotations["crossplane.io/external-name"] == "assets/Logo.SVG", "the blob key is the path as written, only the resource name is sanitized"
    assert _pick(items, "blob-data-bin").spec.forProvider.contentType == "application/octet-stream", "an unknown extension falls back to application/octet-stream"
    assert _pick(items, "blob-manifest-json").spec.forProvider.contentType == "application/manifest+json", "an explicit contentType wins over the derived one"
    assert _pick(items, "blob-manifest-json").spec.forProvider.storageContainerName == "$web", "companion files are served from $web too"
}

# ---- render: the second pass ------------------------------------------------

# FrontdoorOrigin.hostName is a plain string and the static-website host is
# only knowable once the account reports it; a route without its origin is
# rejected, so the two appear together on the second pass and never before.
test_second_pass_origin_and_route = lambda {
    assert not ("frontdoor-origin" in _names(landing.render(_build(_page), {}))), "no origin before the account reports its web host"
    assert not ("frontdoor-route" in _names(landing.render(_build(_page), {}))), "no route before the origin it needs exists"
    items = landing.render(_build(_page), _seen_account)
    assert _names(items) == ["managed", "blob-index", "frontdoor-profile", "frontdoor-endpoint", "frontdoor-origin-group", "frontdoor-origin", "frontdoor-route"], "an observed web host completes the Front Door chain"
    o = _pick(items, "frontdoor-origin").spec.forProvider
    assert o.cdnFrontdoorOriginGroupIdSelector.matchControllerRef == True, "the origin must bind its group by controller ref"
    assert o.hostName == "demo.z6.web.core.windows.net", "the origin must point at the observed static-website host"
    assert o.originHostHeader == "demo.z6.web.core.windows.net", "the account only answers for its own host name"
    assert o.httpsPort == 443 and o.httpPort == 80, "the origin speaks the standard ports"
    assert o.certificateNameCheckEnabled == True, "the account's certificate matches its host name, so the check stays on"
    assert o.priority == 1 and o.weight == 1000 and o.enabled == True, "a single origin takes all the traffic"
    r = _pick(items, "frontdoor-route").spec.forProvider
    assert r.cdnFrontdoorEndpointIdSelector.matchControllerRef == True, "the route must bind the endpoint by controller ref"
    assert r.cdnFrontdoorOriginGroupIdSelector.matchControllerRef == True, "the route must bind the origin group by controller ref"
    assert r.cdnFrontdoorOriginIdsSelector.matchControllerRef == True, "the route must bind the origin by controller ref"
    assert r.forwardingProtocol == "HttpsOnly", "the edge talks to the account over HTTPS"
    assert r.supportedProtocols == ["Http", "Https"], "the edge answers both protocols"
    assert r.patternsToMatch == ["/*"], "the whole site is routed"
    assert r.linkToDefaultDomain == True, "the *.azurefd.net endpoint must serve the page"
    assert r.cache.compressionEnabled == True, "text assets must be compressed at the edge"
    assert r.cache.queryStringCachingBehavior == "IgnoreQueryString", "a static page caches the same object for every query string"
    assert r.httpsRedirectEnabled == True, "tls defaults to on, so HTTP is redirected"
    assert r?.cdnFrontdoorCustomDomainIdsSelector == Undefined, "without a custom domain the route binds none"
}

# ---- render: custom domain and TLS -------------------------------------------
test_custom_domain = lambda {
    items = landing.render(_build(_with({domain = "www.acme.example"})), _seen_account)
    cd = _pick(items, "custom-domain")
    assert cd.kind == "FrontdoorCustomDomain", "spec.domain must compose a Front Door custom domain"
    fp = cd.spec.forProvider
    assert fp.cdnFrontdoorProfileIdSelector.matchControllerRef == True, "the custom domain must bind its profile by controller ref"
    assert fp.hostName == "www.acme.example", "spec.domain is the host name"
    assert fp.tls.certificateType == "ManagedCertificate", "Front Door issues and renews the certificate"
    assert fp.tls.minimumTlsVersion == "TLS12", "TLS 1.2 is the floor"
    assert fp?.dnsZoneId == Undefined, "the zone is not Azure's to resolve — ownership is proven by the _dnsauth TXT record instead"
    assert _pick(items, "frontdoor-route").spec.forProvider.cdnFrontdoorCustomDomainIdsSelector.matchControllerRef == True, "the route must carry the custom domain, or the domain answers nothing"
}

test_tls_disabled_keeps_http = lambda {
    r = _pick(landing.render(_build(_with({domain = "www.acme.example", tls = {enabled = False}})), _seen_account), "frontdoor-route").spec.forProvider
    assert r.httpsRedirectEnabled == False, "tls.enabled=false must stop the HTTP -> HTTPS redirect"
    assert r.supportedProtocols == ["Http", "Https"], "the edge still answers both protocols"
}

# ---- render: no CDN ----------------------------------------------------------

# cdn.enabled=false leaves the account's own website endpoint as the only
# address. The same spec plus spec.domain is REJECTED by render() — a raw
# account endpoint takes neither a custom domain nor a certificate. A KCL
# assert failure cannot be asserted from a test, so this pins the rejecting
# condition instead: spec.domain is the only difference between the spec
# below (accepted) and the rejected one, and with the CDN back on that very
# same domain is accepted.
test_cdn_disabled = lambda {
    items = landing.render(_build(_with({
        cdn = {enabled = False}
    })), _seen_account)
    assert _names(items) == ["managed", "blob-index"], "no CDN -> the account and its blobs only"
    assert items[0].spec.forProvider.staticWebsite.indexDocument == "index.html", "the account still serves the page itself"
    assert "custom-domain" in _names(landing.render(_build(_with({domain = "www.acme.example"})), {})), "with the CDN on, that same domain is accepted"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy = lambda {
    orphaned = landing.render(_build(_with({domain = "www.acme.example", deletionPolicy = "Orphan"})), _seen_account)
    assert len(orphaned) == 8, "the full Front Door chain plus the custom domain"
    assert all _i in orphaned {
        _i.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every managed resource"
    deleted = landing.render(_build(_with({domain = "www.acme.example"})), _seen_account)
    assert all _i in deleted {
        not (_i.spec.managementPolicies == _orphan)
    }, "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------
test_status_pre_observation = lambda {
    dxr = landing.status(_build(_page), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "LandingPage", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must address the composite"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.ready == False, "nothing is serving before the edge exists"
    assert dxr.status.bucketName == "demo", "the account name is known ahead of creation"
    assert dxr.status.cdn == True, "the CDN is on by default"
    assert dxr.status.dnsRecordType == "CNAME", "a Front Door endpoint is a host name"
    assert dxr.status?.dnsTarget == Undefined, "no endpoint host to point DNS at yet"
    assert dxr.status?.host == Undefined, "no address yet: no domain, no endpoint"
    assert dxr.status?.url == Undefined, "no address yet: no domain, no endpoint"
    assert dxr.status?.id == Undefined, "no id before the endpoint exists"
    assert dxr.status?.arn == Undefined, "arn is AWS-only"
    assert dxr.status?.certificateStatus == Undefined, "the FrontdoorCustomDomain schema reports no certificate state"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#browse/Microsoft.Storage%2FStorageAccounts", "without an observed id the console link is the account list"
    domained = landing.status(_build(_with({domain = "www.acme.example"})), {})
    assert domained.status.host == "www.acme.example", "the custom domain is the address whether or not the edge exists yet"
    assert domained.status.url == "https://www.acme.example", "url is the host over https"
}

test_status_observed = lambda {
    dxr = landing.status(_build(_page), _seen_edge)
    assert dxr.status.ready == True, "an observed endpoint host means the page is served"
    assert dxr.status.dnsTarget == "demo-a1b2.z01.azurefd.net", "the endpoint host is the CNAME target"
    assert dxr.status.host == "demo-a1b2.z01.azurefd.net", "with no custom domain the endpoint is the address"
    assert dxr.status.url == "https://demo-a1b2.z01.azurefd.net", "url is the host over https"
    assert dxr.status.id == _endpoint_id, "the edge id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource${_account_id}/overview", "an observed account id must land in the portal link"
    assert dxr.status?.validationRecords == Undefined, "no custom domain, nothing to validate"
}

test_status_custom_domain = lambda {
    _spec = _with({domain = "www.acme.example"})
    pending = landing.status(_build(_spec), _seen_edge | {
        "custom-domain" = {
            Resource = {
                status = {
                    atProvider = {validationToken = "tok123"}
                }
            }
        }
    })
    assert pending.status.ready == False, "the domain answers only once the route binds it to the origin"
    assert pending.status.host == "www.acme.example", "the custom domain is the address"
    assert pending.status.dnsTarget == "demo-a1b2.z01.azurefd.net", "the domain must CNAME to the endpoint"
    assert pending.status.validationRecords == [{name = "_dnsauth.www.acme.example", "type" = "TXT", value = "tok123"}], "the observed token must be published as the record that proves ownership"
    live = landing.status(_build(_spec), _seen_edge | {
        "custom-domain" = {
            Resource = {
                status = {
                    atProvider = {validationToken = "tok123"}
                }
            }
        }
        "frontdoor-route" = {
            Resource = {
                status = {
                    atProvider = {id = "/subscriptions/000/routes/demo"}
                }
            }
        }
    })
    assert live.status.ready == True, "endpoint plus route means the custom domain is being served"
    assert live.status?.certificateStatus == Undefined, "the FrontdoorCustomDomain schema reports no certificate state to surface"
}

test_status_without_cdn = lambda {
    _spec = _with({
        cdn = {enabled = False}
    })
    pre = landing.status(_build(_spec), {})
    assert pre.status.cdn == False, "no edge cache in front of the content"
    assert pre.status.ready == False, "nothing is serving before the account reports its web host"
    assert pre.status.host == "demo.web.core.windows.net", "an approximate address until the account reports the real one"
    assert pre.status.url == "https://demo.web.core.windows.net", "url is the host over https"
    assert pre.status?.dnsTarget == Undefined, "no edge, nothing for DNS to point at"
    assert pre.status?.dnsRecordType == Undefined, "no edge, no record to create"
    seen = landing.status(_build(_spec), _seen_account)
    assert seen.status.ready == True, "the account's web host means the page is served"
    assert seen.status.host == "demo.z6.web.core.windows.net", "the observed web host replaces the approximation"
    assert seen.status.url == "https://demo.z6.web.core.windows.net", "url follows the observed host"
    assert seen.status.id == _account_id, "without an edge the content store is the resource to report"
}
