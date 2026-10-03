# landing (gcp) — Crossplane Composition logic (function-kcl module).
# The page lives in the XR: one GCS Bucket holds the index document and every
# companion file as a BucketObject, an allUsers IAM binding makes them public,
# and — when the CDN is asked for — a global external Application Load Balancer
# (BackendBucket -> URLMap -> proxy -> GlobalForwardingRule on a GlobalAddress)
# puts Cloud CDN and a Google-managed certificate in front of it. That load
# balancer is Cloud CDN's only front door: with the CDN off, the bucket's own
# https://storage.googleapis.com/<bucket>/<index> URL is the whole service.
#
# DNS is not composed here: status.dnsTarget/dnsRecordType publish the A record
# a DnsZone must carry for spec.domain. Cloud Armor, IAP and an HTTP->HTTPS
# redirect URL map are out of scope.
import regex
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as gcsbucket
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_i_a_m_member as gcsiam
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket_object as gcsobject
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_backend_bucket as backendbucket
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_url_map as urlmap
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_address as globaladdress
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_managed_s_s_l_certificate as managedcert
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_https_proxy as httpsproxy
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_http_proxy as httpproxy
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_forwarding_rule as forwardingrule

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# MIME type per file extension. Identical on every landing backend — a drift
# between backends is a bug, not a backend detail.
_content_types = {
    html = "text/html"
    htm = "text/html"
    css = "text/css"
    js = "text/javascript"
    mjs = "text/javascript"
    json = "application/json"
    svg = "image/svg+xml"
    png = "image/png"
    jpg = "image/jpeg"
    jpeg = "image/jpeg"
    gif = "image/gif"
    webp = "image/webp"
    ico = "image/x-icon"
    txt = "text/plain"
    xml = "application/xml"
    woff2 = "font/woff2"
}

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false (or a legitimate 0), so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

_number = lambda v, fallback: int -> int {
    fallback if v in [None, Undefined] else v
}

# Extension of an object key, lowercased, "" when the basename carries none.
_extension = lambda path: str -> str {
    _base = path.lower().split("/")[-1]
    _parts = _base.split(".")
    "" if len(_parts) < 2 else _parts[-1]
}

# An explicit contentType wins; otherwise the extension decides.
_content_type = lambda file: any -> str {
    _ext = _extension(file.path)
    file?.contentType or (_content_types[_ext] if _ext in _content_types else "application/octet-stream")
}

