# bucket (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-storage schema package. Maps the portable Bucket
# common parameters onto a single GCS Bucket (GCS expresses versioning,
# access, encryption, retention, lifecycle, cors, logging and website inline).
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as backend

# Abstract storage tier -> gcp native value.
_storage_class = {"standard" = "STANDARD", "nearline" = "NEARLINE", "cold" = "COLDLINE", "archive" = "ARCHIVE"}

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# One abstract lifecycleRules entry -> zero/one/two native GCS lifecycle rules.
_gcp_lifecycle = lambda r: any -> [any] {
    _prefix = r?.prefix or ""
    _cond = lambda days: int -> any {
        {age = days} if _prefix == "" else {age = days, matchesPrefix = [_prefix]}
    }
    _rules: [any] = []
    if r?.expirationDays != Undefined:
        _rules += [{action = {$type = "Delete"}, condition = _cond(r.expirationDays)}]

    if r?.transitionDays != Undefined and r?.transitionStorageClass != Undefined:
        _rules += [{
            action = {$type = "SetStorageClass", storageClass = _storage_class[r.transitionStorageClass]}
            condition = _cond(r.transitionDays)
        }]

    _rules
}

render = lambda oxr {
    _spec = oxr.spec
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

    # Native lifecycle = storageClass tier transition + any explicit rules.
    _lifecycle: [any] = []
    _sc = _spec?.storageClass
    if _sc and _sc != "standard":
        _lifecycle += [{
            action = {$type = "SetStorageClass", storageClass = _storage_class[_sc]}
            condition = {age = 0, sendAgeIfZero = True}
        }]

    _lifecycle += [_x for _r in (_spec?.lifecycleRules or []) for _x in _gcp_lifecycle(_r)]

    [backend.Bucket {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _del == "Orphan":
            spec.managementPolicies = _orphan_policies
        spec.forProvider.location = _spec.region
        spec.forProvider.forceDestroy = _spec?.forceDestroy or False
        spec.forProvider.versioning = {enabled = _versioning}
        spec.forProvider.uniformBucketLevelAccess = _uniform
        spec.forProvider.publicAccessPrevention = "enforced" if _block else "inherited"
        spec.forProvider.requesterPays = _spec?.requesterPays or False
        if _sc:
            spec.forProvider.storageClass = _storage_class[_sc]
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.encryption = {defaultKmsKeyName = _spec.encryptionKmsKeyId}
        if _spec?.retention:
            spec.forProvider.retentionPolicy = {
                retentionPeriod = _spec.retention.days * 86400
                isLocked = (_spec.retention?.mode or "governance") == "compliance"
            }
        if _spec?.logging:
            spec.forProvider.logging = {
                logBucket = _spec.logging.targetBucket
                if _spec.logging?.targetPrefix:
                    logObjectPrefix = _spec.logging.targetPrefix
            }
        if _spec?.website:
            spec.forProvider.website = {
                mainPageSuffix = _spec.website?.indexDocument or "index.html"
                if _spec.website?.errorDocument:
                    notFoundPage = _spec.website.errorDocument
            }
        if _spec?.cors:
            spec.forProvider.cors = [{
                origin = _c.origins
                method = _c.methods
                responseHeader = _c?.headers or []
                maxAgeSeconds = _c?.maxAgeSeconds or 3600
            } for _c in _spec.cors]
        if _lifecycle:
            spec.forProvider.lifecycleRule = _lifecycle
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = (_at?.id) or oxr.metadata.name
    _dxr = {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Bucket"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            ready = _at != Undefined and (_at?.id or "") != ""
            bucketName = _name
            "cloud-url" = "https://console.cloud.google.com/storage/browser/${_name}"
            endpoint = "${_name}.storage.googleapis.com"
            if _at:
                if _at?.url:
                    url = _at.url
                if _at?.selfLink:
                    selfLink = _at.selfLink
                if _at?.id:
                    id = _at.id
                if _at?.location:
                    region = _at.location
                if _at?.storageClass:
                    storageClass = _at.storageClass
        }
    }
    _dxr
}
