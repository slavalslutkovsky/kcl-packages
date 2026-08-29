# Unit tests for the kms (aws) function-kcl module.
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
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "demo", spec = {region = "us-east-1"} | extra}
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# forProvider of the KMS Key (always the first MR).
_key_fp = lambda extra: any -> any {
    kms.render(_build(extra))[0].spec.forProvider
}

# A realistic atProvider for an existing symmetric key.
_observed = {
    arn = "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    id = "1234abcd-12ab-34cd-56ef-1234567890ab"
    keyId = "1234abcd-12ab-34cd-56ef-1234567890ab"
    region = "us-east-1"
    customerMasterKeySpec = "SYMMETRIC_DEFAULT"
    keyUsage = "ENCRYPT_DECRYPT"
    deletionWindowInDays = 30
    enableKeyRotation = True
    isEnabled = True
    multiRegion = False
}

# 1) Minimal spec: exactly two MRs — the Key then its Alias — with every XRD
#    default re-applied locally.
test_render_minimal = lambda {
    items = kms.render(_build({}))
    assert len(items) == 2, "an encryption key is exactly one KMS Key plus one Alias"
    assert _kinds(items) == ["Key", "Alias"], "the Key must be composed before the Alias that targets it"
    assert items[0].apiVersion == "kms.aws.m.upbound.io/v1beta1", "wrong Key apiVersion"
    assert items[1].apiVersion == "kms.aws.m.upbound.io/v1beta1", "wrong Alias apiVersion"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the Key is the 'managed' composed resource"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "alias", "the Alias is the 'alias' composed resource"
    _fp = items[0].spec.forProvider
    assert _fp.region == "us-east-1", "region must reach the key"
    assert _fp.description == "EncryptionKey demo", "the key description must identify the owning XR"
    assert _fp.keyUsage == "ENCRYPT_DECRYPT", "purpose must default to encrypt-decrypt"
    assert _fp.customerMasterKeySpec == "SYMMETRIC_DEFAULT", "algorithm must default to symmetric"
    assert _fp.deletionWindowInDays == 30, "deletionWindowDays must default to 30"
    assert _fp.multiRegion == False, "multiRegion must default to false"
    assert _fp?.enableKeyRotation == Undefined, "no rotationDays means rotation is never configured"
    assert _fp?.tags == Undefined, "no tags means no tags block"
}

# 2) The external name lands on the Alias only: AWS assigns the key id, so the
#    alias is the sole deterministic, user-visible handle for the key.
test_external_name_on_alias_only = lambda {
    items = kms.render(_build({}))
    assert items[0].metadata.annotations?["crossplane.io/external-name"] == Undefined, "the KMS key id is assigned by AWS and must not be pinned"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "alias/demo", "the alias must be pinned to alias/<xr name>"
}

# 3) The Alias binds to the Key composed alongside it, not to any key in the account.
test_alias_binds_to_composed_key = lambda {
    _fp = kms.render(_build({}))[1].spec.forProvider
    assert _fp.region == "us-east-1", "region must reach the alias"
    assert _fp.targetKeyIdSelector.matchControllerRef == True, "the alias must resolve to the key owned by this XR"
}

# 4) Every portable algorithm maps to its AWS CustomerMasterKeySpec. EC keys are
#    sign-only on AWS, so they are exercised with purpose=sign-verify.
test_algorithm_mapping = lambda {
    assert _key_fp({algorithm = "symmetric"}).customerMasterKeySpec == "SYMMETRIC_DEFAULT", "symmetric must map to SYMMETRIC_DEFAULT"
    assert _key_fp({algorithm = "rsa-2048"}).customerMasterKeySpec == "RSA_2048", "rsa-2048 must map to RSA_2048"
    assert _key_fp({algorithm = "rsa-3072"}).customerMasterKeySpec == "RSA_3072", "rsa-3072 must map to RSA_3072"
    assert _key_fp({algorithm = "rsa-4096"}).customerMasterKeySpec == "RSA_4096", "rsa-4096 must map to RSA_4096"
    assert _key_fp({algorithm = "ec-p256", purpose = "sign-verify"}).customerMasterKeySpec == "ECC_NIST_P256", "ec-p256 must map to ECC_NIST_P256"
    assert _key_fp({algorithm = "ec-p384", purpose = "sign-verify"}).customerMasterKeySpec == "ECC_NIST_P384", "ec-p384 must map to ECC_NIST_P384"
}

