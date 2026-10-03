# kms (oci) — Crossplane Composition logic (function-kcl module).
# Typed against the oci-kms schema package. The portable EncryptionKey maps onto
# TWO managed resources, because OCI has no standalone key: a Vault is the
# container that owns the management and crypto endpoints, and the Key (a
# "master encryption key") is created through its vault's management endpoint.
# One vault per XR, as on Azure: the vault's lifecycle (pending deletion) and
# its IAM surface stay owned by exactly one claim, and a default vault is free,
# so sharing one across XRs would buy nothing but a cross-claim race.
# KeyVersions are NOT composed: OCI creates the first version with the key, and
# a composed version MR would fight any rotation done in the console.
# kcl 0.13 splits each CRD into one file per schema, so the package to import
# is the whole models/unknown directory rather than a per-kind file.
import oci_kms.models.unknown as oci

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# DEFAULT is the multitenant "virtual vault": free to create, and it still holds
# HSM-protected keys (protectionMode HSM keeps the key and every operation on
# it inside the HSM — per the Key CRD's protectionMode description, which is
# per KEY, not per vault). VIRTUAL_PRIVATE is a dedicated HSM partition billed
# at a large fixed monthly cost regardless of key count; a portable per-key API
# must never opt into that implicitly.
_vault_type = "DEFAULT"

# Portable algorithm -> OCI keyShape. OCI has no purpose field: what a key can
# do follows from its algorithm (AES encrypts, RSA encrypts or signs, ECDSA
# only signs). `length` is in BYTES, not bits (AES 16/24/32, RSA 256/384/512,
# ECDSA 32/48/66 per the oci_kms_key docs the CRD is generated from), and ECDSA
# additionally names its curve.
_key_shapes = {
    "symmetric" = {algorithm = "AES", length = 32}
    "rsa-2048" = {algorithm = "RSA", length = 256}
    "rsa-3072" = {algorithm = "RSA", length = 384}
    "rsa-4096" = {algorithm = "RSA", length = 512}
    "ec-p256" = {algorithm = "ECDSA", length = 32, curveId = "NIST_P256"}
    "ec-p384" = {algorithm = "ECDSA", length = 48, curveId = "NIST_P384"}
}

# EC keys are sign-only on every backend.
_ec_algorithms = ["ec-p256", "ec-p384"]

# The OCI provider has no per-resource region: it signs every call for the
# region in its ProviderConfig's credentials. Each MR therefore binds to the
# cluster-wide config for its region, one per region by convention.
provider_config_for = lambda region: str -> any {
    {kind = "ClusterProviderConfig", name = "oci-${region}"}
}

