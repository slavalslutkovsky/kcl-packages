# registry (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-containerregistry schema package. ACR is a single
# resource: the registry carries its own retention, replication, anonymous-pull
# and encryption settings, so this backend composes exactly one MR. A registry
# name must be 5-50 alphanumeric characters, which the XR name has to satisfy.
import azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_registry as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Features ACR gates behind Premium: untagged-image retention, geo-replication
# and zone redundancy. Asking for any of them upgrades the sku rather than
# rendering a registry Azure would reject.
sku_for = lambda spec: any -> str {
    _premium = (spec?.tier or "standard") == "premium" or (spec?.replicationRegions or []) != [] or (spec?.untaggedRetentionDays or Undefined) != Undefined
    "Premium" if _premium else "Standard"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _location = _spec.region

    # A Container Registry cannot exist outside a resource group and this XR
    # does not manage one; fail loud instead of rendering something Azure
    # rejects with a reference-resolution error.
    assert _spec?.resourceGroup, "registry-azure: spec.resourceGroup is required (the Resource Group the registry lives in)"

    _untagged = _spec?.untaggedRetentionDays or Undefined
    _sku = sku_for(_spec)
    # ACR rejects the registry's own location in georeplications.
    _replicas = [_r for _r in (_spec?.replicationRegions or []) if _r != _location]

    # external-name pins the ACR name to the XR name: it is the login server
    # host (<name>.azurecr.io), so it cannot be the random name Crossplane
    # generates for the composed resource.
    [backend.Registry {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if (_spec?.deletionPolicy or "Delete") == "Orphan":
            spec.managementPolicies = _orphan_policies
        spec.forProvider.location = _location
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.sku = _sku
        # Admin user is a shared static credential pair; Entra ID tokens
        # (az acr login) are the supported path, so it stays off.
        spec.forProvider.adminEnabled = False
        spec.forProvider.anonymousPullEnabled = _spec?.publicAccess or False
        spec.forProvider.publicNetworkAccessEnabled = True
        spec.forProvider.zoneRedundancyEnabled = _sku == "Premium"
        if _untagged != Undefined:
            spec.forProvider.retentionPolicyInDays = _untagged
        if _replicas:
            spec.forProvider.georeplications = [{
                location = _r
                regionalEndpointEnabled = True
                zoneRedundancyEnabled = False
            } for _r in _replicas]
        # Customer-managed keys need a user-assigned identity: ACR reads the
        # Key Vault key as that identity, and its system identity cannot be
        # granted access before the registry exists. Both or neither.
        if _spec?.encryptionKeyId and _spec?.encryptionIdentityClientId:
            spec.forProvider.identity = {$type = "UserAssigned"}
            spec.forProvider.encryption = {
                keyVaultKeyId = _spec.encryptionKeyId
                identityClientId = _spec.encryptionIdentityClientId
            }
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _location = (_at?.location) or oxr.spec.region
    _login = _at?.loginServer or ""
    _id = _at?.id or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Registry"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = _login != ""
            registryName = _name
            region = _location
            "cloud-url" = "https://portal.azure.com/#@/resource${_id}" if _id else "https://portal.azure.com/#browse/Microsoft.ContainerRegistry%2Fregistries"
            if _login:
                endpoint = _login
                # ACR is the host; the repository namespace under it is created
                # on first push. Report the path the XR owns by convention.
                repository = "${_login}/${_name}"
                url = "oci://${_login}/${_name}"
            if _id:
                id = _id
        }
    }
}