# 5) Both purposes map to an AWS KeyUsage; sign-verify needs an asymmetric key.
test_purpose_mapping = lambda {
    assert _key_fp({purpose = "encrypt-decrypt"}).keyUsage == "ENCRYPT_DECRYPT", "encrypt-decrypt must map to ENCRYPT_DECRYPT"
    assert _key_fp({purpose = "sign-verify", algorithm = "rsa-4096"}).keyUsage == "SIGN_VERIFY", "sign-verify must map to SIGN_VERIFY"
}

# 6) AWS caps the pending-deletion window at 30 days while the XRD allows 90, so
#    a longer window degrades to the longest AWS supports; shorter passes through.
test_deletion_window_clamped = lambda {
    assert _key_fp({deletionWindowDays = 90}).deletionWindowInDays == 30, "AWS accepts at most a 30-day deletion window"
    assert _key_fp({deletionWindowDays = 31}).deletionWindowInDays == 30, "anything above the AWS maximum must clamp to 30"
    assert _key_fp({deletionWindowDays = 7}).deletionWindowInDays == 7, "a window AWS supports must pass through unchanged"
}

# 7) Rotation: enabled only for symmetric keys, and never faster than the 90-day
#    minimum AWS allows for a custom rotation period.
test_rotation_floor = lambda {
    _fp = _key_fp({rotationDays = 30})
    assert _fp.enableKeyRotation == True, "rotationDays must turn automatic rotation on"
    assert _fp.rotationPeriodInDays == 90, "AWS rejects a rotation period under 90 days, so it must be raised to the floor"
}
test_rotation_passthrough = lambda {
    _fp = _key_fp({rotationDays = 365})
    assert _fp.enableKeyRotation == True, "rotationDays must turn automatic rotation on"
    assert _fp.rotationPeriodInDays == 365, "a rotation period AWS supports must pass through unchanged"
}
test_rotation_absent_by_default = lambda {
    _fp = _key_fp({})
    assert _fp?.enableKeyRotation == Undefined, "no rotationDays means enableKeyRotation is never sent"
    assert _fp?.rotationPeriodInDays == Undefined, "no rotationDays means no rotation period"
}
test_rotation_skipped_for_asymmetric = lambda {
    _fp = _key_fp({algorithm = "rsa-2048", rotationDays = 180})
    assert _fp?.enableKeyRotation == Undefined, "AWS rotates symmetric keys only, so the field must be omitted (not False) on asymmetric keys"
    assert _fp?.rotationPeriodInDays == Undefined, "an unrotatable key must not carry a rotation period"
}
test_rotation_skipped_for_ec = lambda {
    _fp = _key_fp({algorithm = "ec-p384", purpose = "sign-verify", rotationDays = 90})
    assert _fp?.enableKeyRotation == Undefined, "AWS rotates symmetric keys only, so the field must be omitted (not False) on EC keys"
}

# 8) Pass-through fields.
test_multi_region = lambda {
    assert _key_fp({multiRegion = True}).multiRegion == True, "multiRegion must reach the key"
    assert _key_fp({multiRegion = False}).multiRegion == False, "an explicit false must survive default application"
}
test_tags = lambda {
    assert _key_fp({
        tags = {team = "platform", env = "prod"}
    }).tags == {team = "platform", env = "prod"}, "tags must reach the key"
}

# 9) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves the provider default ["*"] in place.
test_deletion_policy_orphan = lambda {
    items = kms.render(_build({deletionPolicy = "Orphan", rotationDays = 120, tags = {a = "b"}}))
    _missing = [_i.kind for _i in items if not (_i.spec.managementPolicies == _orphan)]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = kms.render(_build({}))
    _stamped = [_i.kind for _i in items if not (_i.spec.managementPolicies == ["*"])]
    assert _stamped == [], "Delete must leave the provider default policies, overridden on: ${_stamped}"
}