# composition-resource-name of a content file. Renaming a composed resource
# deletes and recreates the object, so this mapping is part of the contract.
_slug = lambda path: str -> str {
    regex.replace(path.lower(), "[^a-z0-9-]", "-")
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _content = _spec.content
    _index = _content?.index or "index.html"
    _error_document = _content?.errorDocument or "404.html"
    _domain = _spec?.domain
    _cdn = _flag(_spec?.cdn?.enabled, True)
    _ttl = _number(_spec?.cdn?.ttlSeconds, 3600)
    _tls = _flag(_spec?.tls?.enabled, True)
    # HTTPS needs both a name to put on the certificate and TLS left on.
    _https = _domain != Undefined and _domain != "" and _tls
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _cache = "public, max-age=${_ttl}"

    # Rejected shape. Neither a custom domain nor TLS can be put on a raw GCS
    # endpoint — both live on the load balancer, which only exists with the CDN.
    assert _cdn or _domain in [None, Undefined, ""], "landing-gcp: spec.domain cannot be served with spec.cdn.enabled=false — a bucket endpoint carries no custom domain and no certificate; set spec.cdn.enabled=true or drop spec.domain"

    _object = lambda resource_name: str, key: str, body: str, content_type: str -> any {
        gcsobject.BucketObject {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = resource_name}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider = {
                # The bucket is composed next to the object, so bind by
                # controller ref: the object waits for the bucket to exist.
                bucketSelector.matchControllerRef = True
                name = key
                content = body
                contentType = content_type
                cacheControl = _cache
            }
        }
    }

    _store = [
        gcsbucket.Bucket {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "managed"
                # GCS bucket names are a single global namespace, so the name is
                # the provider identifier: pinning it to the XR name makes both
                # the public URL and the BackendBucket reference deterministic
                # (and makes a name clash a creation error, not a silent rename).
                "crossplane.io/external-name" = _name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider = {
                location = _spec.region
                uniformBucketLevelAccess = True
                # An allUsers binding is the whole point of this bucket;
                # "enforced" public access prevention would reject it.
                publicAccessPrevention = "inherited"
                # The XR owns every object in this bucket, so deleting the XR
                # must not wedge on a non-empty bucket.
                forceDestroy = True
                website = {
                    mainPageSuffix = _index
                    notFoundPage = _error_document
                }
                if _spec?.tags:
                    labels = _spec.tags
            }
        }
        gcsiam.BucketIAMMember {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "iam-public"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider = {
                bucketSelector.matchControllerRef = True
                role = "roles/storage.objectViewer"
                member = "allUsers"
            }
        }
        _object("object-index", _index, _content.html, "text/html")
    ] + [_object("object-${_slug(_f.path)}", _f.path, _f.content, _content_type(_f)) for _f in (_content?.files or [])]

    # The global external Application Load Balancer. Cloud CDN is a property of
    # the backend bucket, and a backend bucket is only reachable through this
    # chain — there is no cheaper way to cache or to serve a custom domain.
    _edge: [any] = []
    if _cdn:
        _edge = [
            backendbucket.BackendBucket {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "backend-bucket"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider = {
                    bucketNameSelector.matchControllerRef = True
                    enableCdn = True
                    cdnPolicy = {
                        cacheMode = "CACHE_ALL_STATIC"
                        defaultTtl = _ttl
                        clientTtl = _ttl
                        maxTtl = 86400
                    }
                }
            }
            urlmap.URLMap {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "url-map"}
                if _mp:
                    spec.managementPolicies = _mp
                # Every path goes to the one backend bucket: a landing page has
                # no second origin to route to.
                spec.forProvider.defaultServiceSelector.matchControllerRef = True
            }
            globaladdress.GlobalAddress {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "address"}
                if _mp:
                    spec.managementPolicies = _mp
                # The stable anycast IP the DNS A record points at; it outlives
                # the forwarding rule, so the record never has to change.
                spec.forProvider.addressType = "EXTERNAL"
            }
        ]
        if _https:
            _edge += [
                managedcert.ManagedSSLCertificate {
                    metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "certificate"}
                    if _mp:
                        spec.managementPolicies = _mp
                    # Google validates the domain through the load balancer
                    # itself once the A record resolves — no validation records.
                    spec.forProvider.managed.domains = [_domain]
                }
                httpsproxy.TargetHTTPSProxy {
                    metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "https-proxy"}
                    if _mp:
                        spec.managementPolicies = _mp
                    spec.forProvider = {
                        urlMapSelector.matchControllerRef = True
                        sslCertificatesSelector.matchControllerRef = True
                    }
                }
            ]
        else:
            # No domain (or TLS off) means no certificate: a Google-managed
            # certificate exists only for a domain, and the load balancer has
            # no hostname of its own to put one on. Plain HTTP on the IP.
            _edge += [httpproxy.TargetHTTPProxy {
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "http-proxy"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.urlMapSelector.matchControllerRef = True
            }]
        _edge += [forwardingrule.GlobalForwardingRule {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "forwarding-rule"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider = {
                targetSelector.matchControllerRef = True
                ipAddressSelector.matchControllerRef = True
                portRange = "443" if _https else "80"
                loadBalancingScheme = "EXTERNAL_MANAGED"
            }
        }]

    _store + _edge
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _cds = ocds or {}
    _at = lambda resource_name: str -> any {
        (_cds[resource_name]?.Resource?.status?.atProvider) if resource_name in _cds else Undefined
    }

    # A GCS bucket's provider id is its name, which is pinned to the XR name.
    _bucket = _at("managed")
    _name = _bucket?.id or oxr.metadata.name
    _index = _spec.content?.index or "index.html"
    _domain = _spec?.domain
    _cdn = _flag(_spec?.cdn?.enabled, True)
    _https = _domain != Undefined and _domain != "" and _flag(_spec?.tls?.enabled, True)

    _address = _at("address")?.address or ""
    _rule = _at("forwarding-rule")
    _rule_ip = _rule?.ipAddress or ""

    # With the load balancer the page answers on the custom domain when there is
    # one and on the anycast IP otherwise; without it, only the bucket endpoint
    # exists, and spec.domain is rejected by render().
    _host = (_domain or _address) if _cdn else "storage.googleapis.com"
    _url = ("https://${_domain}" if _https else "http://${_host}") if _cdn else "https://storage.googleapis.com/${_name}/${_index}"

    _dxr = {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "LandingPage"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            # The edge is serving once the forwarding rule holds an IP; without
            # one, the bucket endpoint is live as soon as the bucket exists.
            ready = _rule_ip != "" if _cdn else (_bucket?.id or "") != ""
            bucketName = _name
            cdn = _cdn
            "cloud-url" = "https://console.cloud.google.com/storage/browser/${_name}"
            if _host:
                host = _host
                url = _url
            if _cdn:
                # A global address is an IP, so spec.domain always needs an A
                # record — never a CNAME.
                dnsRecordType = "A"
                if _address:
                    dnsTarget = _address
                if _rule?.id:
                    id = _rule.id
            # status.validationRecords stays unset on GCP: a Google-managed
            # certificate is validated through the load balancer serving the
            # domain, not by a record the user has to publish first.
            # status.certificateStatus stays unset too — the generated
            # ManagedSSLCertificate exposes only certificateId, expireTime,
            # subjectAlternativeNames and managed.domains at provider, with no
            # PROVISIONING/ACTIVE state to report.
            # status.arn is AWS-only.
        }
    }
    _dxr
}
