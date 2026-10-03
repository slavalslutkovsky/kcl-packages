# landing (azure) — Crossplane Composition logic (function-kcl module).
# The page lives in a Storage Account's static website: the account serves
# $web over its own HTTPS endpoint, and Front Door Standard puts the edge
# cache, the custom domain and the managed certificate in front of it. Front
# Door is the only Azure service that fronts a static website with a managed
# certificate, which is why disabling the CDN also costs the custom domain.
#
# Not composed here: the resource group (spec.resourceGroup must already
# exist), the DNS records (status.dnsTarget / status.validationRecords say
# what a DnsZone must carry), WAF policies and rule sets.
import regex
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account as account
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_blob as blob
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_profile as fdprofile
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_endpoint as fdendpoint
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_origin_group as fdorigingroup
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_origin as fdorigin
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_route as fdroute
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_custom_domain as fdcustomdomain

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# MIME type per lowercased path extension. The table is a cross-backend
# parity invariant — the same file must be served as the same type on aws,
# gcp, azure and onprem — so it is pinned here rather than derived.
content_types = {
    "html" = "text/html"
    "htm" = "text/html"
    "css" = "text/css"
    "js" = "text/javascript"
    "mjs" = "text/javascript"
    "json" = "application/json"
    "svg" = "image/svg+xml"
    "png" = "image/png"
    "jpg" = "image/jpeg"
    "jpeg" = "image/jpeg"
    "gif" = "image/gif"
    "webp" = "image/webp"
    "ico" = "image/x-icon"
    "txt" = "text/plain"
    "xml" = "application/xml"
    "woff2" = "font/woff2"
}
default_content_type = "application/octet-stream"

# Azure creates this container itself the moment the static website is
# enabled on the account, and rejects an attempt to create it: never compose
# a Container MR for it, just write the blobs into it by name.
web_container = "$web"

# XRD defaults only exist on an XR that went through the API server; a
# locally rendered example or a unit test carries none. `or` would also
# swallow a legitimate False or 0, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

_num = lambda v, fallback: int -> int {
    fallback if v in [None, Undefined] else v
}

_str = lambda v, fallback: str -> str {
    fallback if v in [None, Undefined, ""] else v
}

# Explicit contentType wins; otherwise the path extension decides.
_content_type = lambda f: any -> str {
    _parts = f.path.lower().split(".")
    _ext = _parts[-1] if len(_parts) > 1 else ""
    _derived = content_types[_ext] if _ext in content_types else default_content_type
    _str(f?.contentType, _derived)
}

# composition-resource-name of one content blob. Renaming a composed resource
# deletes and recreates the blob, so this mapping is part of the contract.
_blob_name = lambda path: str -> str {
    "blob-${regex.replace(path.lower(), '[^a-z0-9-]', '-')}"
}