# 10) status before creation: not ready, and nothing that only AWS can answer.
test_status_pre_creation = lambda {
    dxr = kms.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EncryptionKey", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.keyName == "demo", "the key name is the XR name"
    assert dxr.status.region == "us-east-1", "region falls back to the requested region"
    assert dxr.status.alias == "alias/demo", "the alias is derived from the XR name and known before creation"
    assert dxr.status.protectionLevel == "hsm", "AWS KMS keys are always HSM-backed regardless of spec.protectionLevel"
    assert dxr.status?.keyId == Undefined, "the key id is assigned by AWS and must not be invented"
    assert dxr.status?.arn == Undefined, "the ARN is unknown until observed"
    assert dxr.status?.keyUri == Undefined, "the key URI is the ARN, so it is unknown until observed"
    assert dxr.status?.algorithm == Undefined, "the native key spec is only reported once AWS confirms it"
    assert dxr.status?.rotationEnabled == Undefined, "rotation state is only reported once AWS confirms it"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/kms/home?region=us-east-1#/kms/keys", "without a key id the console URL must point at the key list"
}

# 11) spec.protectionLevel is ignored: AWS has no software-only KMS key.
test_status_protection_level_ignores_spec = lambda {
    dxr = kms.status(_build({protectionLevel = "software"}), {})
    assert dxr.status.protectionLevel == "hsm", "AWS cannot honour protectionLevel=software, so hsm must be reported"
}

# 12) status after creation: populated from the observed atProvider.
test_status_observed = lambda {
    dxr = kms.status(_build({}), {managed.Resource.status.atProvider = _observed})
    _id = "1234abcd-12ab-34cd-56ef-1234567890ab"
    assert dxr.status.ready == True, "an observed ARN must mark the key ready"
    assert dxr.status.keyId == _id, "the observed key id must be surfaced"
    assert dxr.status.id == _id, "the observed resource id must be surfaced"
    assert dxr.status.arn == _observed.arn, "the observed ARN must be surfaced"
    assert dxr.status.keyUri == _observed.arn, "the ARN is the canonical reference other AWS resources use"
    assert dxr.status.algorithm == "SYMMETRIC_DEFAULT", "the native key spec must come from the provider"
    assert dxr.status.rotationEnabled == True, "observed rotation state must be surfaced"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/kms/home?region=us-east-1#/kms/keys/${_id}", "with a key id the console URL must address the key"
}

# 13) An observed enableKeyRotation=False is an answer, not an absence.
test_status_rotation_disabled_is_reported = lambda {
    _off = _observed | {enableKeyRotation = False}
    dxr = kms.status(_build({}), {managed.Resource.status.atProvider = _off})
    assert dxr.status.rotationEnabled == False, "rotation reported off must be surfaced as false, not dropped"
}

# 14) The observed region wins: a multi-region replica can report elsewhere.
test_status_region_from_provider = lambda {
    _elsewhere = _observed | {region = "eu-west-1"}
    dxr = kms.status(_build({}), {managed.Resource.status.atProvider = _elsewhere})
    assert dxr.status.region == "eu-west-1", "the observed region must win over the requested one"
    assert dxr.status["cloud-url"].startswith("https://eu-west-1."), "the console URL must follow the observed region"
}

test_render_minimal()
test_external_name_on_alias_only()
test_alias_binds_to_composed_key()
test_algorithm_mapping()
test_purpose_mapping()
test_deletion_window_clamped()
test_rotation_floor()
test_rotation_passthrough()
test_rotation_absent_by_default()
test_rotation_skipped_for_asymmetric()
test_rotation_skipped_for_ec()
test_multi_region()
test_tags()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_protection_level_ignores_spec()
test_status_observed()
test_status_rotation_disabled_is_reported()
test_status_region_from_provider()
