# landing (aws) — Crossplane Composition logic (function-kcl module).
# The page content lives in the XR: one S3 Bucket holds it, one Object per
# document, and CloudFront serves it from the edge through an Origin Access
# Control (the bucket itself stays private). A custom domain is served with a
# DNS-validated ACM certificate in us-east-1, whose validation records this
# module reports so a DnsZone XR can create them.
#
# DNS is not composed here: status.dnsTarget / status.dnsRecordType say what
# record must point at the distribution, and status.validationRecords say what
# proves domain ownership to ACM.
import json
import regex
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket as backend
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_public_access_block as pab
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_ownership_controls as ownership
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_website_configuration as website
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_policy as bucketpolicy
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_object as s3object
import aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_origin_access_control as oac
import aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_distribution as cloudfront
import aws_acm.models.v1beta1.acm_awsm_upbound_io_v1beta1_certificate as acm

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# CloudFront accepts a viewer certificate from no other region, whatever
# spec.region says the content lives in.
certificate_region = "us-east-1"

# Abstract edge footprint -> CloudFront price class.
_price_class = {"cheapest" = "PriceClass_100", "most" = "PriceClass_200", "all" = "PriceClass_All"}

# Longest a cached object may live at the edge. CloudFront's own maximum
# (one year); cdn.ttlSeconds only moves the default TTL.
max_ttl_seconds = 31536000

