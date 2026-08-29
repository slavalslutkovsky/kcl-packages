# kms (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-kms schema package. The portable EncryptionKey maps onto
# a Cloud KMS KeyRing plus one CryptoKey inside it. The key ring is composed
# rather than referenced because a CryptoKey cannot exist outside one and its
# name is baked into the key's own resource name — an XR that borrowed a shared
# ring would be unable to report a stable key URI. CryptoKeyVersions are NOT
# composed: Cloud KMS creates the first version with the key and rotates it
# itself, so a composed version MR would fight the rotation schedule.
import gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_key_ring as keyring
import gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Cloud KMS expresses every duration as a seconds count with an `s` suffix
# (destroyScheduledDuration, rotationPeriod), while the XR speaks in days.
_seconds_per_day = 86400

# Cloud KMS algorithm names are purpose-specific: the same RSA modulus has a
# distinct name for decryption (OAEP padding) and for signing (PKCS#1), and the
# API rejects a versionTemplate whose algorithm does not match the key purpose.
# Hence one table per purpose rather than one table keyed by algorithm.
_encrypt_algorithms = {
    "symmetric" = "GOOGLE_SYMMETRIC_ENCRYPTION"
    "rsa-2048" = "RSA_DECRYPT_OAEP_2048_SHA256"
    "rsa-3072" = "RSA_DECRYPT_OAEP_3072_SHA256"
    "rsa-4096" = "RSA_DECRYPT_OAEP_4096_SHA256"
}
_sign_algorithms = {
    "rsa-2048" = "RSA_SIGN_PKCS1_2048_SHA256"
    "rsa-3072" = "RSA_SIGN_PKCS1_3072_SHA256"
    "rsa-4096" = "RSA_SIGN_PKCS1_4096_SHA256"
    "ec-p256" = "EC_SIGN_P256_SHA256"
    # P-384 pairs with SHA-384: Cloud KMS has no EC_SIGN_P384_SHA256.
    "ec-p384" = "EC_SIGN_P384_SHA384"
}

# EC keys are sign-only on every backend, so they never appear in the
# encrypt-decrypt table; render() rejects the combination before the lookup.
_ec_algorithms = ["ec-p256", "ec-p384"]

# Native versionTemplate.algorithm for a (purpose, algorithm) pair. Both tables
# are total over the combinations render() lets through, so the lookup cannot
# miss.
version_algorithm = lambda purpose: str, algorithm: str -> str {
    _sign_algorithms[algorithm] if purpose == "sign-verify" else _encrypt_algorithms[algorithm]
}

# atProvider.id is {{key_ring}}/cryptoKeys/{{name}}, i.e. the full Cloud KMS
# resource name projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>.
# The project comes from the ProviderConfig, not the XR, so the console URL can
# only be built once the id is observed.
project_of = lambda id: str -> str {
    _parts = id.split("/")
    _parts[1] if len(_parts) > 1 else ""
}

# atProvider.keyRing is a full resource name too; the ring's own name — the part
# the console and gcloud take — is the trailing segment.
ring_of = lambda key_ring: str -> str {
    _parts = key_ring.split("/")
    _parts[len(_parts) - 1] if key_ring else ""
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _location = _spec.region

    # The XRD defaults these server-side, but render() also runs against
    # hand-written specs (tests, main.k), so every default is reapplied here.
    _purpose = _spec?.purpose or "encrypt-decrypt"
    _algorithm = _spec?.algorithm or "symmetric"
    _protection = _spec?.protectionLevel or "software"
    _window = _spec?.deletionWindowDays or 30

    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel; a rotation
    # period of 0 days is meaningless, so falsy means "no automatic rotation".
    _rotation = _spec?.rotationDays or Undefined

    assert _purpose != "sign-verify" or _algorithm != "symmetric", "kms (gcp): purpose=sign-verify requires an asymmetric algorithm, got symmetric"
    assert _purpose != "encrypt-decrypt" or _algorithm not in _ec_algorithms, "kms (gcp): purpose=encrypt-decrypt cannot use an EC algorithm (ec-p256/ec-p384 are sign-only)"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # 1) The key ring. external-name pins its id to the XR name: the ring name
    # is a path segment of every key resource name under it, so it cannot be the
    # random name Crossplane would otherwise generate.
    _items: [any] = [keyring.KeyRing {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "keyring"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _location
    }]

    # 2) The key itself, bound to the ring above by controller reference so the
    # composed pair stays together without the ring's project being known here.
    # external-name pins the key name to the XR name: it is the tail of the key
    # URI other resources encrypt with.
    _items += [backend.CryptoKey {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.keyRingSelector.matchControllerRef = True
        spec.forProvider.purpose = "ASYMMETRIC_SIGN" if _purpose == "sign-verify" else "ENCRYPT_DECRYPT"
        spec.forProvider.versionTemplate = {
            algorithm = version_algorithm(_purpose, _algorithm)
            protectionLevel = "HSM" if _protection == "hsm" else "SOFTWARE"
        }
        spec.forProvider.destroyScheduledDuration = "${_window * _seconds_per_day}s"
        # Cloud KMS rotates SYMMETRIC keys only: an asymmetric key's public half
        # is distributed to verifiers/encryptors, so Google refuses to swap the
        # primary version behind their back and rejects rotationPeriod outright.
        # rotationDays is therefore dropped (not approximated) for those keys.
        if _rotation != Undefined and _algorithm == "symmetric":
            spec.forProvider.rotationPeriod = "${_rotation * _seconds_per_day}s"
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
    }]

    # Ignored here, by design: multiRegion (Cloud KMS expresses multi-region by
    # choosing a multi-regional location, which is already spec.region),
    # exportable and mountPath (self-hosted only — Cloud KMS never releases key
    # material), resourceGroup and tenantId (Azure only).
    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _location = oxr.spec.region

    _id = _at?.id or ""
    _project = project_of(_id)

    # Before the key exists the ring is still named after the XR (external-name
    # above), which is what the console link and gcloud would need.
    _ring = ring_of(_at?.keyRing or "") or _name
    _vt = _at?.versionTemplate or Undefined

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EncryptionKey"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _id != ""
            keyName = _name
            region = _location
            keyRing = _ring
            # The observed id IS the Cloud KMS resource name, which is both the
            # native identifier and the canonical reference other GCP resources
            # (kmsKeyName fields) take — hence keyId, keyUri and id alike.
            if _id:
                keyId = _id
                keyUri = _id
                id = _id
                "cloud-url" = "https://console.cloud.google.com/security/kms/key/manage/${_location}/${_ring}/${_name}?project=${_project}"
            else:
                "cloud-url" = "https://console.cloud.google.com/security/kms"
            # Reported, never echoed from the spec: a late-initialized or
            # manually edited key may differ from what was asked for.
            if _vt != Undefined:
                algorithm = _vt?.algorithm
                protectionLevel = _vt.protectionLevel.lower() if _vt?.protectionLevel else Undefined
            if _at:
                rotationEnabled = (_at?.rotationPeriod or "") != ""
        }
    }
}
