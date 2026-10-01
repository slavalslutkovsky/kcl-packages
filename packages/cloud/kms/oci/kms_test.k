# Unit tests for the kms (oci) function-kcl module.
# Contract under test:
#   render(oxr, ocds) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr          (single desired-composite carrying .status)
# kcl test cannot catch a failed assert, so the compartment and purpose asserts
# are exercised through the combinations they must let through.
import .kms

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_compartment = "ocid1.compartment.oc1..aaaaexample"
_endpoint = "https://abc123-management.kms.il-jerusalem-1.oraclecloud.com"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "demo", spec = {region = "il-jerusalem-1", compartmentId = _compartment} | extra}
}

# Observed resources once the vault exists and reports its endpoint.
_vault_ready = {
    vault.Resource.status.atProvider = {
        id = "ocid1.vault.oc1.il-jerusalem-1.vaultid"
        managementEndpoint = _endpoint
        cryptoEndpoint = "https://abc123-crypto.kms.il-jerusalem-1.oraclecloud.com"
    }
}

# Every MR for `extra` once the vault is observed: [Vault, Key].
_all = lambda extra: any -> [any] {
    kms.render(_build(extra), _vault_ready)
}

# The Key forProvider block — index 1, the vault is always composed first.
_fp = lambda extra: any -> any {
    _all(extra)[1].spec.forProvider
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# A rendered keyShape as "<algorithm>/<length>/<curveId>". The rendered value
# is a typed schema instance, which never compares equal to a plain dict.
_shape_str = lambda s: any -> str {
    "${s.algorithm}/${s.length}/${s?.curveId or ''}"
}

# keyShape for a (purpose, algorithm) pair. Brace-free so it can be called
# inside a "${...}" interpolation.
_pair_shape = lambda pair: [str] -> str {
    _shape_str(_fp({purpose = pair[0], algorithm = pair[1]}).keyShape[0])
}

# Every (purpose, algorithm) pair the XRD allows, with the OCI keyShape it must
# produce (length in BYTES).
_mappings = [
    ["encrypt-decrypt", "symmetric", "AES/32/"]
    ["encrypt-decrypt", "rsa-2048", "RSA/256/"]
    ["encrypt-decrypt", "rsa-3072", "RSA/384/"]
    ["encrypt-decrypt", "rsa-4096", "RSA/512/"]
    ["sign-verify", "rsa-2048", "RSA/256/"]
    ["sign-verify", "rsa-3072", "RSA/384/"]
    ["sign-verify", "rsa-4096", "RSA/512/"]
    ["sign-verify", "ec-p256", "ECDSA/32/NIST_P256"]
    ["sign-verify", "ec-p384", "ECDSA/48/NIST_P384"]
]

# 1) Before the vault is observed only the vault is rendered: the Key cannot be
#    created without the vault's management endpoint.
test_render_before_vault = lambda {
    items = kms.render(_build({}), {})
    assert _kinds(items) == ["Vault"], "the key must wait for the vault's management endpoint"
    _v = items[0]
    assert _v.apiVersion == "kms.oci.m.upbound.io/v1alpha1", "wrong Vault apiVersion"
    assert _v.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "vault", "status reads the vault back under the name `vault`"
    assert "crossplane.io/external-name" not in _v.metadata.annotations, "OCI assigns the vault OCID; it must not be pinned"
    assert _v.spec.forProvider.compartmentId == _compartment, "compartment must come from the spec"
    assert _v.spec.forProvider.displayName == "demo", "the vault is named after the XR"
    assert _v.spec.forProvider.vaultType == "DEFAULT", "never the fixed-cost VIRTUAL_PRIVATE vault"
    assert _v.spec.forProvider?.freeformTags == Undefined, "no tags means no freeformTags"
}

# 2) Once the vault is observed, the key is rendered against its endpoint with
#    every XRD default reapplied.
test_render_minimal = lambda {
    items = _all({})
    assert _kinds(items) == ["Vault", "Key"], "the vault must be composed before the key it holds"
    _k = items[1]
    assert _k.apiVersion == "kms.oci.m.upbound.io/v1alpha1", "wrong Key apiVersion"
    assert _k.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "status reads the key back under the name `managed`"
    assert "crossplane.io/external-name" not in _k.metadata.annotations, "OCI assigns the key OCID; it must not be pinned"
    _f = _k.spec.forProvider
    assert _f.managementEndpoint == _endpoint, "the key must be created through the composed vault's endpoint"
    assert _f.compartmentId == _compartment, "compartment must come from the spec"
    assert _f.displayName == "demo", "the key is named after the XR"
    assert len(_f.keyShape) == 1 and _shape_str(_f.keyShape[0]) == "AES/32/", "algorithm must default to AES-256"
    assert _f.protectionMode == "SOFTWARE", "protectionLevel must default to software"
    assert _f?.isAutoRotationEnabled == Undefined, "rotation is not available in a DEFAULT vault"
    assert _f?.timeOfDeletion == Undefined, "the deletion window is left to OCI's default"
}

# 3) An existing Key keeps its endpoint even if the vault observation lacks it,
#    so it is never dropped from the desired state (which would delete it).
test_render_keeps_existing_key = lambda {
    ocds = {
        vault.Resource.status.atProvider = {id = "ocid1.vault.oc1..x"}
        managed.Resource.spec.forProvider.managementEndpoint = _endpoint
    }
    items = kms.render(_build({}), ocds)
    assert _kinds(items) == ["Vault", "Key"], "an existing key must stay in the desired state"
    assert items[1].spec.forProvider.managementEndpoint == _endpoint, "the key's own endpoint is the fallback"
}

# 4) All nine purpose/algorithm pairs map to their OCI keyShape; this also
#    proves both purpose asserts let every valid combination through.
test_key_shapes = lambda {
    _wrong = ["${_m[0]}+${_m[1]} -> ${_pair_shape(_m)}" for _m in _mappings if _pair_shape(_m) != _m[2]]
    assert _wrong == [], "wrong keyShape for: ${_wrong}"
}

# 5) protectionLevel selects the per-key protectionMode.
test_protection_mode = lambda {
    assert _fp({protectionLevel = "hsm"}).protectionMode == "HSM", "hsm must select the HSM protection mode"
    assert _fp({protectionLevel = "software"}).protectionMode == "SOFTWARE", "software must select the SOFTWARE protection mode"
    assert _all({protectionLevel = "hsm"})[0].spec.forProvider.vaultType == "DEFAULT", "HSM keys must not upgrade the vault type"
}

# 6) Every MR binds to the per-region ClusterProviderConfig.
test_provider_config_ref = lambda {
    items = kms.render(_build({region = "eu-frankfurt-1"}), _vault_ready)
    _wrong = [_i.kind for _i in items if _i.spec.providerConfigRef.kind != "ClusterProviderConfig" or _i.spec.providerConfigRef.name != "oci-eu-frankfurt-1"]
    assert _wrong == [], "providerConfigRef must be oci-<region>, wrong on: ${_wrong}"
}

# 7) rotationDays and deletionWindowDays are documented no-ops on OCI.
test_ignored_fields = lambda {
    _f = _fp({rotationDays = 90, deletionWindowDays = 7})
    assert _f?.isAutoRotationEnabled == Undefined, "auto rotation needs a private vault; rotationDays is ignored"
    assert _f?.autoKeyRotationDetails == Undefined, "auto rotation needs a private vault; rotationDays is ignored"
    assert _f?.timeOfDeletion == Undefined, "deletionWindowDays is ignored"
}

# 8) tags become freeformTags on both the vault and the key.
test_tags = lambda {
    items = _all({
        tags = {team = "platform", env = "prod"}
    })
    _missing = [_i.kind for _i in items if _i.spec.forProvider.freeformTags != {team = "platform", env = "prod"}]
    assert _missing == [], "tags must reach every MR as freeformTags, missing on: ${_missing}"
}

# 9) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves the provider default ["*"] in place.
test_deletion_policy_orphan = lambda {
    items = _all({deletionPolicy = "Orphan"})
    _missing = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = _all({})
    _wrong = [_i.kind for _i in items if _i.spec.managementPolicies != ["*"]]
    assert _wrong == [], "Delete must leave the provider default managementPolicies, changed on: ${_wrong}"
}

# 10) status before creation: not ready, nothing only OCI can know.
test_status_pre_creation = lambda {
    dxr = kms.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EncryptionKey", "dxr kind must echo the composite"
    assert dxr.status.provider == "oci", "provider must be oci"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.keyName == "demo", "the key is named after the XR"
    assert dxr.status.region == "il-jerusalem-1", "region must come from the spec"
    assert dxr.status?.keyId == Undefined, "no key OCID before creation"
    assert dxr.status?.keyUri == Undefined, "no key OCID before creation"
    assert dxr.status?.vaultId == Undefined, "no vault OCID before creation"
    assert dxr.status?.protectionLevel == Undefined, "the protection mode is reported, never guessed"
    assert dxr.status?.rotationEnabled == Undefined, "rotation state is unknown until the key is observed"
    assert dxr.status["cloud-url"] == "https://cloud.oracle.com/security/kms", "cloud-url must fall back to the KMS landing page"
}

# 11) status after creation: the key OCID is id, keyId and keyUri; the console
#     link addresses the key inside its vault.
test_status_observed = lambda {
    _id = "ocid1.key.oc1.il-jerusalem-1.keyid"
    _vid = "ocid1.vault.oc1.il-jerusalem-1.vaultid"
    ocds = _vault_ready | {
        managed.Resource.status.atProvider = {
            id = _id
            vaultId = _vid
            protectionMode = "HSM"
            isAutoRotationEnabled = False
            keyShape = [{algorithm = "AES", length = 32}]
        }
    }
    dxr = kms.status(_build({protectionLevel = "hsm"}), ocds)
    assert dxr.status.ready == True, "an observed key OCID must mark the key ready"
    assert dxr.status.keyId == _id, "the key OCID is the native key id"
    assert dxr.status.keyUri == _id, "the key OCID is what other OCI resources reference"
    assert dxr.status.id == _id, "the observed id must be surfaced"
    assert dxr.status.vaultId == _vid, "the vault OCID must be surfaced"
    assert dxr.status.managementEndpoint == _endpoint, "the management endpoint must be surfaced"
    assert dxr.status.cryptoEndpoint == "https://abc123-crypto.kms.il-jerusalem-1.oraclecloud.com", "the crypto endpoint must be surfaced"
    assert dxr.status.algorithm == "AES", "algorithm must be the observed keyShape algorithm"
    assert dxr.status.protectionLevel == "hsm", "the protection mode must be reported lowercase"
    assert dxr.status.rotationEnabled == False, "an observed False must be reported, not dropped"
    assert dxr.status["cloud-url"] == "https://cloud.oracle.com/security/kms/vaults/${_vid}/keys/${_id}?region=il-jerusalem-1", "cloud-url must address the key inside its vault"
}

test_render_before_vault()
test_render_minimal()
test_render_keeps_existing_key()
test_key_shapes()
test_protection_mode()
test_provider_config_ref()
test_ignored_fields()
test_tags()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
