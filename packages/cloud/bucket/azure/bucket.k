# bucket (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-storage schema package.
#
# spec.import adopts an existing storage account. The account name is the
# provider's external name, but the ARM id it observes also needs the resource
# group, which is why import.resourceGroup exists (Azure only). The lifecycle
# ManagementPolicy is not rendered in observe mode: it is identified through
# the account it belongs to and has nothing to observe on its own.
#
# spec.access gives CI pipelines (and the ticket systems that start them)
# keyless access to the account's blobs: per entry a User Assigned Identity,
# one FederatedIdentityCredential per token subject, and a Storage Blob Data
# RoleAssignment on the account (render_access).
import crypto
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_account as backend
import azure_storage.models.v1beta1.storage_azurem_upbound_io_v1beta1_management_policy as policy
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_user_assigned_identity as uai
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_federated_identity_credential as fic
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment as ra
import federation.lib as fed

# Azure accessTier has no account-level Archive: tier blobs to Archive
# via a companion ManagementPolicy MR for the deepest tier(s).
_access_tier = {"standard" = "Hot", "nearline" = "Cool", "cold" = "Cold", "archive" = "Cold"}
_archive_days = {"archive" = 180}

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# How Crossplane relates to the cloud bucket, for status.mode:
# created (Crossplane made it) | observe (adopted, read-only) | managed (adopted, Crossplane writes).
mode_of = lambda oxr -> str {
    _imp = oxr.spec?.$import
    "created" if not _imp?.existingName else ("observe" if (_imp?.mode or "observe") == "observe" else "managed")
}

