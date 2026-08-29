# kms (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-keyvault schema package. The portable EncryptionKey
# maps onto TWO managed resources, because Azure has no standalone key: a Key
# Vault is the container that holds key material and enforces the protection
# level (standard = software, premium = HSM), and the Key itself lives inside
# it. One vault per XR keeps the SKU, the purge/soft-delete window and the RBAC
# surface owned by exactly one claim; sharing a vault across XRs would make
# `protectionLevel` and `deletionWindowDays` a race between claims.
import azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_vault as vault
import azure_keyvault.models.v1beta1.keyvault_azurem_upbound_io_v1beta1_key as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Portable algorithm -> RSA modulus size. `symmetric` has no Key Vault
# equivalent (Key Vault only issues RSA and EC keys; the `oct` type exists in
# the data plane but is Managed-HSM-only and not exposed by this provider), so
# the portable symmetric key becomes the strongest RSA wrap key instead. This
# is the documented portable stand-in: it still satisfies encrypt/decrypt and
# wrap/unwrap, which is what a symmetric KMS key is used for.
_rsa_key_sizes = {"symmetric" = 4096, "rsa-2048" = 2048, "rsa-3072" = 3072, "rsa-4096" = 4096}

# Portable algorithm -> JWK curve name for the EC cases.
_curves = {"ec-p256" = "P-256", "ec-p384" = "P-384"}

# JSON web key operations. Key Vault has no "purpose" field: what a key may do
# IS its keyOpts list, so purpose is expressed by granting exactly one of these
# two sets. wrapKey/unwrapKey ride along with encrypt/decrypt because that is
# how an RSA key is used as a KMS-style envelope key.
_encrypt_key_opts = ["decrypt", "encrypt", "wrapKey", "unwrapKey"]
_sign_key_opts = ["sign", "verify"]

# Key Vault key type for the algorithm/protection pair. The "-HSM" suffix is
# what actually pins operations to the HSM partition — the premium vault SKU
# only makes HSM keys *possible*, it does not make a plain RSA/EC key
# HSM-backed, so both must be set together.
key_type_for = lambda algorithm: str, protection_level: str -> str {
    _base = "EC" if algorithm in _curves else "RSA"
    "${_base}-HSM" if protection_level == "hsm" else _base
}

# Key Vault SKU for the protection level: HSM-backed key types are rejected by
# a standard vault, so `hsm` must lift the whole vault to premium.
sku_for = lambda protection_level: str -> str {
    "premium" if protection_level == "hsm" else "standard"
}