# Path extension -> MIME type. Identical on every backend of this XRD: the
# same file must be served with the same type wherever the page is hosted, so
# this table is a parity invariant, not an aws detail.
_mime = {
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
_default_mime = "application/octet-stream"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Lowercased extension of a path, empty when the last segment carries none.
_ext = lambda path: str -> str {
    _base = path.lower().split("/")[-1]
    _parts = _base.split(".")
    "" if len(_parts) < 2 else _parts[-1]
}

# MIME type of one content.files entry: what the user asked for, else the type
# derived from the extension, else the catch-all.
_content_type = lambda path: str, explicit -> str {
    _e = _ext(path)
    explicit or (_mime[_e] if _e in _mime else _default_mime)
}

# Object key -> composition-resource-name suffix. Renaming a composed resource
# deletes and recreates the object, so this mapping is part of the contract.
_slug = lambda path: str -> str {
    regex.replace(path.lower(), "[^a-z0-9-]", "-")
}

# Observed state of a composed resource; Undefined until the first reconcile.
_at = lambda ocds, res: str -> any {
    (ocds[res]?.Resource?.status?.atProvider) if res in (ocds or {}) else Undefined
}

# Bucket policy granting CloudFront — and only this distribution — read access
# to the objects. The SourceArn condition is what keeps another account's
# distribution from pointing at the bucket.
_oac_policy = lambda bucket: str, distribution_arn: str -> str {
    json.encode({
        Version = "2012-10-17"
        Statement = [{
            Sid = "AllowCloudFrontServicePrincipalReadOnly"
            Effect = "Allow"
            Principal = {Service = "cloudfront.amazonaws.com"}
            Action = "s3:GetObject"
            Resource = "arn:aws:s3:::${bucket}/*"
            Condition = {
                StringEquals = {"AWS:SourceArn" = distribution_arn}
            }
        }]
    })
}

# Bucket policy for the website endpoint: the S3 website endpoint authenticates
# nothing, so anonymous GetObject is the only way it serves anything.
_public_policy = lambda bucket: str -> str {
    json.encode({
        Version = "2012-10-17"
        Statement = [{
            Sid = "PublicReadGetObject"
            Effect = "Allow"
            Principal = "*"
            Action = "s3:GetObject"
            Resource = "arn:aws:s3:::${bucket}/*"
        }]
    })
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _domain = _spec?.domain
    _content = _spec.content
    _index = _content?.index or "index.html"
    _error_doc = _content?.errorDocument or "404.html"
    _files = _content?.files or []
    _cdn = _flag(_spec?.cdn?.enabled, True)
    _ttl = _spec?.cdn?.ttlSeconds
    if _ttl in [None, Undefined]:
        _ttl = 3600

    _tls = _flag(_spec?.tls?.enabled, True)
    _tags = _spec?.tags
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently pretending a field took effect.
    assert not _domain or _cdn, "landing-aws: spec.domain needs spec.cdn.enabled=true — an S3 website endpoint answers on its own *.s3-website-<region>.amazonaws.com name only; keep the CDN, or drop spec.domain"
    assert not _domain or _tls, "landing-aws: spec.domain needs spec.tls.enabled=true — CloudFront refuses an alternate domain name without an ACM certificate covering it; keep TLS, or drop spec.domain and be served on the CloudFront domain"

    # The bucket name IS the CloudFront origin host and the ARN the bucket
    # policy grants on, so it must be known before either exists: the
    # external-name is pinned to the XR name instead of being generated.
    # S3 bucket names are globally unique across all AWS accounts, so the XR
    # name has to be unique too — a colliding name fails at create time.
    _bucket = _name

    _annos = lambda res: str -> {str:str} {
        {"krm.kcl.dev/composition-resource-name" = res}
    }

    # Common scaffolding for a resource that binds back to the bucket.
    _attach = lambda res: str -> any {
        _c = {
            metadata.annotations = _annos(res)
            spec.forProvider.region = _region
            spec.forProvider.bucketSelector.matchControllerRef = True
        }
        _c | {spec.managementPolicies = _mp} if _mp else _c
    }

    # 1) The content store.
    _items: [any] = [backend.Bucket {
        metadata.annotations = _annos("managed") | {"crossplane.io/external-name" = _bucket}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        if _tags:
            spec.forProvider.tags = _tags
    }]

    # 2) Public access. With the CDN the bucket is read through the Origin
    # Access Control and nothing about it is public; without it, the website
    # endpoint serves exactly what the public bucket policy below allows, and
    # a block would turn every request into a 403.
    _items += [pab.BucketPublicAccessBlock {
        **_attach("public-access-block")
        spec.forProvider.blockPublicAcls = _cdn
        spec.forProvider.blockPublicPolicy = _cdn
        spec.forProvider.ignorePublicAcls = _cdn
        spec.forProvider.restrictPublicBuckets = _cdn
    }]

    # 3) ACLs disabled — access to the page is decided by the bucket policy
    # alone, on both paths.
    _items += [ownership.BucketOwnershipControls {
        **_attach("ownership")
        spec.forProvider.$rule = {objectOwnership = "BucketOwnerEnforced"}
    }]

    # 4) The page itself: the index document, then one object per companion
    # file, each served with its own MIME type.
    _items += [s3object.Object {
        **_attach("object-index")
        spec.forProvider.key = _index
        spec.forProvider.content = _content.html
        spec.forProvider.contentType = "text/html"
    }]
    _items += [s3object.Object {
        **_attach("object-${_slug(_f.path)}")
        spec.forProvider.key = _f.path
        spec.forProvider.content = _f.content
        spec.forProvider.contentType = _content_type(_f.path, _f?.contentType)
    } for _f in _files]

    if _cdn:
        # The OAC signs CloudFront's requests to S3 with SigV4, which is what
        # lets the bucket stay private. CloudFront is global: neither this MR
        # nor the Distribution takes a region in the provider schema.
        _items += [oac.OriginAccessControl {
            metadata.annotations = _annos("oac")
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.name = "${_name}-oac"
            spec.forProvider.originAccessControlOriginType = "s3"
            spec.forProvider.signingBehavior = "always"
            spec.forProvider.signingProtocol = "sigv4"
        }]

        if _domain:
            _items += [acm.Certificate {
                metadata.annotations = _annos("certificate")
                if _mp:
                    spec.managementPolicies = _mp
                # Not spec.region: a CloudFront viewer certificate must live
                # in us-east-1, wherever the content does.
                spec.forProvider.region = certificate_region
                spec.forProvider.domainName = _domain
                # DNS validation, so status.validationRecords can be turned
                # into records by a DnsZone instead of needing a mailbox.
                spec.forProvider.validationMethod = "DNS"
                if _tags:
                    spec.forProvider.tags = _tags
            }]

        # SECOND PASS: the Distribution schema carries acmCertificateArn as a
        # plain string with no ref/selector, so the alias and its certificate
        # can only be attached once ACM has been observed. Attaching the alias
        # any earlier is rejected outright (CloudFront will not answer on an
        # alternate domain name the viewer certificate does not cover).
        _cert_arn = _at(ocds, "certificate")?.arn
        _aliased = _domain and _cert_arn

        _origin_id = "s3-${_name}"
        _items += [cloudfront.Distribution {
            metadata.annotations = _annos("distribution")
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.enabled = True
            spec.forProvider.defaultRootObject = _index
            spec.forProvider.origin = [{
                # The REST endpoint, not the website endpoint: an OAC signs
                # requests to the former only.
                domainName = "${_bucket}.s3.${_region}.amazonaws.com"
                originId = _origin_id
                originAccessControlIdSelector.matchControllerRef = True
            }]
            spec.forProvider.defaultCacheBehavior = {
                targetOriginId = _origin_id
                viewerProtocolPolicy = "redirect-to-https" if _tls else "allow-all"
                allowedMethods = ["GET", "HEAD"]
                cachedMethods = ["GET", "HEAD"]
                compress = True
                minTtl = 0
                defaultTtl = _ttl
                maxTtl = max_ttl_seconds
                # Mandatory whenever no cachePolicyId is given; a landing page
                # varies on nothing, so nothing is forwarded to the origin.
                forwardedValues = {queryString = False, cookies = {forward = "none"}}
            }
            spec.forProvider.priceClass = _price_class[_spec?.cdn?.priceClass or "cheapest"]
            spec.forProvider.restrictions = {
                geoRestriction = {restrictionType = "none"}
            }
            if _aliased:
                spec.forProvider.aliases = [_domain]
                spec.forProvider.viewerCertificate = {
                    acmCertificateArn = _cert_arn
                    sslSupportMethod = "sni-only"
                    minimumProtocolVersion = "TLSv1.2_2021"
                }
            else:
                spec.forProvider.viewerCertificate = {cloudfrontDefaultCertificate = True}
            # Only wired up when the error document is actually one of the
            # files: pointing at a key that was never uploaded turns every
            # 404 into a 404 for the error page itself.
            if any _f in _files {
                _f.path == _error_doc
            }:
                spec.forProvider.customErrorResponse = [{
                    errorCode = 404
                    responseCode = 404
                    responsePagePath = "/${_error_doc}"
                }]
            # A distribution takes ~15 minutes to deploy; waiting for it here
            # would block the provider's worker for the whole time instead of
            # letting status.ready report it.
            spec.forProvider.waitForDeployment = False
            if _tags:
                spec.forProvider.tags = _tags
        }]

        # SECOND PASS: the policy names the distribution in its SourceArn
        # condition, which only exists once the distribution does. Until then
        # the bucket has no policy at all, which is the safe state: the
        # objects are simply unreadable.
        _dist_arn = _at(ocds, "distribution")?.arn
        if _dist_arn:
            _items += [bucketpolicy.BucketPolicy {
                **_attach("bucket-policy")
                spec.forProvider.policy = _oac_policy(_bucket, _dist_arn)
            }]

    else:
        # No edge: the bucket's own website endpoint is the site. It resolves
        # directory requests to the index document and serves the error
        # document itself, both of which CloudFront does differently.
        _items += [website.BucketWebsiteConfiguration {
            **_attach("website")
            spec.forProvider.indexDocument = {suffix = _index}
            spec.forProvider.errorDocument = {key = _error_doc}
        }]
        _items += [bucketpolicy.BucketPolicy {
            **_attach("bucket-policy")
            spec.forProvider.policy = _public_policy(_bucket)
        }]
    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _domain = _spec?.domain
    _cdn = _flag(_spec?.cdn?.enabled, True)

    _bucket_at = _at(ocds, "managed")
    _dist_at = _at(ocds, "distribution")
    _cert_at = _at(ocds, "certificate")
    _bucket = (_bucket_at?.id) or _name

    # What ACM needs in DNS before it issues the certificate. A DnsZone XR
    # turns these into records; without them the certificate never leaves
    # PENDING_VALIDATION.
    _validation = [{
        name = _v.resourceRecordName
        $type = _v.resourceRecordType
        value = _v.resourceRecordValue
    } for _v in (_cert_at?.domainValidationOptions or [])]

    # The endpoint the page answers on when nothing is cached in front of it.
    _site_host = "${_bucket}.s3-website-${_region}.amazonaws.com"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "LandingPage"
        metadata.name = _name
        status = {
            provider = "aws"
            bucketName = _bucket
            cdn = _cdn
            if _cdn:
                ready = (_dist_at?.status or "") == "Deployed"
                if _dist_at?.domainName:
                    host = _dist_at.domainName
                    dnsTarget = _dist_at.domainName
                    dnsRecordType = "CNAME"
                if _domain:
                    url = "https://${_domain}"
                elif _dist_at?.domainName:
                    url = "https://${_dist_at.domainName}"
                if _dist_at?.arn:
                    arn = _dist_at.arn
                if _dist_at?.id:
                    id = _dist_at.id
                    # Distributions are listed by id, so the console link only
                    # exists once the distribution does.
                    "cloud-url" = "https://console.aws.amazon.com/cloudfront/v4/home#/distributions/${_dist_at.id}"
            else:
                # Nothing to wait for but the bucket: the website endpoint is
                # live as soon as S3 answers for it.
                ready = (_bucket_at?.arn or "") != ""
                host = _site_host
                dnsTarget = _site_host
                dnsRecordType = "CNAME"
                url = "http://${_site_host}"
                if _bucket_at?.id:
                    id = _bucket_at.id
                "cloud-url" = "https://s3.console.aws.amazon.com/s3/buckets/${_bucket}?region=${_region}"
            if _validation:
                validationRecords = _validation
            if _cert_at?.status:
                certificateStatus = _cert_at.status
        }
    }
}
