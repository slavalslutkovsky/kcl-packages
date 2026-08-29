# Unit tests for the kms (openbao) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# Escaped schema keys ($type) serialize to plain keys, so observed atProvider
# fixtures carry the de-escaped string key (x["type"]).
import .kms

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
# region is required by the XRD and ignored by this backend.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "demo", spec = {region = "in-cluster"} | extra}
}

_mount_of = lambda extra: any -> any {
    kms.render(_build(extra))[0]
}
_key_of = lambda extra: any -> any {
    kms.render(_build(extra))[1]
}
_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# 1) Minimal spec: the transit mount plus one symmetric, non-exportable,
#    deletable key — every XRD default re-applied by render().
test_render_minimal = lambda {
    items = kms.render(_build({}))
    assert len(items) == 2, "minimal spec must render exactly the mount and the key"
    assert _kinds(items) == ["Mount", "SecretBackendKey"], "the mount must be composed before the key that lives in it"
    assert items[0].apiVersion == "vault.vault.m.upbound.io/v1alpha1", "wrong Mount apiVersion"
    assert items[1].apiVersion == "transit.vault.m.upbound.io/v1alpha1", "wrong SecretBackendKey apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "transit-mount", "the mount resource name is transit-mount"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the key is the primary 'managed' resource status() reads"

    _mp = items[0].spec.forProvider
    assert _mp.path == "transit", "mountPath must default to transit"
    assert _mp.$type == "transit", "the mount must enable the transit secrets engine"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "transit", "a mount is identified by its path, so external-name is pinned to it"

    _fp = items[1].spec.forProvider
    assert _fp.name == "demo", "the transit key is named after the XR"
    assert _fp.backend == "transit", "the key must live in the composed mount"
    assert _fp.$type == "aes256-gcm96", "symmetric encrypt-decrypt is transit's AES-256-GCM key"
    assert _fp.exportable == False, "key material must not be exportable by default"
    assert _fp.allowPlaintextBackup == False, "plaintext backup must be off by default"
    assert _fp.deletionAllowed == True, "deletionPolicy defaults to Delete, which needs the key to allow deletion"
    assert _fp.minDecryptionVersion == 1, "every key version from the first must stay usable for decryption"
    assert _fp?.autoRotatePeriod == Undefined, "no rotationDays means no automatic rotation"
    assert items[1].metadata.annotations?["crossplane.io/external-name"] == Undefined, "the key's external name is derived by the provider from backend+name, never pinned"
    assert items[1].spec.managementPolicies == ["*"], "Delete must leave the provider's default management policies in place"
}

# 2) mountPath reaches the mount, its external name, and the key's backend.
test_custom_mount_path = lambda {
    items = kms.render(_build({mountPath = "crypto"}))
    assert items[0].spec.forProvider.path == "crypto", "mountPath must choose where the engine is mounted"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "crypto", "external-name must follow the mount path"
    assert items[1].spec.forProvider.backend == "crypto", "the key must be created in the requested mount"
    assert kms.status(_build({mountPath = "crypto"}), {}).status.keyUri == "crypto/keys/demo", "keyUri must address the key inside the requested mount"
}

# 3) The mount is shared by every EncryptionKey at that path, so it is never
#    deletable — not even under the default deletionPolicy=Delete.
test_mount_never_deleted = lambda {
    _policies = [_mount_of(_e).spec.managementPolicies for _e in [{}, {deletionPolicy = "Delete"}, {deletionPolicy = "Orphan"}]]
    _wrong = [_p for _p in _policies if _p != _orphan]
    assert _wrong == [], "the shared mount must never carry Delete, got: ${_wrong}"
}

# 4) Every algorithm maps to its transit key type. Transit RSA keys both
#    decrypt and sign, so rsa-* is valid for either purpose.
_type_of = lambda purpose: str, algorithm: str -> str {
    _key_of({purpose = purpose, algorithm = algorithm}).spec.forProvider.$type
}
test_type_mapping_encrypt_decrypt = lambda {
    _want = {"symmetric" = "aes256-gcm96", "rsa-2048" = "rsa-2048", "rsa-3072" = "rsa-3072", "rsa-4096" = "rsa-4096"}
    _got = {_a: _type_of("encrypt-decrypt", _a) for _a in _want}
    assert _got == _want, "encrypt-decrypt algorithms must map to transit types, got: ${_got}"
}
test_type_mapping_sign_verify = lambda {
    _want = {"rsa-2048" = "rsa-2048", "rsa-3072" = "rsa-3072", "rsa-4096" = "rsa-4096", "ec-p256" = "ecdsa-p256", "ec-p384" = "ecdsa-p384"}
    _got = {_a: _type_of("sign-verify", _a) for _a in _want}
    assert _got == _want, "sign-verify algorithms must map to transit types, got: ${_got}"
}

# 5) deletionAllowed is what actually lets OpenBao destroy the key, so it
#    tracks deletionPolicy in both directions; Orphan also stamps the key.
test_deletion_policy_delete = lambda {
    _k = _key_of({deletionPolicy = "Delete"})
    assert _k.spec.forProvider.deletionAllowed == True, "Delete requires the key to permit its own deletion"
    assert _k.spec.managementPolicies == ["*"], "Delete must leave the provider's default management policies in place"
}
test_deletion_policy_orphan = lambda {
    _k = _key_of({deletionPolicy = "Orphan"})
    assert _k.spec.forProvider.deletionAllowed == False, "an orphaned key must refuse deletion so the material survives"
    assert _k.spec.managementPolicies == _orphan, "Orphan must stamp the orphan management policies on the key"
}

