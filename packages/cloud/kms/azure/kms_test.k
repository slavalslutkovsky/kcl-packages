# Unit tests for the kms (azure) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
import .kms

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base (minimal valid azure) spec merged
# with `extra`. resourceGroup and tenantId are part of the base because the
# azure backend refuses to render without them.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "demo", spec = {region = "westeurope", resourceGroup = "platform-rg", tenantId = "tenant-1"} | extra}
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# forProvider of the Key (second MR) for a spec.
_key_fp = lambda extra: any -> any {
    kms.render(_build(extra))[1].spec.forProvider
}

# forProvider of the Vault (first MR) for a spec.
_vault_fp = lambda extra: any -> any {
    kms.render(_build(extra))[0].spec.forProvider
}

# 1) Minimal spec: vault then key, with every XRD default applied defensively.
test_render_minimal = lambda {
    items = kms.render(_build({}))
    assert len(items) == 2, "azure needs exactly two MRs: the vault holding the material and the key inside it"
    assert _kinds(items) == ["Vault", "Key"], "the vault must be rendered before the key that binds to it"
    assert items[0].apiVersion == "keyvault.azure.m.upbound.io/v1beta1", "wrong Vault apiVersion"
    assert items[1].apiVersion == "keyvault.azure.m.upbound.io/v1beta1", "wrong Key apiVersion"

    # Both names are user-visible: the vault name is its DNS host and the key
    # name is the last segment of every key URI.
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the vault name must be pinned to the XR name"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "demo", "the key name must be pinned to the XR name"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "vault", "the vault MR is addressed as `vault`"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the key MR is addressed as `managed`"

    _v = items[0].spec.forProvider
    assert _v.location == "westeurope", "region must become the vault location"
    assert _v.resourceGroupName == "platform-rg", "resourceGroup must reach the vault"
    assert _v.tenantId == "tenant-1", "tenantId must reach the vault"
    assert _v.skuName == "standard", "software protection must stay on the standard SKU"
    assert _v.enableRbacAuthorization == True, "the vault must use RBAC, not legacy access policies"
    assert _v.purgeProtectionEnabled == True, "purge protection is what makes the soft-delete window a real grace period"
    assert _v.softDeleteRetentionDays == 30, "deletionWindowDays must default to 30"
    assert _v.publicNetworkAccessEnabled == True, "the provider reaches the data plane over the public endpoint"
    assert _v?.tags == Undefined, "no tags asked for means no tags block"

    _k = items[1].spec.forProvider
    assert _k.keyVaultIdSelector.matchControllerRef == True, "the key must bind to the composed vault by controller reference"
    assert _k.keyType == "RSA", "the default symmetric algorithm becomes an RSA wrap key on Key Vault"
    assert _k.keySize == 4096, "the symmetric stand-in must be the strongest RSA key"
    assert _k.keyOpts == ["decrypt", "encrypt", "wrapKey", "unwrapKey"], "encrypt-decrypt must grant the envelope operations"
    assert _k?.rotationPolicy == Undefined, "no rotationDays means no rotation policy"
    assert _k?.tags == Undefined, "no tags asked for means no tags block"
}

# 2) Every algorithm maps to a keyType plus exactly one of keySize / curve.
#    symmetric is the documented RSA-4096 stand-in (Key Vault has no software
#    symmetric key type).
test_algorithm_rsa_sizes = lambda {
    _cases = {"symmetric" = 4096, "rsa-2048" = 2048, "rsa-3072" = 3072, "rsa-4096" = 4096}
    _bad = [_a for _a in _cases if _key_fp({algorithm = _a}).keySize != _cases[_a]]
    assert _bad == [], "RSA modulus size must follow the algorithm, wrong for: ${_bad}"
    _wrong_type = [_a for _a in _cases if _key_fp({algorithm = _a}).keyType != "RSA"]
    assert _wrong_type == [], "every RSA-family algorithm must render keyType RSA, wrong for: ${_wrong_type}"
}
test_algorithm_ec_curves = lambda {
    # EC keys cannot encrypt, so the purpose has to be sign-verify to render.
    _cases = {"ec-p256" = "P-256", "ec-p384" = "P-384"}
    _bad = [_a for _a in _cases if _key_fp({algorithm = _a, purpose = "sign-verify"}).curve != _cases[_a]]
    assert _bad == [], "EC curve must follow the algorithm, wrong for: ${_bad}"
    _wrong_type = [_a for _a in _cases if _key_fp({algorithm = _a, purpose = "sign-verify"}).keyType != "EC"]
    assert _wrong_type == [], "every EC-family algorithm must render keyType EC, wrong for: ${_wrong_type}"
}

