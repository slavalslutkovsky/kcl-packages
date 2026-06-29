# bucket (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-storage schema package.
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account as backend
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_management_policy as policy

# Azure accessTier has no account-level Archive: tier blobs to Archive
# via a companion ManagementPolicy MR for the deepest tier(s).
_access_tier = {"standard" = "Hot", "nearline" = "Cool", "cold" = "Cold", "archive" = "Cold"}
_archive_days = {"archive" = 180}

render = lambda oxr {
    _items: [any] = [backend.Account {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        spec.forProvider.location = oxr.spec.region
        spec.forProvider.accountTier = "Standard"
        spec.forProvider.accountReplicationType = "LRS"
        if oxr.spec?.storageClass:
            spec.forProvider.accessTier = _access_tier[oxr.spec.storageClass]
    }]
    _sc = oxr.spec?.storageClass
    if _sc and _sc in _archive_days:
        _items += [policy.ManagementPolicy {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "lifecycle"}
            spec.forProvider.storageAccountIdSelector.matchControllerRef = True
            spec.forProvider.$rule = [{
                name = "archive"
                enabled = True
                filters = {blobTypes = ["blockBlob"]}
                actions = {baseBlob = {tierToArchiveAfterDaysSinceModificationGreaterThan = _archive_days[_sc]}}
            }]
        }]
    _items
}
