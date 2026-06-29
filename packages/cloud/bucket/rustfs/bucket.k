# bucket (rustfs) — Crossplane Composition logic (function-kcl module).
# Untyped fallback. Run `nx g nx-kcl:import-crd aws-s3 --image=<provider-image>`
# then regenerate to get typed, default-aware schemas.

render = lambda oxr {
    [{
        apiVersion = "s3.aws.upbound.io/v1beta1"
        kind = "Bucket"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.providerConfigRef.name = "rustfs"
        spec.forProvider.region = "us-east-1"
    }]
}