# 3) keySize and curve are mutually exclusive in the Key Vault API.
test_key_size_and_curve_exclusive = lambda {
    _rsa = ["symmetric", "rsa-2048", "rsa-3072", "rsa-4096"]
    _with_curve = [_a for _a in _rsa if _key_fp({algorithm = _a})?.curve != Undefined]
    assert _with_curve == [], "an RSA key must never carry a curve, set on: ${_with_curve}"
    _ec = ["ec-p256", "ec-p384"]
    _with_size = [_a for _a in _ec if _key_fp({algorithm = _a, purpose = "sign-verify"})?.keySize != Undefined]
    assert _with_size == [], "an EC key must never carry a keySize, set on: ${_with_size}"
}

# 4) protectionLevel=hsm suffixes the key type AND lifts the vault to premium —
#    an HSM key type is rejected by a standard vault.
test_hsm_suffix_and_sku = lambda {
    _cases = {"symmetric" = "RSA-HSM", "rsa-2048" = "RSA-HSM", "rsa-4096" = "RSA-HSM"}
    _bad = [_a for _a in _cases if _key_fp({algorithm = _a, protectionLevel = "hsm"}).keyType != _cases[_a]]
    assert _bad == [], "hsm must suffix the RSA key type, wrong for: ${_bad}"
    assert _key_fp({algorithm = "ec-p384", purpose = "sign-verify", protectionLevel = "hsm"}).keyType == "EC-HSM", "hsm must suffix the EC key type too"
    assert _key_fp({algorithm = "ec-p384", purpose = "sign-verify", protectionLevel = "hsm"}).curve == "P-384", "the curve must survive the HSM suffix"
    assert _key_fp({algorithm = "rsa-3072", protectionLevel = "hsm"}).keySize == 3072, "the key size must survive the HSM suffix"
}
test_sku_from_protection_level = lambda {
    assert _vault_fp({}).skuName == "standard", "software protection must stay standard"
    assert _vault_fp({protectionLevel = "software"}).skuName == "standard", "explicit software must stay standard"
    assert _vault_fp({protectionLevel = "hsm"}).skuName == "premium", "hsm keys require a premium vault"
}

# 5) purpose is expressed purely as keyOpts — Key Vault has no purpose field.
test_key_opts_per_purpose = lambda {
    assert _key_fp({}).keyOpts == ["decrypt", "encrypt", "wrapKey", "unwrapKey"], "encrypt-decrypt is the default purpose"
    assert _key_fp({purpose = "encrypt-decrypt", algorithm = "rsa-2048"}).keyOpts == ["decrypt", "encrypt", "wrapKey", "unwrapKey"], "encrypt-decrypt must grant wrap/unwrap as well as encrypt/decrypt"
    assert _key_fp({purpose = "sign-verify", algorithm = "rsa-2048"}).keyOpts == ["sign", "verify"], "sign-verify must grant only sign and verify"
    assert _key_fp({purpose = "sign-verify", algorithm = "ec-p256"}).keyOpts == ["sign", "verify"], "an EC key must be sign-only"
}

# 6) Rotation: the expiry is derived at twice the rotation period because Azure
#    rejects an automatic policy without one.
test_rotation_policy_derived = lambda {
    _rp = _key_fp({rotationDays = 90}).rotationPolicy
    assert _rp.automatic.timeAfterCreation == "P90D", "rotation must happen rotationDays after creation"
    assert _rp.expireAfter == "P180D", "the derived expiry must be twice the rotation period"
    assert _rp.notifyBeforeExpiry == "P30D", "expiry notification must be the fixed 30-day window"
    assert _key_fp({rotationDays = 30}).rotationPolicy.expireAfter == "P60D", "the expiry must track the rotation period"
}
test_rotation_off_by_default = lambda {
    assert _key_fp({})?.rotationPolicy == Undefined, "no rotationDays means Key Vault keeps its default (no rotation policy)"
}

# 7) deletionWindowDays maps to the vault's soft-delete retention; the key
#    itself has no window (the vault owns the material).
test_deletion_window = lambda {
    assert _vault_fp({deletionWindowDays = 7}).softDeleteRetentionDays == 7, "the minimum window must reach the vault"
    assert _vault_fp({deletionWindowDays = 90}).softDeleteRetentionDays == 90, "the maximum window must reach the vault"
}

# 8) tags land on both MRs (Azure tags are per-resource, not inherited).
test_tags_on_both_resources = lambda {
    items = kms.render(_build({
        tags = {team = "platform"}
    }))
    _missing = [_i.kind for _i in items if _i.spec.forProvider?.tags != {team = "platform"}]
    assert _missing == [], "tags must reach every MR, missing on: ${_missing}"
}

# 9) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves the provider default ["*"] in place.
test_deletion_policy_orphan = lambda {
    items = kms.render(_build({deletionPolicy = "Orphan", rotationDays = 30, tags = {a = "b"}}))
    _missing = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = kms.render(_build({}))
    _stamped = [_i.kind for _i in items if _i.spec.managementPolicies == ["*"]]
    assert len(_stamped) == 2, "Delete must leave the provider default managementPolicies on every MR"
}

