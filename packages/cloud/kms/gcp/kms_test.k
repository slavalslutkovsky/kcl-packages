# Unit tests for the kms (gcp) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
import .kms

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "demo", spec = {region = "us-central1"} | extra}
}

# The CryptoKey forProvider block for the given spec — index 1, the key ring is
# always composed first.
_fp = lambda extra: any -> any {
    kms.render(_build(extra))[1].spec.forProvider
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# Per-pair accessors for the mapping table below. They exist because a config
# literal inside a "${...}" interpolation is a syntax error in KCL, so the
# assertion messages can only call brace-free helpers.
_pair_algo = lambda pair: [str] -> str {
    _fp({purpose = pair[0], algorithm = pair[1]}).versionTemplate.algorithm
}

_pair_purpose = lambda pair: [str] -> str {
    _fp({purpose = pair[0], algorithm = pair[1]}).purpose
}

# rotationPeriod for that pair when 30-day rotation is asked for; Undefined when
# render() dropped the request.
_pair_rotation = lambda pair: [str] -> any {
    _fp({purpose = pair[0], algorithm = pair[1], rotationDays = 30})?.rotationPeriod
}

# Every (purpose, algorithm) pair the XRD allows, with the Cloud KMS
# versionTemplate.algorithm it must produce.
_mappings = [
    ["encrypt-decrypt", "symmetric", "GOOGLE_SYMMETRIC_ENCRYPTION"]
    ["encrypt-decrypt", "rsa-2048", "RSA_DECRYPT_OAEP_2048_SHA256"]
    ["encrypt-decrypt", "rsa-3072", "RSA_DECRYPT_OAEP_3072_SHA256"]
    ["encrypt-decrypt", "rsa-4096", "RSA_DECRYPT_OAEP_4096_SHA256"]
    ["sign-verify", "rsa-2048", "RSA_SIGN_PKCS1_2048_SHA256"]
    ["sign-verify", "rsa-3072", "RSA_SIGN_PKCS1_3072_SHA256"]
    ["sign-verify", "rsa-4096", "RSA_SIGN_PKCS1_4096_SHA256"]
    ["sign-verify", "ec-p256", "EC_SIGN_P256_SHA256"]
    ["sign-verify", "ec-p384", "EC_SIGN_P384_SHA384"]
]

# 1) Minimal spec: a key ring then a symmetric software key inside it, with
#    every XRD default reapplied locally.
test_render_minimal = lambda {
    items = kms.render(_build({}))
    assert len(items) == 2, "a Cloud KMS key needs exactly its ring and itself"
    assert _kinds(items) == ["KeyRing", "CryptoKey"], "the ring must be composed before the key it contains"
    assert items[0].apiVersion == "kms.gcp.m.upbound.io/v1beta1", "wrong KeyRing apiVersion"
    assert items[1].apiVersion == "kms.gcp.m.upbound.io/v1beta1", "wrong CryptoKey apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "keyring", "the ring's resource name must be stable"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "status reads the key back under the name `managed`"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the ring name is part of the key URI and must be the XR name"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "demo", "the key name must be the XR name"
    assert items[0].spec.forProvider.location == "us-central1", "region must become the ring location"

    _f = items[1].spec.forProvider
    assert _f.keyRingSelector.matchControllerRef == True, "the key must bind to the composed ring, not a foreign one"
    assert _f.purpose == "ENCRYPT_DECRYPT", "purpose must default to encrypt-decrypt"
    assert _f.versionTemplate.algorithm == "GOOGLE_SYMMETRIC_ENCRYPTION", "algorithm must default to the native symmetric cipher"
    assert _f.versionTemplate.protectionLevel == "SOFTWARE", "protectionLevel must default to software"
    assert _f.destroyScheduledDuration == "2592000s", "deletionWindowDays must default to 30 days expressed in seconds"
    assert _f?.rotationPeriod == Undefined, "no rotationDays means no automatic rotation"
    assert _f?.labels == Undefined, "no tags means no labels block"
}

# 2) All nine purpose/algorithm pairs map to their native Cloud KMS algorithm,
#    which is padding- and hash-specific per purpose.
test_algorithm_mappings = lambda {
    _wrong = ["${_m[0]}+${_m[1]} -> ${_pair_algo(_m)}, want ${_m[2]}" for _m in _mappings if _pair_algo(_m) != _m[2]]
    assert _wrong == [], "wrong native algorithm for: ${_wrong}"
}

# 3) The key purpose follows the XR purpose, not the algorithm family.
test_purpose_mapping = lambda {
    _bad = ["${_m[0]}+${_m[1]} -> ${_pair_purpose(_m)}" for _m in _mappings if _pair_purpose(_m) != ("ASYMMETRIC_SIGN" if _m[0] == "sign-verify" else "ENCRYPT_DECRYPT")]
    assert _bad == [], "wrong native purpose for: ${_bad}"
}

# 4) protectionLevel=hsm moves key operations into the Cloud HSM pool.
test_protection_level_hsm = lambda {
    assert _fp({protectionLevel = "hsm"}).versionTemplate.protectionLevel == "HSM", "hsm must select the HSM protection level"
    assert _fp({protectionLevel = "software"}).versionTemplate.protectionLevel == "SOFTWARE", "software must select the SOFTWARE protection level"
}

# 5) Rotation: symmetric keys get a seconds-suffixed rotationPeriod; asymmetric
#    keys get none, because Cloud KMS rejects rotation on a published public key.
test_rotation_symmetric = lambda {
    assert _fp({rotationDays = 90}).rotationPeriod == "7776000s", "rotationDays must become a seconds-suffixed rotationPeriod"
    assert _fp({rotationDays = 1}).rotationPeriod == "86400s", "the shortest allowed rotation is one day of seconds"
}
test_rotation_asymmetric_dropped = lambda {
    _asym = [_m for _m in _mappings if _m[1] != "symmetric"]
    _rotating = ["${_m[0]}+${_m[1]}" for _m in _asym if _pair_rotation(_m) != Undefined]
    assert _rotating == [], "Cloud KMS cannot rotate asymmetric keys, but rotationPeriod was set on: ${_rotating}"
}
test_rotation_absent_by_default = lambda {
    assert _fp({algorithm = "symmetric"})?.rotationPeriod == Undefined, "rotation must stay off unless rotationDays is given"
}

# 6) The deletion window becomes the destroy-scheduled duration, in seconds.
test_deletion_window = lambda {
    assert _fp({deletionWindowDays = 7}).destroyScheduledDuration == "604800s", "the 7-day floor must be expressed in seconds"
    assert _fp({deletionWindowDays = 90}).destroyScheduledDuration == "7776000s", "the 90-day ceiling must be expressed in seconds"
}

# 7) tags become Cloud KMS labels on the key. The KeyRing API carries no labels
#    at all, so the user's tags can only land on the key itself.
test_tags_become_labels = lambda {
    items = kms.render(_build({
        tags = {team = "platform", env = "prod"}
    }))
    assert items[1].spec.forProvider.labels == {team = "platform", env = "prod"}, "tags must reach the key as labels"

    # The project is deliberately left to the ProviderConfig: pinning it here
    # would make the package unusable outside one GCP project.
    assert items[0].spec.forProvider?.project == Undefined, "the key ring must inherit its project from the ProviderConfig"
}

# 8) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves the provider default ["*"] in place.
test_deletion_policy_orphan = lambda {
    items = kms.render(_build({deletionPolicy = "Orphan"}))
    _missing = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = kms.render(_build({}))
    _wrong = [_i.kind for _i in items if _i.spec.managementPolicies != ["*"]]
    assert _wrong == [], "Delete must leave the provider default managementPolicies, changed on: ${_wrong}"
}

# 9) status before creation: not ready, nothing that only Cloud KMS can know.
test_status_pre_creation = lambda {
    dxr = kms.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EncryptionKey", "dxr kind must echo the composite"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.keyName == "demo", "the key is named after the XR"
    assert dxr.status.region == "us-central1", "region must come from the spec before observation"
    assert dxr.status.keyRing == "demo", "the ring is named after the XR before observation"
    assert dxr.status?.keyUri == Undefined, "the key URI needs the project, which only the provider knows"
    assert dxr.status?.keyId == Undefined, "no key id before creation"
    assert dxr.status?.id == Undefined, "no resource id before creation"
    assert dxr.status?.algorithm == Undefined, "the native algorithm is reported, never guessed"
    assert dxr.status?.protectionLevel == Undefined, "the native protection level is reported, never guessed"
    assert dxr.status?.rotationEnabled == Undefined, "rotation state is unknown until the key is observed"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/security/kms", "cloud-url must fall back to the KMS landing page"
}

# 10) status after creation: the observed id is the Cloud KMS resource name, and
#     both the project and the ring's short name are parsed out of the observed
#     full resource names rather than assumed.
test_status_observed = lambda {
    _id = "projects/acme-prod/locations/us-central1/keyRings/demo/cryptoKeys/demo"
    ocds = {
        managed.Resource.status.atProvider = {
            id = _id
            keyRing = "projects/acme-prod/locations/us-central1/keyRings/demo"
            purpose = "ENCRYPT_DECRYPT"
            rotationPeriod = "7776000s"
            destroyScheduledDuration = "2592000s"
            versionTemplate = {algorithm = "GOOGLE_SYMMETRIC_ENCRYPTION", protectionLevel = "HSM"}
        }
    }
    dxr = kms.status(_build({protectionLevel = "hsm", rotationDays = 90}), ocds)
    assert dxr.status.ready == True, "an observed resource name must mark the key ready"
    assert dxr.status.keyRing == "demo", "keyRing must be the trailing segment of the observed ring resource name"
    assert dxr.status.keyId == _id, "the Cloud KMS resource name is the native key id"
    assert dxr.status.keyUri == _id, "the Cloud KMS resource name is what other resources reference"
    assert dxr.status.id == _id, "the observed id must be surfaced"
    assert dxr.status.algorithm == "GOOGLE_SYMMETRIC_ENCRYPTION", "algorithm must be the observed native algorithm"
    assert dxr.status.protectionLevel == "hsm", "the native protection level must be reported in the XRD's lowercase form"
    assert dxr.status.rotationEnabled == True, "an observed rotationPeriod means the backend rotates the key"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/security/kms/key/manage/us-central1/demo/demo?project=acme-prod", "cloud-url must address the key with the project parsed from the observed id"
}

# 11) An observed key without a rotation period is reported as not rotating.
test_status_observed_no_rotation = lambda {
    ocds = {
        managed.Resource.status.atProvider = {
            id = "projects/acme-prod/locations/us-central1/keyRings/demo/cryptoKeys/demo"
            keyRing = "projects/acme-prod/locations/us-central1/keyRings/demo"
            versionTemplate = {algorithm = "EC_SIGN_P384_SHA384", protectionLevel = "SOFTWARE"}
        }
    }
    dxr = kms.status(_build({purpose = "sign-verify", algorithm = "ec-p384"}), ocds)
    assert dxr.status.rotationEnabled == False, "no observed rotationPeriod means no automatic rotation"
    assert dxr.status.algorithm == "EC_SIGN_P384_SHA384", "the observed signing algorithm must be surfaced"
    assert dxr.status.protectionLevel == "software", "SOFTWARE must be reported lowercase"
}

test_render_minimal()
test_algorithm_mappings()
test_purpose_mapping()
test_protection_level_hsm()
test_rotation_symmetric()
test_rotation_asymmetric_dropped()
test_rotation_absent_by_default()
test_deletion_window()
test_tags_become_labels()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
test_status_observed_no_rotation()
