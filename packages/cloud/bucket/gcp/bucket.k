# bucket (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-storage schema package.
import gcp_storage.models.v1beta1.storage_gcpm_upbound_io_v1beta1_bucket as backend

# Abstract storage tier -> gcp native value.
_storage_class = {"standard" = "STANDARD", "nearline" = "NEARLINE", "cold" = "COLDLINE", "archive" = "ARCHIVE"}

render = lambda oxr {
    [backend.Bucket {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider.location = oxr.spec.region
        spec.forProvider.versioning = False
        if oxr.spec?.storageClass:
            spec.forProvider.storageClass = _storage_class[oxr.spec.storageClass]
    }]
}