# The vault's management endpoint, or "" while it is unknown. The observed
# vault is the source; the key's own spec/observation is the fallback, so a
# vault observation that momentarily lacks the endpoint can never drop an
# existing Key from the desired state (which Crossplane would read as delete).
management_endpoint_of = lambda ocds: any -> str {
    _vault_at = (ocds["vault"]?.Resource?.status?.atProvider) if ("vault" in ocds) else Undefined
    _key = (ocds["managed"]?.Resource) if ("managed" in ocds) else Undefined
    _vault_at?.managementEndpoint or _key?.spec?.forProvider?.managementEndpoint or _key?.status?.atProvider?.managementEndpoint or ""
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    # The XRD defaults these server-side, but render() also runs against
    # hand-written specs (tests, main.k), so every default is reapplied here.
    _purpose = _spec?.purpose or "encrypt-decrypt"
    _algorithm = _spec?.algorithm or "symmetric"
    _protection = _spec?.protectionLevel or "software"

    assert _spec?.compartmentId, "kms (oci): spec.compartmentId is required"
    assert _purpose != "sign-verify" or _algorithm != "symmetric", "kms (oci): purpose=sign-verify requires an asymmetric algorithm, got symmetric"
    assert _purpose != "encrypt-decrypt" or _algorithm not in _ec_algorithms, "kms (oci): purpose=encrypt-decrypt cannot use an EC algorithm (ec-p256/ec-p384 are sign-only)"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _pcr = provider_config_for(_region)
    _endpoint = management_endpoint_of(ocds)

    # 1) The vault. external-name is NOT pinned (on either MR): OCI assigns
    # every resource an OCID and looks resources up by it, so the XR name can
    # only be the displayName. The compartment comes from the spec because OCI
    # requires it on the resource and the ProviderConfig does not imply one.
    _items: [any] = [oci.Vault {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "vault"}
        if _mp:
            spec.managementPolicies = _mp
        spec.providerConfigRef = _pcr
        spec.forProvider.compartmentId = _spec.compartmentId
        spec.forProvider.displayName = _name
        spec.forProvider.vaultType = _vault_type
        if _spec?.tags:
            spec.forProvider.freeformTags = _spec.tags
    }]

    # 2) The key. The Key CRD has no managementEndpointRef/Selector (and no
    # vault id field at all — the endpoint IS the vault binding), so the
    # endpoint is read from the observed vault and the Key is only emitted once
    # it is known; the next reconcile after the vault is ready creates it.
    if _endpoint:
        _items += [oci.Key {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
            if _mp:
                spec.managementPolicies = _mp
            spec.providerConfigRef = _pcr
            spec.forProvider.compartmentId = _spec.compartmentId
            spec.forProvider.displayName = _name
            spec.forProvider.managementEndpoint = _endpoint
            spec.forProvider.keyShape = [_key_shapes[_algorithm]]
            # Immutable after creation; OCI's own default would be HSM.
            spec.forProvider.protectionMode = "HSM" if _protection == "hsm" else "SOFTWARE"
            if _spec?.tags:
                spec.forProvider.freeformTags = _spec.tags
        }]

    # Ignored here, by design:
    # - rotationDays: OCI auto key rotation (isAutoRotationEnabled +
    #   autoKeyRotationDetails.rotationIntervalInDays, 60-365 days) is only
    #   available in VIRTUAL_PRIVATE vaults, which this backend does not create
    #   (see _vault_type).
    # - deletionWindowDays: OCI schedules key and vault deletion 7-30 days out
    #   (30 by default, matching the XRD default), but its only knob,
    #   timeOfDeletion, is an absolute RFC 3339 timestamp — a render-time clock
    #   would make the desired state change on every reconcile.
    # - multiRegion (OCI replicates only private vaults), exportable and
    #   mountPath (self-hosted only), resourceGroup and tenantId (Azure only).
    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _vault = (ocds["vault"]?.Resource?.status?.atProvider) if ("vault" in ocds) else Undefined
    _name = oxr.metadata.name
    _region = oxr.spec.region

    _id = _at?.id or ""
    _vault_id = _at?.vaultId or _vault?.id or ""
    _shapes = _at?.keyShape or []

    # isAutoRotationEnabled is a bool: an observed False is a real answer, so
    # only a type test separates it from "not observed".
    _rotation = _at?.isAutoRotationEnabled

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EncryptionKey"
        metadata.name = _name
        status = {
            provider = "oci"
            ready = _id != ""
            keyName = _name
            region = _region
            # The key OCID is the native id and also what other OCI resources
            # (kmsKeyId fields) reference — hence keyId, keyUri and id alike.
            if _id:
                keyId = _id
                keyUri = _id
                id = _id
            "cloud-url" = "https://cloud.oracle.com/security/kms/vaults/${_vault_id}/keys/${_id}?region=${_region}" if _id and _vault_id else "https://cloud.oracle.com/security/kms"
            if _vault_id:
                vaultId = _vault_id
            if _vault?.managementEndpoint:
                managementEndpoint = _vault.managementEndpoint
            if _vault?.cryptoEndpoint:
                cryptoEndpoint = _vault.cryptoEndpoint
            # Reported, never echoed from the spec.
            if _shapes:
                algorithm = _shapes[0]?.algorithm
            if _at?.protectionMode:
                protectionLevel = _at.protectionMode.lower()
            if typeof(_rotation) == "bool":
                rotationEnabled = _rotation
        }
    }
}