# Rotation policy for the requested rotation period. Azure rejects an
# automatic rotation policy that has no expiry, so expireAfter is derived at
# twice the rotation period: that guarantees the successor version exists (and
# has been rotated to) well before the predecessor expires, without inventing a
# second knob in the portable API. notifyBeforeExpiry is the fixed 30-day
# Event Grid warning window.
rotation_policy_for = lambda rotation_days: int -> any {
    {
        automatic = {timeAfterCreation = "P${rotation_days}D"}
        expireAfter = "P${rotation_days * 2}D"
        notifyBeforeExpiry = "P30D"
    }
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # The XRD defaults these server-side, but render() is also called with
    # hand-written specs (tests, `kcl run main.k`), so every default is applied
    # defensively here too.
    _purpose = _spec?.purpose or "encrypt-decrypt"
    _algorithm = _spec?.algorithm or "symmetric"
    _protection = _spec?.protectionLevel or "software"
    _window = _spec?.deletionWindowDays or 30

    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel; a rotation
    # period of 0 days is not a thing, so falsiness is safe here.
    _rotation = _spec?.rotationDays or Undefined

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    assert _spec?.resourceGroup, "kms (azure): spec.resourceGroup is required (the Resource Group the Key Vault lives in)"
    assert _spec?.tenantId, "kms (azure): spec.tenantId is required (Key Vault has no tenant-less form — it authenticates every data-plane call against an Entra ID tenant)"

    # Portable validation, identical on every backend.
    assert not (_purpose == "sign-verify" and _algorithm == "symmetric"), "kms (azure): purpose=sign-verify requires an asymmetric algorithm, got symmetric"
    assert not (_purpose == "encrypt-decrypt" and _algorithm in _curves), "kms (azure): purpose=encrypt-decrypt cannot use an EC algorithm (ec-p256/ec-p384 are sign-only)"

    _key_type = key_type_for(_algorithm, _protection)

    # 1) The vault. external-name pins the vault name to the XR name because it
    # IS the DNS host of the data plane (`<name>.vault.azure.net`), so it can
    # never be the random name Crossplane generates for a composed resource.
    _items: [any] = [vault.Vault {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "vault"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.tenantId = _spec.tenantId
        spec.forProvider.skuName = sku_for(_protection)
        # Access policies are the legacy authorization model and are managed as
        # a mutable list on the vault, which fights Crossplane's ownership of
        # the resource. RBAC is the current model: the provider identity must
        # hold the "Key Vault Crypto Officer" role on this vault (or its
        # resource group) or the Key below will fail to create.
        spec.forProvider.enableRbacAuthorization = True
        # Purge protection is what makes softDeleteRetentionDays a real grace
        # period: without it a deleted vault can be purged immediately and the
        # key material is gone the same day.
        spec.forProvider.purgeProtectionEnabled = True
        spec.forProvider.softDeleteRetentionDays = _window
        # The control plane (this provider) reaches the data plane over the
        # public endpoint; disabling it would require a private endpoint the
        # portable API does not model.
        spec.forProvider.publicNetworkAccessEnabled = True
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) The key. external-name pins the key name to the XR name because it is
    # the last path segment of every key URI callers reference.
    _items += [backend.Key {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        # Bind to the vault composed above rather than naming its id, which is
        # only known after the vault exists.
        spec.forProvider.keyVaultIdSelector.matchControllerRef = True
        spec.forProvider.keyType = _key_type
        # keySize and curve are mutually exclusive in the Key Vault API: an EC
        # key rejects keySize and an RSA key rejects curve, so exactly one of
        # them is emitted per algorithm.
        if _algorithm in _curves:
            spec.forProvider.curve = _curves[_algorithm]
        else:
            spec.forProvider.keySize = _rsa_key_sizes[_algorithm]
        spec.forProvider.keyOpts = _sign_key_opts if _purpose == "sign-verify" else _encrypt_key_opts
        if _rotation != Undefined:
            spec.forProvider.rotationPolicy = rotation_policy_for(_rotation)
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _vault = (ocds["vault"]?.Resource?.status?.atProvider) if ("vault" in ocds) else Undefined
    _name = oxr.metadata.name

    # The version-LESS id is the canonical reference: it is what other Azure
    # resources (Storage/SQL/Disk encryption) must point at so they follow the
    # key when it rotates. The versioned id would pin them to one version.
    _key_uri = _at?.versionlessId or ""
    _vault_id = _vault?.id or ""
    _key_type = _at?.keyType or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EncryptionKey"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = _key_uri != ""
            keyName = _name
            region = _vault?.location or oxr.spec.region
            # The vault has no per-key blade URL, so the console link addresses
            # the keys list of the vault; before the vault id is observed there
            # is nothing to address but the vault browser.
            "cloud-url" = "https://portal.azure.com/#@/resource${_vault_id}/keys" if _vault_id else "https://portal.azure.com/#browse/Microsoft.KeyVault%2Fvaults"
            if _vault?.vaultUri:
                vaultUri = _vault.vaultUri
            if _key_uri:
                keyId = _key_uri
                keyUri = _key_uri
            if _at?.version:
                version = _at.version
            if _key_type:
                algorithm = _key_type
                # The "-HSM" suffix on the observed key type is the only
                # authoritative signal that operations happen in the HSM; the
                # premium vault SKU alone does not imply it.
                protectionLevel = "hsm" if _key_type.endswith("-HSM") else "software"
            if _at:
                rotationEnabled = (_at?.rotationPolicy or Undefined) != Undefined
                if _at?.id:
                    id = _at.id
        }
    }
}