# 6) exportable drives export AND plaintext backup: a backup of a
#    non-exportable key would still leak the key material.
test_exportable_flags = lambda {
    _fp = _key_of({exportable = True}).spec.forProvider
    assert _fp.exportable == True, "exportable must allow key export"
    assert _fp.allowPlaintextBackup == True, "exportable must also allow plaintext backup"
    _off = _key_of({exportable = False}).spec.forProvider
    assert _off.exportable == False and _off.allowPlaintextBackup == False, "exportable=false must lock both export paths"
}

# 7) rotationDays becomes autoRotatePeriod in SECONDS, and unlike the cloud
#    backends it applies to asymmetric keys too.
test_rotation_period_seconds = lambda {
    assert _key_of({rotationDays = 30}).spec.forProvider.autoRotatePeriod == 2592000, "30 days must be 30*86400 seconds"
    assert _key_of({rotationDays = 1}).spec.forProvider.autoRotatePeriod == 86400, "one day must be 86400 seconds"
}
test_rotation_asymmetric = lambda {
    _fp = _key_of({purpose = "sign-verify", algorithm = "rsa-4096", rotationDays = 90}).spec.forProvider
    assert _fp.$type == "rsa-4096", "the signing key must stay RSA-4096"
    assert _fp.autoRotatePeriod == 7776000, "transit rotates asymmetric keys too, so the period must be set"
}

# 8) Fields the XRD documents as ignored here must not change what is composed;
#    they only exist for the cloud backends.
test_ignored_cloud_fields = lambda {
    _extra = {protectionLevel = "hsm", deletionWindowDays = 7, multiRegion = True, tags = {team = "platform"}, resourceGroup = "rg", tenantId = "tid"}
    assert kms.render(_build(_extra)) == kms.render(_build({})), "cloud-only fields must not alter the composed transit resources"
    assert kms.status(_build(_extra), {}).status.protectionLevel == "software", "there is no HSM path without an enterprise seal"
}

# 9) status before creation: not ready, deterministic paths only, nothing the
#    provider alone could know.
test_status_pre_creation = lambda {
    dxr = kms.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EncryptionKey", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must be named after the XR"
    assert dxr.status.provider == "openbao", "provider must be openbao"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.keyName == "demo" and dxr.status.keyId == "demo", "in transit the key name is its identifier"
    assert dxr.status.mountPath == "transit", "mountPath must be reported"
    assert dxr.status.keyUri == "transit/keys/demo", "keyUri is deterministic from mount path and name"
    assert dxr.status["cloud-url"] == "bao://transit/keys/demo", "cloud-url must address the key in the engine"
    assert dxr.status.rotationEnabled == False, "rotation is off until the provider reports a period"
    assert dxr.status?.algorithm == Undefined, "the native key type is unknown until observed"
    assert dxr.status?.id == Undefined, "the provider id is unknown until observed"
    assert dxr.status?.region == Undefined, "region is meaningless for an in-cluster engine and must never be reported"
}

# 10) status after creation: populated from a realistic atProvider.
test_status_observed = lambda {
    ocds = {
        managed.Resource.status.atProvider = {
            backend = "transit"
            name = "demo"
            id = "transit/keys/demo"
            "type" = "rsa-4096"
            latestVersion = 2
            minAvailableVersion = 0
            minDecryptionVersion = 1
            autoRotatePeriod = 7776000
            supportsSigning = True
            supportsEncryption = False
        }
    }
    dxr = kms.status(_build({purpose = "sign-verify", algorithm = "rsa-4096", rotationDays = 90}), ocds)
    assert dxr.status.ready == True, "an observed key version means the key exists"
    assert dxr.status.algorithm == "rsa-4096", "algorithm must be the type the engine reports"
    assert dxr.status.rotationEnabled == True, "a non-zero autoRotatePeriod means rotation is on"
    assert dxr.status.id == "transit/keys/demo", "observed id must be surfaced"
    assert dxr.status.keyUri == "transit/keys/demo", "keyUri must stay the transit API path"
    assert dxr.status.protectionLevel == "software", "transit keys live in the software barrier"
}
test_status_observed_no_rotation = lambda {
    ocds = {
        managed.Resource.status.atProvider = {id = "transit/keys/demo", "type" = "aes256-gcm96", latestVersion = 1, autoRotatePeriod = 0}
    }
    dxr = kms.status(_build({}), ocds)
    assert dxr.status.ready == True, "version 1 is a live key"
    assert dxr.status.rotationEnabled == False, "autoRotatePeriod=0 is transit's way of disabling rotation"
    assert dxr.status.algorithm == "aes256-gcm96", "the observed symmetric type must be surfaced"
}

test_render_minimal()
test_custom_mount_path()
test_mount_never_deleted()
test_type_mapping_encrypt_decrypt()
test_type_mapping_sign_verify()
test_deletion_policy_delete()
test_deletion_policy_orphan()
test_exportable_flags()
test_rotation_period_seconds()
test_rotation_asymmetric()
test_ignored_cloud_fields()
test_status_pre_creation()
test_status_observed()
test_status_observed_no_rotation()
