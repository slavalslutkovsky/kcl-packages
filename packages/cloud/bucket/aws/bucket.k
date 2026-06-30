# bucket (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-s3 schema package. The S3 Bucket MR is intentionally
# minimal; versioning, encryption, public-access, ownership, lifecycle, object
# lock, cors, logging, website and request-payment are each a companion MR that
# binds back to the Bucket via bucketSelector.matchControllerRef.
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket as backend
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_versioning as versioning
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_server_side_encryption_configuration as encryption
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_public_access_block as pab
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_ownership_controls as ownership
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_lifecycle_configuration as lifecycle
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_object_lock_configuration as objectlock
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_cors_configuration as cors
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_logging as logging
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_website_configuration as website
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_request_payment_configuration as payment

# Abstract storage tier -> S3 native class for lifecycle transitions
# (S3 has no bucket-level storage class).
_aws_class = {"standard" = "STANDARD", "nearline" = "STANDARD_IA", "cold" = "GLACIER_IR", "archive" = "DEEP_ARCHIVE"}
# storageClass tier -> implicit transition (class + age in days).
_transition = {"nearline" = {storageClass = "STANDARD_IA", days = 30}, "cold" = {storageClass = "GLACIER_IR", days = 90}, "archive" = {storageClass = "DEEP_ARCHIVE", days = 180}}

_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr {
    _spec = oxr.spec
    _region = _spec.region
    _versioning = _spec?.versioning
    if _versioning == Undefined:
        _versioning = True

    _block = _spec?.blockPublicAccess
    if _block == Undefined:
        _block = True

    _uniform = _spec?.uniformAccess
    if _uniform == Undefined:
        _uniform = True

    _del = _spec?.deletionPolicy or "Delete"
    _mp = _orphan_policies if _del == "Orphan" else Undefined

    # Common scaffolding for a companion MR: name annotation, region, controller binding.
    _attach = lambda name: str -> any {
        _c = {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = name}
            spec.forProvider.region = _region
            spec.forProvider.bucketSelector.matchControllerRef = True
        }
        _c | {spec.managementPolicies = _mp} if _mp else _c
    }

    # 1) Bucket (minimal).
    _items: [any] = [backend.Bucket {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.forceDestroy = _spec?.forceDestroy or False
        if _spec?.retention:
            spec.forProvider.objectLockEnabled = True
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) Versioning (always managed: Enabled or Suspended).
    _items += [versioning.BucketVersioning {
        **_attach("versioning")
        spec.forProvider.versioningConfiguration = {status = "Enabled" if _versioning else "Suspended"}
    }]

    # 3) Public access block (always managed).
    _items += [pab.BucketPublicAccessBlock {
        **_attach("public-access-block")
        spec.forProvider.blockPublicAcls = _block
        spec.forProvider.blockPublicPolicy = _block
        spec.forProvider.ignorePublicAcls = _block
        spec.forProvider.restrictPublicBuckets = _block
    }]

    # 4) Ownership controls (ACLs disabled when uniform).
    _items += [ownership.BucketOwnershipControls {
        **_attach("ownership")
        spec.forProvider.$rule = {objectOwnership = "BucketOwnerEnforced" if _uniform else "BucketOwnerPreferred"}
    }]

    # 5) Server-side encryption — KMS when a key is given (S3 applies SSE-S3 by default otherwise).
    if _spec?.encryptionKmsKeyId:
        _items += [encryption.BucketServerSideEncryptionConfiguration {
            **_attach("encryption")
            spec.forProvider.$rule = [{
                applyServerSideEncryptionByDefault = {sseAlgorithm = "aws:kms", kmsMasterKeyId = _spec.encryptionKmsKeyId}
                bucketKeyEnabled = True
            }]
        }]

    # 6) Lifecycle: storageClass tier transition + explicit rules, merged into one config.
    _sc = _spec?.storageClass
    _tier_rule = [{
        id = "storage-class"
        status = "Enabled"
        $filter = [{}]
        transition = [{days = _transition[_sc].days, storageClass = _transition[_sc].storageClass}]
    }] if (_sc and _sc in _transition) else []
    _aws_rule = lambda r: any -> any {
        _base = {id = r.id, status = "Enabled", $filter = [{prefix = r?.prefix or ""}]}
        _with_exp = (_base | {expiration = [{days = r.expirationDays}]}) if r?.expirationDays != Undefined else _base
        (_with_exp | {transition = [{days = r.transitionDays, storageClass = _aws_class[r.transitionStorageClass]}]}) if (r?.transitionDays != Undefined and r?.transitionStorageClass != Undefined) else _with_exp
    }
    _rules = _tier_rule + [_aws_rule(_r) for _r in (_spec?.lifecycleRules or [])]
    if _rules:
        _items += [lifecycle.BucketLifecycleConfiguration {
            **_attach("lifecycle")
            spec.forProvider.$rule = _rules
        }]

    # 7) Object lock / retention.
    if _spec?.retention:
        _items += [objectlock.BucketObjectLockConfiguration {
            **_attach("object-lock")
            spec.forProvider.$rule = {
                defaultRetention = {
                    mode = "COMPLIANCE" if (_spec.retention?.mode or "governance") == "compliance" else "GOVERNANCE"
                    days = _spec.retention.days
                }
            }
        }]

    # 8) CORS.
    if _spec?.cors:
        _items += [cors.BucketCorsConfiguration {
            **_attach("cors")
            spec.forProvider.corsRule = [{
                allowedOrigins = _c.origins
                allowedMethods = _c.methods
                allowedHeaders = _c?.headers or []
                maxAgeSeconds = _c?.maxAgeSeconds or 3600
            } for _c in _spec.cors]
        }]

    # 9) Access logging.
    if _spec?.logging:
        _items += [logging.BucketLogging {
            **_attach("logging")
            spec.forProvider.targetBucket = _spec.logging.targetBucket
            spec.forProvider.targetPrefix = _spec.logging?.targetPrefix or ""
        }]

    # 10) Static website.
    if _spec?.website:
        _items += [website.BucketWebsiteConfiguration {
            **_attach("website")
            spec.forProvider.indexDocument = {suffix = _spec.website?.indexDocument or "index.html"}
            if _spec.website?.errorDocument:
                spec.forProvider.errorDocument = {key = _spec.website.errorDocument}
        }]

    # 11) Requester pays.
    if _spec?.requesterPays:
        _items += [payment.BucketRequestPaymentConfiguration {
            **_attach("request-payment")
            spec.forProvider.payer = "Requester"
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = (_at?.id) or oxr.metadata.name
    _region = (_at?.region) or oxr.spec.region
    _dxr = {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Bucket"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = _at != Undefined and (_at?.arn or "") != ""
            bucketName = _name
            region = _region
            url = "s3://${_name}"
            "cloud-url" = "https://s3.console.aws.amazon.com/s3/buckets/${_name}?region=${_region}"
            if _at:
                if _at?.arn:
                    arn = _at.arn
                if _at?.bucketRegionalDomainName:
                    endpoint = _at.bucketRegionalDomainName
                elif _at?.bucketDomainName:
                    endpoint = _at.bucketDomainName
                if _at?.id:
                    id = _at.id
        }
    }
    _dxr
}