# 10) status before creation: not ready, and nothing that only Azure can tell
#     us is invented.
test_status_pre_creation = lambda {
    dxr = kms.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EncryptionKey", "dxr kind must echo the composite"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.keyName == "demo", "the key name is the XR name"
    assert dxr.status.region == "westeurope", "region falls back to the requested one"
    assert dxr.status?.vaultUri == Undefined, "the vault URI is unknown until observed"
    assert dxr.status?.keyUri == Undefined, "the key URI is unknown until observed"
    assert dxr.status?.version == Undefined, "the key version is unknown until observed"
    assert dxr.status?.algorithm == Undefined, "the native key type is unknown until observed"
    assert dxr.status?.protectionLevel == Undefined, "only the observed key type proves HSM backing"
    assert dxr.status?.rotationEnabled == Undefined, "rotation state is unknown until observed"
    assert dxr.status?.id == Undefined, "the resource id is assigned by Azure"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#browse/Microsoft.KeyVault%2Fvaults", "without a vault id the console link can only reach the vault browser"
}

# 11) status after creation reads the two MRs from DIFFERENT ocds entries: the
#     location and URI come from the vault, the key identity from the key.
test_status_observed = lambda {
    _vault_id = "/subscriptions/sub-1/resourceGroups/platform-rg/providers/Microsoft.KeyVault/vaults/demo"
    ocds = {
        vault.Resource.status.atProvider = {
            id = _vault_id
            location = "northeurope"
            vaultUri = "https://demo.vault.azure.net/"
            skuName = "premium"
        }
        managed.Resource.status.atProvider = {
            id = "https://demo.vault.azure.net/keys/demo/abc123"
            keyType = "RSA-HSM"
            keySize = 4096
            version = "abc123"
            versionlessId = "https://demo.vault.azure.net/keys/demo"
            resourceId = "${_vault_id}/keys/demo/versions/abc123"
            rotationPolicy = {automatic = {timeAfterCreation = "P90D"}, expireAfter = "P180D"}
        }
    }
    dxr = kms.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed versionless key id must mark the key ready"
    assert dxr.status.region == "northeurope", "the observed vault location must win over the requested region"
    assert dxr.status.vaultUri == "https://demo.vault.azure.net/", "the vault URI must come from the vault MR"
    assert dxr.status.keyUri == "https://demo.vault.azure.net/keys/demo", "keyUri must be the versionless URL other Azure resources reference"
    assert dxr.status.keyId == "https://demo.vault.azure.net/keys/demo", "keyId must be the versionless id"
    assert dxr.status.version == "abc123", "the current key version must be surfaced"
    assert dxr.status.algorithm == "RSA-HSM", "algorithm must be the key type Azure reports"
    assert dxr.status.protectionLevel == "hsm", "a -HSM key type means HSM protection"
    assert dxr.status.rotationEnabled == True, "an observed rotation policy means rotation is on"
    assert dxr.status.id == "https://demo.vault.azure.net/keys/demo/abc123", "the observed key id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource${_vault_id}/keys", "cloud-url must address the keys list of the observed vault"
}

# 12) An observed software key without a rotation policy reports both honestly.
test_status_observed_software_no_rotation = lambda {
    ocds = {
        vault.Resource.status.atProvider = {vaultUri = "https://demo.vault.azure.net/", location = "westeurope"}
        managed.Resource.status.atProvider = {keyType = "RSA", versionlessId = "https://demo.vault.azure.net/keys/demo"}
    }
    dxr = kms.status(_build({}), ocds)
    assert dxr.status.protectionLevel == "software", "a key type without -HSM is software-protected"
    assert dxr.status.rotationEnabled == False, "no observed rotation policy means rotation is off"
    assert dxr.status?.id == Undefined, "an unobserved resource id must not be invented"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#browse/Microsoft.KeyVault%2Fvaults", "without a vault id the link stays the vault browser"
}

# 13) The vault can be observed before the key exists (the key waits on it).
test_status_vault_only = lambda {
    ocds = {
        vault.Resource.status.atProvider = {id = "/subscriptions/sub-1/vaults/demo", location = "eastus", vaultUri = "https://demo.vault.azure.net/"}
    }
    dxr = kms.status(_build({}), ocds)
    assert dxr.status.ready == False, "the vault alone does not make the key ready"
    assert dxr.status.vaultUri == "https://demo.vault.azure.net/", "the vault URI is reported as soon as the vault exists"
    assert dxr.status.region == "eastus", "the vault location is authoritative once observed"
    assert dxr.status?.keyUri == Undefined, "the key URI stays unknown until the key exists"
    assert dxr.status?.rotationEnabled == Undefined, "rotation state is unknown while the key is unobserved"
}

test_render_minimal()
test_algorithm_rsa_sizes()
test_algorithm_ec_curves()
test_key_size_and_curve_exclusive()
test_hsm_suffix_and_sku()
test_sku_from_protection_level()
test_key_opts_per_purpose()
test_rotation_policy_derived()
test_rotation_off_by_default()
test_deletion_window()
test_tags_on_both_resources()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
test_status_observed_software_no_rotation()
test_status_vault_only()
