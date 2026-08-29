# kms (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-kms schema package. The portable EncryptionKey maps onto
# one KMS Key plus one Alias bound to it by controller reference. AWS splits the
# two on purpose: the Key is addressed by an opaque, account-assigned key id and
# the Alias is the only human-readable, stable handle for it — so the XR name
# lands on the Alias, never on the Key.
# Key policies are deliberately NOT composed: omitting `policy` leaves the AWS
# default root-account policy in place, whereas an XR-managed policy would be
# the single thing standing between the account and a locked-out key.
import aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_key as backend
import aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_alias as alias

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Portable algorithm -> AWS CustomerMasterKeySpec. "symmetric" is AWS's own
# 256-bit AES default rather than a named cipher, hence SYMMETRIC_DEFAULT; the
# EC specs are spelled by NIST curve name, not by key size.
_cmk_spec = {
    "symmetric" = "SYMMETRIC_DEFAULT"
    "rsa-2048" = "RSA_2048"
    "rsa-3072" = "RSA_3072"
    "rsa-4096" = "RSA_4096"
    "ec-p256" = "ECC_NIST_P256"
    "ec-p384" = "ECC_NIST_P384"
}

# Portable purpose -> AWS KeyUsage.
_key_usage = {
    "encrypt-decrypt" = "ENCRYPT_DECRYPT"
    "sign-verify" = "SIGN_VERIFY"
}

# AWS caps a pending-deletion window at 30 days; the XRD allows up to 90 because
# Key Vault's soft-delete retention goes that far. Clamping (rather than
# rejecting) keeps one portable spec usable on every backend — a longer grace
# period than the backend supports degrades to the longest it does support.
_aws_max_deletion_window = 30

# AWS accepts a custom rotation period only in 90..2560 days, so anything
# shorter is raised to the floor rather than rejected: the intent ("rotate
# automatically") is honoured at the fastest cadence AWS allows.
_aws_min_rotation_days = 90

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    # XRD defaults are applied server-side, but render() is also called with
    # hand-written specs (tests, main.k), so every default is re-applied here.
    _purpose = _spec?.purpose or "encrypt-decrypt"
    _algorithm = _spec?.algorithm or "symmetric"
    _window = _spec?.deletionWindowDays or 30

    # Booleans cannot use `or`: False is falsy and would silently pick the
    # default, so absence is tested explicitly.
    _multi_region = _spec?.multiRegion
    if _multi_region == Undefined:
        _multi_region = False

    # `or Undefined` folds the two shapes of an absent optional key (missing ->
    # Undefined, explicit null -> None) into one sentinel meaning "no automatic
    # rotation"; a rotation period of 0 days is meaningless, so 0 folding in too
    # is harmless.
    _rotation_days = _spec?.rotationDays or Undefined

    assert not (_purpose == "sign-verify" and _algorithm == "symmetric"), "kms (aws): purpose=sign-verify requires an asymmetric algorithm, got symmetric"
    assert not (_purpose == "encrypt-decrypt" and _algorithm in ["ec-p256", "ec-p384"]), "kms (aws): purpose=encrypt-decrypt cannot use an EC algorithm (ec-p256/ec-p384 are sign-only)"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # AWS rotates SYMMETRIC_DEFAULT keys only — it owns every version of them.
    # Asymmetric key material is published to callers as a public key, so AWS
    # refuses enableKeyRotation on it; the field is omitted entirely rather than
    # set to False, since sending False on an asymmetric key is still rejected.
    _rotate = _algorithm == "symmetric" and _rotation_days != Undefined

    _items: [any] = [
        # 1) The key itself. external-name is intentionally NOT pinned: AWS
        # assigns the key id, so the only name a user ever types is the alias
        # below.
        backend.Key {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.description = "EncryptionKey ${_name}"
            spec.forProvider.keyUsage = _key_usage[_purpose]
            spec.forProvider.customerMasterKeySpec = _cmk_spec[_algorithm]
            spec.forProvider.deletionWindowInDays = min([_window, _aws_max_deletion_window])
            spec.forProvider.multiRegion = _multi_region
            if _rotate:
                spec.forProvider.enableKeyRotation = True
                spec.forProvider.rotationPeriodInDays = max([_rotation_days, _aws_min_rotation_days])
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }
        # 2) The alias. This one IS pinned: "alias/<xr name>" is the identifier
        # users and other resources reference, so it must be deterministic and
        # not the random name Crossplane generates for the composed resource.
        alias.Alias {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "alias"
                "crossplane.io/external-name" = "alias/${_name}"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.targetKeyIdSelector.matchControllerRef = True
        }
    ]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _region = (_at?.region) or oxr.spec.region

    _key_id = _at?.keyId or ""

    # enableKeyRotation is a bool, so neither `or` nor `!= Undefined` detects
    # absence: an observed False is a real answer that must be reported, while
    # an absent key arrives as Undefined *or* None depending on the path. A type
    # test is the only check that separates "no observation" from "False".
    _rotation = _at?.enableKeyRotation
    _rotation_observed = typeof(_rotation) == "bool"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EncryptionKey"
        metadata.name = _name
        status = {
            provider = "aws"
            # The ARN is the last field AWS fills in, and it is what every
            # consumer of the key needs, so it doubles as the readiness signal.
            ready = (_at?.arn or "") != ""
            keyName = _name
            region = _region
            # Derived from the XR name, so it is correct before the key exists.
            alias = "alias/${_name}"
            # AWS KMS keys are always HSM-backed; spec.protectionLevel is
            # ignored by this backend and the truth is reported instead.
            protectionLevel = "hsm"
            "cloud-url" = "https://${_region}.console.aws.amazon.com/kms/home?region=${_region}#/kms/keys/${_key_id}" if _key_id else "https://${_region}.console.aws.amazon.com/kms/home?region=${_region}#/kms/keys"
            if _at?.customerMasterKeySpec:
                algorithm = _at.customerMasterKeySpec
            if _rotation_observed:
                rotationEnabled = _rotation
            if _key_id:
                keyId = _key_id
            if _at?.arn:
                arn = _at.arn
                # Other AWS resources reference a key by ARN, so the ARN is the
                # canonical URI for this backend.
                keyUri = _at.arn
            if _at?.id:
                id = _at.id
        }
    }
}
