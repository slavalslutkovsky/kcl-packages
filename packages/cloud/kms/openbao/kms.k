# kms (openbao) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend: the KMS is an OpenBao transit secrets engine
# (OpenBao is the Linux Foundation's Apache-2.0 fork of HashiCorp Vault), and
# the OpenBao SERVER is a cluster PREREQUISITE — installed, initialized and
# unsealed out-of-band, exactly like the CloudNativePG operator is for the
# postgres/cnpg backend. This Composition never installs or upgrades it.
#
# What it does own is the key material, declaratively: provider-vault speaks
# the transit API (OpenBao is wire-compatible with it), so a transit mount and
# a transit key are ordinary managed resources. That is why this backend
# composes MRs rather than a Helm release like registry/zot does.
#
# The generated schemas live in models/unknown/: `kcl import` buckets CRDs it
# cannot classify into a stable API version group under `unknown`, and these
# CRDs are v1alpha1. The path is correct — do not "fix" it.
import vault.models.unknown.vault_vaultm_upbound_io_v1alpha1_mount as mount
import vault.models.unknown.transit_vaultm_upbound_io_v1alpha1_secret_backend_key as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Default transit mount path, matching the XRD default for spec.mountPath.
default_mount_path = "transit"

# OpenBao transit key type (`$type`) per portable algorithm. Transit types are
# purely algorithmic: an RSA transit key decrypts AND signs, so `purpose` does
# not select a different type once render()'s validation has rejected the two
# impossible combinations (symmetric signing, EC encryption). EC maps to the
# `ecdsa-*` naming transit uses for the NIST curves.
transit_types = {
    "symmetric" = "aes256-gcm96"
    "rsa-2048" = "rsa-2048"
    "rsa-3072" = "rsa-3072"
    "rsa-4096" = "rsa-4096"
    "ec-p256" = "ecdsa-p256"
    "ec-p384" = "ecdsa-p384"
}

# The transit API path callers encrypt/sign against, and the identifier the
# provider derives its own external name from.
key_path = lambda mount_path: str, name: str -> str {
    "${mount_path}/keys/${name}"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # XRD defaults are applied server-side by Crossplane, but render() is also
    # called with hand-written specs (tests, main.k), so every default is
    # re-applied here.
    _purpose = _spec?.purpose or "encrypt-decrypt"
    _algorithm = _spec?.algorithm or "symmetric"
    _path = _spec?.mountPath or default_mount_path
    _exportable = _spec?.exportable or False
    _policy = _spec?.deletionPolicy or "Delete"

    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel meaning "no
    # automatic rotation"; a rotation period of 0 days is not expressible.
    _rotation_days = _spec?.rotationDays or Undefined

    assert not (_purpose == "sign-verify" and _algorithm == "symmetric"), "kms (openbao): purpose=sign-verify requires an asymmetric algorithm, got symmetric"
    assert not (_purpose == "encrypt-decrypt" and _algorithm in ["ec-p256", "ec-p384"]), "kms (openbao): purpose=encrypt-decrypt cannot use an EC algorithm (ec-p256/ec-p384 are sign-only)"

    [
        # 1) The transit secrets engine itself. external-name is pinned to the
        # mount path because the path IS the mount's identity in OpenBao (and
        # the prefix of every key's API path), not a provider-assigned id.
        mount.Mount {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "transit-mount"
                "crossplane.io/external-name" = _path
            }
            # THE one place this backend deliberately ignores
            # spec.deletionPolicy: a mount is shared by every EncryptionKey
            # that lives at this path, so no single XR may ever delete it —
            # doing so would take every sibling's keys with it. Always the
            # orphan set, Delete included; the mount is adopted if it already
            # exists (Observe + LateInitialize) and only ever created once.
            spec.managementPolicies = _orphan_policies
            spec.forProvider.path = _path
            spec.forProvider.$type = "transit"
            spec.forProvider.description = "transit keys managed by Crossplane EncryptionKey composites"
        }
        # 2) The key. No external-name pin: forProvider.name + forProvider.backend
        # ARE the key's identity, and upjet derives the external name from them
        # ("<backend>/keys/<name>"), so pinning it would fight the provider.
        backend.SecretBackendKey {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
            if _policy == "Orphan":
                spec.managementPolicies = _orphan_policies
            spec.forProvider.name = _name
            spec.forProvider.backend = _path
            spec.forProvider.$type = transit_types[_algorithm]
            # Both flags, from the one portable switch: a plaintext BACKUP of a
            # non-exportable key still hands out the key material, so allowing
            # one while refusing the other buys nothing. Both are one-way in
            # OpenBao — once enabled on a key they cannot be turned off.
            spec.forProvider.exportable = _exportable
            spec.forProvider.allowPlaintextBackup = _exportable
            # OpenBao refuses to delete a transit key unless the key itself
            # permits it, so this is what actually makes deletionPolicy=Delete
            # work — and an Orphan XR must leave it off, or a stray API call
            # could destroy key material Crossplane promised to keep.
            spec.forProvider.deletionAllowed = _policy == "Delete"
            # Transit rotates SYMMETRIC AND ASYMMETRIC keys: this is the one
            # backend where asymmetric rotation works (AWS and GCP rotate
            # symmetric keys only). Period is seconds, the XR speaks days.
            if _rotation_days != Undefined:
                spec.forProvider.autoRotatePeriod = _rotation_days * 86400
            # Rotation archives nothing by itself: every version from 1 up
            # stays usable for decryption, so data encrypted before a rotation
            # keeps decrypting.
            spec.forProvider.minDecryptionVersion = 1
        }
    ]
}

# spec.region, protectionLevel, deletionWindowDays, multiRegion and tags
# are ignored here and documented as such in the XRD: the engine runs where
# the XR does, the software barrier is the only seal available without an
# enterprise license, transit deletes a key immediately, there are no
# replicas, and transit keys carry no metadata to label.

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _path = _spec?.mountPath or default_mount_path
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EncryptionKey"
        metadata.name = _name
        status = {
            provider = "openbao"
            # latestVersion is 1-indexed: a key with a first version exists and
            # can encrypt. Absent (or 0) means the key has not been created yet.
            ready = (_at?.latestVersion or 0) >= 1
            keyName = _name
            mountPath = _path
            # In transit the key's NAME is its identifier — there is no
            # provider-assigned handle to wait for, unlike a KMS key id.
            keyId = _name
            # Both are deterministic from the mount path and the XR name, so
            # they are reported before observation (as registry/zot reports its
            # in-cluster endpoints): keyUri is the transit API path callers
            # encrypt against, and cloud-url is the same location in
            # addressable form, since a self-hosted engine has no console.
            keyUri = key_path(_path, _name)
            "cloud-url" = "bao://${key_path(_path, _name)}"
            # No enterprise seal means no HSM path: transit key operations
            # always happen in OpenBao's software barrier.
            protectionLevel = "software"
            rotationEnabled = (_at?.autoRotatePeriod or 0) > 0
            # status.region is deliberately never set: the engine runs in this
            # cluster, so the region the XR had to supply (the XRD requires it
            # for the cloud backends) describes nothing here.
            if _at?.type:
                algorithm = _at.type
            if _at?.id:
                id = _at.id
        }
    }
}
