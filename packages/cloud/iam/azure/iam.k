# iam (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-managedidentity and azure-authorization schema
# packages. The portable Identity maps onto a User Assigned Identity; each
# accessPolicies entry becomes a RoleAssignment (built-in role name, or a
# role definition ID when the role starts with "/") and trust.federated
# becomes one FederatedIdentityCredential per subject.
# A RoleAssignment needs the identity's principal (object) ID, which only
# exists once the identity is observed, so grants are composed on the second
# pass, from ocds — the standard two-phase function-kcl pattern.
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_user_assigned_identity as uai
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_federated_identity_credential as fic
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment as ra

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    assert _spec?.region, "iam-azure: spec.region is required (the Azure location of the User Assigned Identity)"
    assert _spec?.resourceGroup, "iam-azure: spec.resourceGroup is required (the Resource Group the identity lives in)"
    assert not _spec?.inlinePolicy, "iam-azure: spec.inlinePolicy is AWS-only — express fine-grained access as accessPolicies[].condition"
    assert not _spec?.permissionsBoundary, "iam-azure: spec.permissionsBoundary is AWS-only"
    assert not _spec?.trust?.services, "iam-azure: trust.services is AWS-only"
    assert not _spec?.trust?.identities, "iam-azure: trust.identities is not expressible for a User Assigned Identity — use trust.federated"

    _grants = _spec?.accessPolicies or []

    # Azure role assignments are meaningless without a scope; there is no
    # provider-level default to fall back to.
    assert all _g in _grants {
        bool(_g?.scope)
    }, "iam-azure: every accessPolicies entry needs a scope (/subscriptions/…, a resource group or a resource ID)"

    # Azure identities have no description field; carry displayName as a tag.
    _tags = _spec?.tags or {}
    if _spec?.displayName:
        _tags |= {"display-name" = _spec.displayName}

    # 1) The identity itself.
    _items: [any] = [uai.UserAssignedIdentity {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.name = _name
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        if _tags:
            spec.forProvider.tags = _tags
    }]

    # 2) Federation trust: one credential per subject, bound to the identity
    # via matchControllerRef, so no observed state is needed.
    if _spec?.trust?.federated:
        _f = _spec.trust.federated
        _items += [fic.FederatedIdentityCredential {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "federation-${_i}"
                # The credential's Azure name comes from the external name.
                "crossplane.io/external-name" = "${_name}-federation-${_i}"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.issuer = _f.issuer
            spec.forProvider.subject = _s
            spec.forProvider.audience = _f?.audiences or ["api://AzureADTokenExchange"]
            spec.forProvider.resourceGroupName = _spec.resourceGroup
            spec.forProvider.parentIdSelector.matchControllerRef = True
        } for _i, _s in _f.subjects]

    # 3) Grants: one RoleAssignment per accessPolicies entry, once the
    # identity's service principal is observed.
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _principal = _at?.principalId
    if _principal:
        _items += [ra.RoleAssignment {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "grant-${_i}"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.principalId = _principal
            spec.forProvider.principalType = "ServicePrincipal"
            # The service principal is brand new; skip the AAD replication check.
            spec.forProvider.skipServicePrincipalAadCheck = True
            spec.forProvider.scope = _g.scope
            if _g.role.startswith("/"):
                spec.forProvider.roleDefinitionId = _g.role
            else:
                spec.forProvider.roleDefinitionName = _g.role
            if _g?.condition:
                spec.forProvider.condition = _g.condition.expression
                spec.forProvider.conditionVersion = "2.0"
        } for _i, _g in _grants]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Identity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            ready = (_at?.principalId or "") != ""
            name = oxr.metadata.name
            if _at:
                if _at?.principalId:
                    principalId = _at.principalId
                    principal = _at.principalId
                if _at?.clientId:
                    clientId = _at.clientId
                if _at?.tenantId:
                    tenantId = _at.tenantId
                if _at?.id:
                    id = _at.id
                    "cloud-url" = "https://portal.azure.com/#@/resource${_at.id}"
        }
    }
}