render = lambda oxr {
    _spec = oxr.spec
    _del = _spec?.deletionPolicy or "Delete"
    _imp = _spec?.$import
    _existing = _imp?.existingName
    _observe = _existing and (_imp?.mode or "observe") == "observe"
    _mp = ["Observe"] if _observe else (_orphan_policies if _del == "Orphan" else Undefined)

    # pin=False for the ManagementPolicy: the provider derives its id from the
    # account, so an external-name there would be wrong, not just redundant.
    _annos = lambda name: str, pin: bool -> {str:str} {
        _a = {"krm.kcl.dev/composition-resource-name" = name}
        if _existing and pin:
            _a |= {"crossplane.io/external-name" = _existing}

        if _imp?.source:
            _a |= {"cloud.example.org/imported-from" = _imp.source}

        if _imp?.address:
            _a |= {"cloud.example.org/import-address" = _imp.address}

        _a
    }

    _items: [any] = [backend.Account {
        metadata.annotations = _annos("managed", True)
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.accountTier = "Standard"
        spec.forProvider.accountReplicationType = "LRS"
        if _imp?.resourceGroup:
            spec.forProvider.resourceGroupName = _imp.resourceGroup
        if _spec?.storageClass:
            spec.forProvider.accessTier = _access_tier[_spec.storageClass]
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]
    _sc = _spec?.storageClass
    if _sc and _sc in _archive_days and not _observe:
        _items += [policy.ManagementPolicy {
            metadata.annotations = _annos("lifecycle", False)
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.storageAccountIdSelector.matchControllerRef = True
            spec.forProvider.$rule = [{
                name = "archive"
                enabled = True
                filters = {blobTypes = ["blockBlob"]}
                actions = {
                    baseBlob = {tierToArchiveAfterDaysSinceModificationGreaterThan = _archive_days[_sc]}
                }
            }]
        }]

    _items
}

# Built-in data-plane roles per access role: blobs only, never the account's
# configuration, its keys or IAM.
blob_roles = {"read" = "Storage Blob Data Reader", "write" = "Storage Blob Data Contributor", "admin" = "Storage Blob Data Owner"}

# Observed atProvider of a composed resource, Undefined until observed.
_observed = lambda ocds, name: str {
    (ocds[name]?.Resource?.status?.atProvider) if (ocds and name in ocds) else Undefined
}

# Who an entry admits, for the identity's access-for tag.
access_label = lambda b: fed.Access -> str {
    _t = fed.ticket_of(b)
    _c = fed.client_of(b)
    "${_t.label} via ${_c.label}" if _t else _c.label
}

# Validated access entries; fails on settings Azure access cannot honour.
_access_of = lambda oxr -> [fed.Access] {
    _spec = oxr.spec
    _fed = _spec?.federation
    assert not _fed?.gcpProjectNumber, "bucket-azure: spec.federation.gcpProjectNumber is GCP-only — Azure access needs spec.federation.azureResourceGroup (or import.resourceGroup)"
    assert not _fed?.awsAccountId, "bucket-azure: spec.federation.awsAccountId is AWS-only — Azure access needs spec.federation.azureResourceGroup (or import.resourceGroup)"
    _entries = _spec?.access or []
    if _entries:
        assert _fed?.azureResourceGroup or _spec?.$import?.resourceGroup, "bucket-azure: spec.access needs spec.federation.azureResourceGroup (or import.resourceGroup) — the Resource Group its User Assigned Identities live in"
        assert mode_of(oxr) != "observe", "bucket-azure: access writes IAM; Crossplane promised read-only in observe mode — switch import.mode to manage or drop access"

    fed.access_list(_entries)
}

# One entry's resources: the identity always; the credentials once its id is
# observed (several identities live in one composite, so matchControllerRef
# would be ambiguous); the grant once its principal and the account's id are.
_entry_items = lambda oxr, ocds, b: fed.Access -> [any] {
    _spec = oxr.spec
    _rg = _spec?.federation?.azureResourceGroup or _spec?.$import?.resourceGroup
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _n = fed.access_name(b)
    _res = "access-${_n}"
    _identity = "${oxr.metadata.name}-${_n}"
    assert len(_identity) <= 128, "bucket-azure: identity name '${_identity}' is over Azure's 128 characters — shorten the XR name or the entry's pool/provider"
    _subjects = fed.azure_subjects(b)
    _dups = [_s for _i, _s in _subjects if _s in _subjects[:_i:]]
    assert not _dups, "bucket-azure: access ${_n} lists subjects twice: ${_dups}"
    _issuer = fed.issuer_uri(b)
    _aud = fed.audiences_for(b, "azure")
    _id = _observed(ocds, _res)
    _account = _observed(ocds, "managed")
    _items: [any] = [uai.UserAssignedIdentity {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _res}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.name = _identity
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.tags = (_spec?.tags or {}) | {"access-for" = access_label(b)}
    }]
    if _id?.id:
        _items += [fic.FederatedIdentityCredential {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "${_res}-${_h}"
                # The credential's Azure name comes from the external name.
                "crossplane.io/external-name" = "${_identity}-${_h}"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.issuer = _issuer
            spec.forProvider.subject = _s
            spec.forProvider.audience = _aud
            spec.forProvider.resourceGroupName = _rg
            spec.forProvider.parentId = _id.id
        } for _s in _subjects for _h in [crypto.sha256(_s)[:8]]]

    if _id?.principalId and _account?.id:
        _items += [ra.RoleAssignment {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "${_res}-grant"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.principalId = _id.principalId
            spec.forProvider.principalType = "ServicePrincipal"
            # The service principal is brand new; skip the AAD replication check.
            spec.forProvider.skipServicePrincipalAadCheck = True
            spec.forProvider.scope = _account.id
            spec.forProvider.roleDefinitionName = blob_roles[b.role]
        }]

    _items
}

# Per access entry: a User Assigned Identity, one FederatedIdentityCredential
# per token subject and a Storage Blob Data RoleAssignment on the account.
render_access = lambda oxr, ocds -> [any] {
    sum([_entry_items(oxr, ocds, _e) for _e in _access_of(oxr)], [])
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = _observed(ocds, "managed")
    _id = _at?.id or ""
    _entries = oxr.spec?.access or []
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Bucket"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            mode = mode_of(oxr)
            ready = _id != ""
            if _id:
                id = _id
                bucketName = _id.split("/")[-1]
                "cloud-url" = "https://portal.azure.com/#@/resource${_id}"
            if _at?.primaryBlobEndpoint:
                endpoint = _at.primaryBlobEndpoint
            if _at?.primaryLocation:
                region = _at.primaryLocation
            if _entries:
                access = [{
                    name = _n
                    role = _e.role
                    if _o?.clientId:
                        clientId = _o.clientId
                    if _o?.tenantId:
                        tenantId = _o.tenantId
                } for _e in fed.access_list(_entries) for _n in [fed.access_name(_e)] for _o in [_observed(ocds, "access-${_n}")]]
        }
    }
}
