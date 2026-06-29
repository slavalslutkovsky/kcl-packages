# bucket (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-s3 schema package.
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket as backend
import aws_s3.models.v1beta1.s3_awsm_upbound_io_v1beta1_bucket_lifecycle_configuration as lifecycle

# S3 has no bucket-level storage class: map the abstract tier to an object
# lifecycle transition on a companion BucketLifecycleConfiguration MR.
_transition = {"nearline" = {storageClass = "STANDARD_IA", days = 30}, "cold" = {storageClass = "GLACIER_IR", days = 90}, "archive" = {storageClass = "DEEP_ARCHIVE", days = 180}}

render = lambda oxr {
    _items: [any] = [backend.Bucket {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider.region = oxr.spec.region
    }]
    _sc = oxr.spec?.storageClass
    if _sc and _sc in _transition:
        _t = _transition[_sc]
        _items += [lifecycle.BucketLifecycleConfiguration {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "lifecycle"}
            spec.forProvider.region = oxr.spec.region
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