# The static-website host, observed on the Account. Front Door needs it as a
# plain string (FrontdoorOrigin.hostName takes no reference to the account),
# and it carries a region-assigned segment — <account>.z<NN>.web.core.windows.net
# — that cannot be derived, so it only exists after the first observation.
_web_host = lambda ocds {
    ((ocds or {})["managed"]?.Resource?.status?.atProvider?.primaryWebHost) or ""
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _content = _spec.content
    _index = _str(_content?.index, "index.html")
    _error = _str(_content?.errorDocument, "404.html")
    _files = _content?.files or []
    _cdn_on = _flag(_spec?.cdn?.enabled, True)
    _ttl = _num(_spec?.cdn?.ttlSeconds, 3600)
    _tls_on = _flag(_spec?.tls?.enabled, True)
    _domain = _spec?.domain
    _rg = _spec?.resourceGroup
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently pretending a field took effect.
    assert _rg, "landing-azure: spec.resourceGroup is required — name the existing resource group the Storage Account and the Front Door profile are created in"
    assert not _domain or _cdn_on, "landing-azure: spec.domain needs the CDN — a Storage Account's own website endpoint takes neither a custom domain nor a certificate; drop spec.domain, or set spec.cdn.enabled=true"

    # The account name is the blob endpoint host and the Front Door origin
    # host, so it must be deterministic: it is pinned to the XR name rather
    # than left to Crossplane's generated external-name. Azure's own rule for
    # a Storage Account name is 3-24 lowercase letters and digits — no
    # dashes, no dots, no uppercase — so the XR name must obey it too.
    assert regex.match(_name, r"^[a-z0-9]{3,24}$"), "landing-azure: metadata.name '${_name}' is not a valid Storage Account name — rename the XR to 3-24 lowercase letters and digits, no dashes"

    # 1) The content store: a StorageV2 account with the static website on.
    # $web, the index document and the 404 document all come from here.
    _items: [any] = [account.Account {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.accountTier = "Standard"
        spec.forProvider.accountReplicationType = "LRS"
        # Static websites exist on StorageV2 only.
        spec.forProvider.accountKind = "StorageV2"
        spec.forProvider.staticWebsite = {indexDocument = _index, error404Document = _error}
        # A landing page is public by definition; $web is only readable when
        # nested items may opt into being public.
        spec.forProvider.allowNestedItemsToBePublic = True
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) One blob per document. BlobSpecForProvider has no `name` attribute:
    # the blob key IS the provider's external name, so it is pinned there.
    # Front Door Standard takes a cache duration only from a rule set, which
    # this XR does not compose, so cdn.ttlSeconds becomes the blob's own
    # Cache-Control — which both the edge and the browser honour.
    _blob = lambda res: str, key: str, body: str, ctype: str -> any {
        blob.Blob {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = res
                "crossplane.io/external-name" = key
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.storageAccountNameSelector.matchControllerRef = True
            spec.forProvider.storageContainerName = web_container
            spec.forProvider.$type = "Block"
            spec.forProvider.sourceContent = body
            spec.forProvider.contentType = ctype
            spec.forProvider.cacheControl = "public, max-age=${_ttl}"
        }
    }
    _items += [_blob("blob-index", _index, _content.html, "text/html")]
    _items += [_blob(_blob_name(_f.path), _f.path, _f.content, _content_type(_f)) for _f in _files]

    if _cdn_on:
        # 3) Front Door Standard. The profile is global — the MR carries no
        # location, only the resource group that holds its ARM record.
        _items += [fdprofile.FrontdoorProfile {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "frontdoor-profile"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.resourceGroupName = _rg
            spec.forProvider.skuName = "Standard_AzureFrontDoor"
            spec.forProvider.responseTimeoutSeconds = 60
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]

        # The *.azurefd.net address the page answers on, and the CNAME target
        # for spec.domain.
        _items += [fdendpoint.FrontdoorEndpoint {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "frontdoor-endpoint"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.cdnFrontdoorProfileIdSelector.matchControllerRef = True
            spec.forProvider.enabled = True
        }]

        # One origin group holding the single static-website origin. The
        # probe is HTTPS on / because that is the only path a static site is
        # guaranteed to answer, and HEAD keeps the probe off the page body.
        _items += [fdorigingroup.FrontdoorOriginGroup {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "frontdoor-origin-group"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.cdnFrontdoorProfileIdSelector.matchControllerRef = True
            spec.forProvider.loadBalancing = {
                sampleSize = 4
                successfulSamplesRequired = 3
                additionalLatencyInMilliseconds = 50
            }
            spec.forProvider.healthProbe = {
                path = "/"
                $protocol = "Https"
                requestType = "HEAD"
                intervalInSeconds = 100
            }
        }]

        # The custom domain. No dnsZoneId is set: the zone lives wherever the
        # user's DnsZone XR put it, so Front Door validates through the
        # _dnsauth TXT record reported in status.validationRecords.
        if _domain:
            _items += [fdcustomdomain.FrontdoorCustomDomain {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "custom-domain"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.cdnFrontdoorProfileIdSelector.matchControllerRef = True
                spec.forProvider.hostName = _domain
                spec.forProvider.tls = {certificateType = "ManagedCertificate", minimumTlsVersion = "TLS12"}
            }]

        # SECOND PASS. The origin points at the static-website host by plain
        # string, and that host is only knowable once the account reports it,
        # so both the origin and the route it needs wait for the first
        # observation. A route without its origin is rejected by Azure, which
        # is why they appear together and never before.
        _host = _web_host(ocds)
        if _host:
            _items += [fdorigin.FrontdoorOrigin {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "frontdoor-origin"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.cdnFrontdoorOriginGroupIdSelector.matchControllerRef = True
                spec.forProvider.hostName = _host
                # The account only answers for its own host name.
                spec.forProvider.originHostHeader = _host
                spec.forProvider.httpsPort = 443
                spec.forProvider.httpPort = 80
                spec.forProvider.certificateNameCheckEnabled = True
                spec.forProvider.priority = 1
                spec.forProvider.weight = 1000
                spec.forProvider.enabled = True
            }]

            _items += [fdroute.FrontdoorRoute {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "frontdoor-route"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.cdnFrontdoorEndpointIdSelector.matchControllerRef = True
                spec.forProvider.cdnFrontdoorOriginGroupIdSelector.matchControllerRef = True
                spec.forProvider.cdnFrontdoorOriginIdsSelector.matchControllerRef = True
                # The account speaks HTTPS; the edge accepts both and, with
                # tls.enabled, sends HTTP visitors to HTTPS.
                spec.forProvider.forwardingProtocol = "HttpsOnly"
                spec.forProvider.supportedProtocols = ["Http", "Https"]
                spec.forProvider.patternsToMatch = ["/*"]
                spec.forProvider.httpsRedirectEnabled = _tls_on
                spec.forProvider.linkToDefaultDomain = True
                spec.forProvider.cache = {compressionEnabled = True, queryStringCachingBehavior = "IgnoreQueryString"}
                if _domain:
                    spec.forProvider.cdnFrontdoorCustomDomainIdsSelector.matchControllerRef = True
            }]


    # 4) cdn.enabled=false stops here: the account's own static-website
    # endpoint serves the page, HTTP(S) on *.web.core.windows.net only.
    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _cdn_on = _flag(_spec?.cdn?.enabled, True)
    _domain = _spec?.domain
    _o = ocds or {}

    _at = lambda res: str {
        (_o[res]?.Resource?.status?.atProvider) if res in _o else Undefined
    }
    _acct = _at("managed")
    _endpoint = _at("frontdoor-endpoint")
    _cd = _at("custom-domain")

    _acct_id = _acct?.id or ""
    _edge_host = (_endpoint?.hostName or "") if _cdn_on else ""

    # Without Front Door the account's own web host is the address. Before it
    # is observed the value below is an APPROXIMATION: the real host carries a
    # region-assigned segment (<account>.z<NN>.web.core.windows.net) that
    # cannot be derived, so this is a placeholder until the account reports.
    _site_host = (_web_host(_o) or "${_name}.web.core.windows.net") if not _cdn_on else ""
    _host = _domain or _edge_host or _site_host
    _route_id = (_o["frontdoor-route"]?.Resource?.status?.atProvider?.id or "") if "frontdoor-route" in _o else ""
    _token = _cd?.validationToken or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "LandingPage"
        metadata.name = _name
        status = {
            provider = "azure"
            # With Front Door the page is served once the endpoint has a host
            # — and, when a custom domain is composed, once the route that
            # binds it to the origin exists. Without Front Door the account's
            # own web host is the only thing to wait for.
            ready = (_edge_host != "" and (not _domain or _route_id != "")) if _cdn_on else (_web_host(_o) != "")
            bucketName = _name
            cdn = _cdn_on
            if _host:
                host = _host
                url = "https://${_host}"
            if _edge_host:
                dnsTarget = _edge_host
            if _cdn_on:
                # A Front Door endpoint is a hostname, never an address.
                dnsRecordType = "CNAME"
            # Domain ownership is proven by one TXT record before the managed
            # certificate is issued. The generated FrontdoorCustomDomain
            # schema reports validationToken and expirationDate but no
            # validation or certificate state, so status.certificateStatus
            # has nothing to read and is omitted rather than invented.
            if _domain and _cdn_on and _token:
                validationRecords = [{name = "_dnsauth.${_domain}", type = "TXT", value = _token}]
            # The edge's own id with Front Door; the content store's id
            # otherwise, which is then the only thing serving the page.
            if _cdn_on:
                if _endpoint?.id:
                    id = _endpoint.id
            elif _acct_id:
                id = _acct_id
            "cloud-url" = "https://portal.azure.com/#@/resource${_acct_id}/overview" if _acct_id else "https://portal.azure.com/#browse/Microsoft.Storage%2FStorageAccounts"
        }
    }
}
