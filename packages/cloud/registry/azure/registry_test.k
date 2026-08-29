# Unit tests for the registry (azure) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
import .registry

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
# Every spec below carries resourceGroup: render() asserts on it ("the azure
# backend requires spec.resourceGroup") and KCL has no way to catch a failed
# assert inside a test, so the missing-field path is exercised by inspection
# (and by `kcl run` with the field removed), not by a test lambda.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Registry", metadata.name = "demoreg", spec = {region = "westeurope", resourceGroup = "demo-rg"} | extra}
}

# The Container Registry forProvider block for the given spec.
_fp = lambda extra: any -> any {
    registry.render(_build(extra))[0].spec.forProvider
}

# 1) Minimal spec: exactly one MR — a Standard registry, private, admin user off.
test_render_minimal = lambda {
    items = registry.render(_build({}))
    assert len(items) == 1, "ACR is a single resource: one managed resource"
    assert items[0].apiVersion == "containerregistry.azure.m.upbound.io/v1beta1", "wrong Registry apiVersion"
    assert items[0].kind == "Registry", "the composed MR must be the Registry"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demoreg", "the ACR name must be pinned to the XR name"
    _f = items[0].spec.forProvider
    assert _f.location == "westeurope", "region must become the location"
    assert _f.resourceGroupName == "demo-rg", "resourceGroup must reach the registry"
    assert _f.sku == "Standard", "standard tier must map to the Standard sku"
    assert _f.adminEnabled == False, "the shared admin credential pair must stay off"
    assert _f.anonymousPullEnabled == False, "registries must be private by default"
    assert _f.publicNetworkAccessEnabled == True, "the registry must be reachable"
    assert _f.zoneRedundancyEnabled == False, "zone redundancy is Premium-only"
    assert _f?.retentionPolicyInDays == Undefined, "no retention asked for"
    assert _f?.georeplications == Undefined, "no replication asked for"
    assert _f?.encryption == Undefined, "no CMEK asked for"
}

# 2) tier=premium selects the Premium sku and zone redundancy.
test_premium_tier = lambda {
    _f = _fp({tier = "premium"})
    assert _f.sku == "Premium", "premium tier must map to the Premium sku"
    assert _f.zoneRedundancyEnabled == True, "Premium registries are zone redundant"
}

# 3) Premium-only features upgrade the sku by themselves rather than rendering
#    a registry Azure would reject.
test_retention_forces_premium = lambda {
    _f = _fp({untaggedRetentionDays = 21})
    assert _f.sku == "Premium", "retention is Premium-only, so the sku must upgrade"
    assert _f.retentionPolicyInDays == 21, "retention days must be carried through"
}
test_replication_forces_premium = lambda {
    _f = _fp({replicationRegions = ["northeurope", "eastus"]})
    assert _f.sku == "Premium", "geo-replication is Premium-only, so the sku must upgrade"
    assert [_g.location for _g in _f.georeplications] == ["northeurope", "eastus"], "every replica region must be rendered"
    assert _f.georeplications[0].regionalEndpointEnabled == True, "replicas need their regional endpoint"
}

# 4) ACR rejects its own location as a replica; the primary region is filtered.
test_replication_drops_primary = lambda {
    _f = _fp({replicationRegions = ["westeurope", "northeurope"]})
    assert [_g.location for _g in _f.georeplications] == ["northeurope"], "the registry's own location must be dropped"
}
test_replication_only_primary = lambda {
    _f = _fp({replicationRegions = ["westeurope"]})
    assert _f?.georeplications == Undefined, "a replica list that collapses to nothing must not render an empty block"
}

# 5) publicAccess maps to anonymous pull.
test_public_access = lambda {
    assert _fp({publicAccess = True}).anonymousPullEnabled == True, "publicAccess must enable anonymous pull"
}

# 6) CMEK needs the key AND the identity that reads it: both or neither.
test_encryption_requires_identity = lambda {
    _f = _fp({encryptionKeyId = "https://kv.vault.azure.net/keys/k/1"})
    assert _f?.encryption == Undefined, "a key without an identity must not render encryption"
    assert _f?.identity == Undefined, "no identity block either"
}
test_encryption_with_identity = lambda {
    _f = _fp({encryptionKeyId = "https://kv.vault.azure.net/keys/k/1", encryptionIdentityClientId = "1111-2222"})
    assert _f.encryption.keyVaultKeyId == "https://kv.vault.azure.net/keys/k/1", "key must be carried through"
    assert _f.encryption.identityClientId == "1111-2222", "identity client id must be carried through"
    assert _f.identity["type"] == "UserAssigned", "CMEK requires a user-assigned identity"
}

# 7) Fields ACR cannot express are dropped, not faked.
test_unsupported_fields_ignored = lambda {
    _f = _fp({immutableTags = True, scanOnPush = True, keepLastImages = 5, forceDestroy = True})
    assert _f?.quarantinePolicyEnabled == Undefined, "scanOnPush is a Defender setting, not a registry field"
    assert _f?.retentionPolicyInDays == Undefined, "keepLastImages has no ACR equivalent"
    assert _f.sku == "Standard", "an ignored field must not silently upgrade the sku"
}

# 8) deletionPolicy=Orphan stamps the orphan managementPolicies.
test_deletion_policy_orphan = lambda {
    assert registry.render(_build({deletionPolicy = "Orphan"}))[0].spec.managementPolicies == _orphan, "Orphan must set the orphan policies"
}
test_deletion_policy_delete_default = lambda {
    assert registry.render(_build({}))[0].spec.managementPolicies == ["*"], "Delete must leave the provider-default managementPolicies"
}

# 9) tags reach the registry.
test_tags = lambda {
    assert _fp({
        tags = {team = "platform"}
    }).tags == {team = "platform"}, "tags must be carried through"
}

# 10) status before creation: not ready, no invented login server.
test_status_pre_creation = lambda {
    dxr = registry.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Registry", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.region == "westeurope", "region must echo the spec"
    assert dxr.status?.endpoint == Undefined, "the login server is unknown until observed"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#browse/Microsoft.ContainerRegistry%2Fregistries", "cloud-url falls back to the registry list"
}

# 11) status after creation: ready, endpoint is the observed login server.
test_status_observed = lambda {
    _id = "/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.ContainerRegistry/registries/demoreg"
    ocds = {
        managed.Resource.status.atProvider = {
            id = _id
            loginServer = "demoreg.azurecr.io"
            location = "westeurope"
            sku = "Standard"
        }
    }
    dxr = registry.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed login server must mark the registry ready"
    assert dxr.status.endpoint == "demoreg.azurecr.io", "endpoint is the login server"
    assert dxr.status.repository == "demoreg.azurecr.io/demoreg", "repository is the login server plus the XR name"
    assert dxr.status.url == "oci://demoreg.azurecr.io/demoreg", "url must be the oci:// form"
    assert dxr.status.id == _id, "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource${_id}", "cloud-url must address the registry"
}

test_render_minimal()
test_premium_tier()
test_retention_forces_premium()
test_replication_forces_premium()
test_replication_drops_primary()
test_replication_only_primary()
test_public_access()
test_encryption_requires_identity()
test_encryption_with_identity()
test_unsupported_fields_ignored()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_tags()
test_status_pre_creation()
test_status_observed()
