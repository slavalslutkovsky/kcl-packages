# bucket (azure) — Crossplane Composition logic (function-kcl module).
# Untyped fallback. Run `nx g nx-kcl:import-crd azure-storage --image=<provider-image>`
# then regenerate to get typed, default-aware schemas.

render = lambda oxr {
    [{
        apiVersion = "storage.azure.upbound.io/v1beta1"
        kind = "Account"
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider.location = oxr.spec.region
        spec.forProvider.accountTier = "Standard"
        spec.forProvider.accountReplicationType = "LRS"
    }]
}
