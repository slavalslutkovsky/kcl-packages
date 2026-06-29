# bucket (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-storage schema package.
import gcp_storage.models.v1beta2.storage_gcp_upbound_io_v1beta2_bucket as backend

render = lambda oxr {
    [backend.Bucket {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider.location = oxr.spec.region
    }]
}
