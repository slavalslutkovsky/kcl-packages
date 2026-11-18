# bucket (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-s3 schema package. The S3 Bucket MR is intentionally
# minimal; versioning, encryption, public-access, ownership, lifecycle, object
# lock, cors, logging, website and request-payment are each a companion MR that
# binds back to the Bucket via bucketSelector.matchControllerRef.
#
# spec.import adopts a bucket that already exists (Terraform/Pulumi-made):
# every MR — the Bucket and each companion — gets crossplane.io/external-name
# pinned to the existing bucket name, because for all of them that name IS the
# provider's identifier (the S3 companion APIs are keyed by bucket). Companions
# then name the bucket directly instead of resolving it through the selector,
# so nothing waits on a reference in observe-only mode.
#
# spec.access (render_access) gives CI pipelines and the ticket systems that
# start them keyless access: per entry an aws-iam Role trusting the account's
# IAM OIDC provider for the entry's issuer, plus an inline RolePolicy scoped
# to this bucket (federation library: packages/cloud/federation).
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
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as iamrole
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy as iampolicy
import federation.lib as fed
import crypto
import json

# Abstract storage tier -> S3 native class for lifecycle transitions
# (S3 has no bucket-level storage class).
_aws_class = {"standard" = "STANDARD", "nearline" = "STANDARD_IA", "cold" = "GLACIER_IR", "archive" = "DEEP_ARCHIVE"}
# storageClass tier -> implicit transition (class + age in days).
_transition = {"nearline" = {storageClass = "STANDARD_IA", days = 30}, "cold" = {storageClass = "GLACIER_IR", days = 90}, "archive" = {storageClass = "DEEP_ARCHIVE", days = 180}}

_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# spec.access role -> S3 actions on the bucket ARN and on its objects. Object
# data only: never bucket configuration, bucket policy or IAM.
#   read  = list + get (any version)
#   write = read + put/delete (a delete marker when versioned) + multipart
#   admin = write + permanent version deletes, restore, ACLs, tagging,
#           retention / legal hold (incl. bypassing GOVERNANCE retention)
_s3_read_bucket = ["s3:ListBucket", "s3:GetBucketLocation"]
_s3_read_objects = ["s3:GetObject", "s3:GetObjectVersion"]
_s3_write_bucket = _s3_read_bucket + ["s3:ListBucketMultipartUploads"]
_s3_write_objects = _s3_read_objects + ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
_s3_bucket_actions = {
    read = _s3_read_bucket
    write = _s3_write_bucket
    admin = _s3_write_bucket + ["s3:ListBucketVersions"]
}
_s3_object_actions = {
    read = _s3_read_objects
    write = _s3_write_objects
    admin = _s3_write_objects + ["s3:DeleteObjectVersion", "s3:RestoreObject", "s3:GetObjectAcl", "s3:PutObjectAcl", "s3:GetObjectVersionAcl", "s3:PutObjectVersionAcl", "s3:GetObjectTagging", "s3:PutObjectTagging", "s3:DeleteObjectTagging", "s3:GetObjectVersionTagging", "s3:PutObjectVersionTagging", "s3:DeleteObjectVersionTagging", "s3:GetObjectRetention", "s3:PutObjectRetention", "s3:GetObjectLegalHold", "s3:PutObjectLegalHold", "s3:BypassGovernanceRetention"]
}
# KMS key use the role needs when the bucket encrypts with a customer key.
_kms_actions = {read = ["kms:Decrypt"], write = ["kms:Decrypt", "kms:GenerateDataKey"], admin = ["kms:Decrypt", "kms:GenerateDataKey"]}

# The IAM role name an access entry pins: "<xr namespace>-<xr name>-<entry>",
# cut to IAM's 64 characters with a hash of the full name when longer.
access_role_name = lambda oxr, entry: str -> str {
    _full = "${oxr.metadata?.namespace or 'default'}-${oxr.metadata.name}-${entry}"
    _full if len(_full) <= 64 else "${_full[:55]}-${crypto.sha256(_full)[:8]}"
}

