# bucket (rustfs) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-s3 schema package.
#
# spec.import adopts a bucket that already exists on the RustFS endpoint: the
# name is the S3 identifier for both the Bucket and its lifecycle companion, so
# both pin crossplane.io/external-name to it, and the companion names the
# bucket directly instead of resolving the selector.
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket as backend
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_lifecycle_configuration as lifecycle

# S3 has no bucket-level storage class: map the abstract tier to an object
# lifecycle transition on a companion BucketLifecycleConfiguration MR.
_transition = {"nearline" = {storageClass = "STANDARD_IA", days = 30}, "cold" = {storageClass = "GLACIER_IR", days = 90}, "archive" = {storageClass = "DEEP_ARCHIVE", days = 180}}

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# How Crossplane relates to the bucket, for status.mode:
# created (Crossplane made it) | observe (adopted, read-only) | managed (adopted, Crossplane writes).
mode_of = lambda oxr -> str {
    _imp = oxr.spec?.$import
    "created" if not _imp?.existingName else ("observe" if (_imp?.mode or "observe") == "observe" else "managed")
}

render = lambda oxr {
    _spec = oxr.spec
    _del = _spec?.deletionPolicy or "Delete"
    _imp = _spec?.$import
    _existing = _imp?.existingName
    _observe = _existing and (_imp?.mode or "observe") == "observe"
    _mp = ["Observe"] if _observe else (_orphan_policies if _del == "Orphan" else Undefined)
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

    _items: [any] = [backend.Bucket {
        metadata.annotations = _annos("managed")
        if _mp:
            spec.managementPolicies = _mp
        spec.providerConfigRef.kind = "ProviderConfig"
        spec.providerConfigRef.name = "rustfs"
        spec.forProvider.region = "us-east-1"
    }]
    _sc = _spec?.storageClass
    if _sc and _sc in _transition:
        _t = _transition[_sc]
        _items += [lifecycle.BucketLifecycleConfiguration {
            metadata.annotations = _annos("lifecycle")
            if _mp:
                spec.managementPolicies = _mp
            spec.providerConfigRef.kind = "ProviderConfig"
            spec.providerConfigRef.name = "rustfs"
            spec.forProvider.region = "us-east-1"
            if _existing:
                spec.forProvider.bucket = _existing
            else:
                spec.forProvider.bucketSelector.matchControllerRef = True
            spec.forProvider.$rule = [{
                id = "storage-class"
                status = "Enabled"
                $filter = [{}]
                transition = [{days = _t.days, storageClass = _t.storageClass}]
            }]
        }]

    _items
}
