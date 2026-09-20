# bucket (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-storage schema package.
#
# spec.import adopts an existing storage account. The account name is the
# provider's external name, but the ARM id it observes also needs the resource
# group, which is why import.resourceGroup exists (Azure only). The lifecycle
# ManagementPolicy is not rendered in observe mode: it is identified through
# the account it belongs to and has nothing to observe on its own.
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account as backend
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_management_policy as policy

# Azure accessTier has no account-level Archive: tier blobs to Archive
# via a companion ManagementPolicy MR for the deepest tier(s).
_access_tier = {"standard" = "Hot", "nearline" = "Cool", "cold" = "Cold", "archive" = "Cold"}
_archive_days = {"archive" = 180}

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# How Crossplane relates to the cloud bucket, for status.mode:
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

    # pin=False for the ManagementPolicy: the provider derives its id from the
    # account, so an external-name there would be wrong, not just redundant.
    _annos = lambda name: str, pin: bool -> {str:str} {
        _a = {"krm.kcl.dev/composition-resource-name" = name}
        if _existing and pin:
            _a |= {"crossplane.io/external-name" = _existing}

        if _imp?.source:
            _a |= {"cloud.example.org/imported-from" = _imp.source}

        if _imp?.address:
            _a |= {"cloud.example.org/import-address" = _imp.address}

        _a
    }

    _items: [any] = [backend.Account {
        metadata.annotations = _annos("managed", True)
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.accountTier = "Standard"
        spec.forProvider.accountReplicationType = "LRS"
        if _imp?.resourceGroup:
            spec.forProvider.resourceGroupName = _imp.resourceGroup
        if _spec?.storageClass:
            spec.forProvider.accessTier = _access_tier[_spec.storageClass]
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]
    _sc = _spec?.storageClass
    if _sc and _sc in _archive_days and not _observe:
        _items += [policy.ManagementPolicy {
            metadata.annotations = _annos("lifecycle", False)
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.storageAccountIdSelector.matchControllerRef = True
            spec.forProvider.$rule = [{
                name = "archive"
                enabled = True
                filters = {blobTypes = ["blockBlob"]}
                actions = {
                    baseBlob = {tierToArchiveAfterDaysSinceModificationGreaterThan = _archive_days[_sc]}
                }
            }]
        }]

    _items
}