# Inline policy of an access role: `level` (read|write|admin) on bucket
# `bucketName` and its objects, plus the bucket's KMS key when one is set.
access_policy = lambda level: str, bucketName: str, kmsKeyArn: str -> str {
    _stmts = [
        {Sid = "Bucket", Effect = "Allow", Action = _s3_bucket_actions[level], Resource = "arn:aws:s3:::${bucketName}"}
        {Sid = "Objects", Effect = "Allow", Action = _s3_object_actions[level], Resource = "arn:aws:s3:::${bucketName}/*"}
    ]
    if kmsKeyArn:
        _stmts += [{Sid = "Kms", Effect = "Allow", Action = _kms_actions[level], Resource = kmsKeyArn}]

    json.encode({Version = "2012-10-17", Statement = _stmts})
}

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

    # Import: adopt an existing bucket. observe = Crossplane reads only (the
    # old tool still owns writes); manage = full policies, deletionPolicy as usual.
    _imp = _spec?.$import
    _existing = _imp?.existingName
    _observe = _existing and (_imp?.mode or "observe") == "observe"
    _mp = ["Observe"] if _observe else (_orphan_policies if _del == "Orphan" else Undefined)

    # Annotations every MR carries: the composition-resource-name, plus — when
    # adopting — the external-name pin and where the bucket came from.
    _annos = lambda name: str -> {str:str} {
        _a = {"krm.kcl.dev/composition-resource-name" = name}
        if _existing:
            _a |= {"crossplane.io/external-name" = _existing}

        if _imp?.source:
            _a |= {"cloud.example.org/imported-from" = _imp.source}

        if _imp?.address:
            _a |= {"cloud.example.org/import-address" = _imp.address}

        _a
    }

    # Common scaffolding for a companion MR: annotations, region, bucket binding.
    _attach = lambda name: str -> any {
        _c = {
            metadata.annotations = _annos(name)
            spec.forProvider.region = _region
            if _existing:
                spec.forProvider.bucket = _existing
            else:
                spec.forProvider.bucketSelector.matchControllerRef = True
        }
        _c | {spec.managementPolicies = _mp} if _mp else _c
    }

    # 1) Bucket (minimal).
    _items: [any] = [backend.Bucket {
        metadata.annotations = _annos("managed")
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

# spec.access: one IAM Role per entry, trusting the account's IAM OIDC
# provider for the entry's issuer (aud + sub, see federation.aws_trust), with
# its name pinned so the inline RolePolicy can name it. The policy needs the
# bucket name, which a created bucket only has once observed: it is composed
# on the pass after the Bucket shows up in ocds (import.existingName: at once).
render_access = lambda oxr, ocds -> [any] {
    _spec = oxr.spec
    _fedcfg = _spec?.federation or {}
    assert not _fedcfg?.gcpProjectNumber, "bucket-aws: spec.federation.gcpProjectNumber is GCP-only; AWS access roles trust spec.federation.awsAccountId"
    assert not _fedcfg?.azureResourceGroup, "bucket-aws: spec.federation.azureResourceGroup is Azure-only; AWS access roles trust spec.federation.awsAccountId"
    _entries = fed.access_list(_spec?.access or [])
    _account = _fedcfg?.awsAccountId
    assert not _entries or _account, "bucket-aws: spec.federation.awsAccountId is required with spec.access: the account whose IAM OIDC providers (one per issuer) the access roles trust"
    _imp = _spec?.$import
    _observe = _imp?.existingName and (_imp?.mode or "observe") == "observe"
    assert not _entries or not _observe, "bucket-aws: access writes IAM; Crossplane promised read-only in observe mode — switch import.mode to manage or drop access"
    _kms = _spec?.encryptionKmsKeyId or ""
    assert not _entries or not _kms or (_kms.startswith("arn:") and ":key/" in _kms), "bucket-aws: access grants kms:Decrypt on encryptionKmsKeyId, which must then be a key ARN (arn:aws:kms:<region>:<account>:key/<id>), got '${_kms}'"
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _bucket = _imp?.existingName or _at?.id
    _xr = "${oxr.metadata?.namespace or 'default'}/${oxr.metadata.name}"

    _one = lambda entry: any -> [any] {
        _n = fed.access_name(entry)
        _rn = access_role_name(oxr, _n)
        _t = fed.ticket_of(entry)
        _who = fed.client_of(entry).label + (" started by ${_t.label}" if _t else "")
        _role = [iamrole.Role {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "access-${_n}"
                "crossplane.io/external-name" = _rn
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.assumeRolePolicy = json.encode(fed.aws_trust(entry, _account))
            spec.forProvider.description = "Keyless ${entry.role} access to Bucket ${_xr} for ${_who} (${_n})"
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]
        _policy = [iampolicy.RolePolicy {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "access-${_n}-policy"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.role = _rn
            spec.forProvider.policy = access_policy(entry.role, _bucket, _kms)
        }] if _bucket else []
        _role + _policy
    }

    [_r for _x in _entries for _r in _one(_x)]
}

# How Crossplane relates to the cloud bucket, for status.mode:
# created (Crossplane made it) | observe (adopted, read-only) | managed (adopted, Crossplane writes).
mode_of = lambda oxr -> str {
    _imp = oxr.spec?.$import
    "created" if not _imp?.existingName else ("observe" if (_imp?.mode or "observe") == "observe" else "managed")
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _access = fed.access_list(oxr.spec?.access or [])
    _access_status = lambda entry: any -> {str:} {
        _n = fed.access_name(entry)
        _ra = (ocds["access-${_n}"]?.Resource?.status?.atProvider) if ("access-${_n}" in ocds) else Undefined
        {
            name = _n
            role = entry.role
            if _ra?.arn:
                roleArn = _ra.arn
        }
    }
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _imp = oxr.spec?.$import
    _name = (_at?.id) or _imp?.existingName or oxr.metadata.name
    _region = (_at?.region) or oxr.spec.region
    _dxr = {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Bucket"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            mode = mode_of(oxr)
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
            if _access:
                access = [_access_status(_x) for _x in _access]
        }
    }
    _dxr
}
