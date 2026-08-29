# workload-identity (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-managedidentity and azure-authorization schema
# packages plus core Kubernetes. The portable WorkloadIdentity maps onto Azure
# Workload Identity: a User Assigned Identity, a FederatedIdentityCredential
# trusting system:serviceaccount:<ns>:<name> from the cluster's OIDC issuer,
# one RoleAssignment per accessPolicies entry, and the Kubernetes
# ServiceAccount annotated with the identity's client ID.
# A RoleAssignment needs the identity's principal (object) ID and the
# annotation needs its client ID; both only exist once the identity is
# observed, so they are composed on the second pass, from ocds — the standard
# two-phase function-kcl pattern.
import k8s.api.core.v1 as corev1
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_user_assigned_identity as uai
import azure_managedidentity.models.v1beta1.managedidentity_azurem_upbound_io_v1beta1_federated_identity_credential as fic
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment as ra

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The audience Azure AD accepts for a federated Kubernetes token.
_default_audiences = ["api://AzureADTokenExchange"]

# The Kubernetes subject the cluster's OIDC tokens carry for a ServiceAccount.
ksa_subject = lambda namespace: str, name: str -> str {
    "system:serviceaccount:${namespace}:${name}"
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    assert _spec?.region, "workload-identity-azure: spec.region is required (the Azure location of the User Assigned Identity)"
    assert _spec?.resourceGroup, "workload-identity-azure: spec.resourceGroup is required (the Resource Group the identity and its federated credential live in)"
    assert not _spec?.cluster?.project, "workload-identity-azure: spec.cluster.project is GCP-only — identify the cluster with spec.cluster.oidcIssuer"
    assert not _spec?.cluster?.workloadIdentityPool, "workload-identity-azure: spec.cluster.workloadIdentityPool is GCP-only — identify the cluster with spec.cluster.oidcIssuer"

    # Without the issuer there is nothing to federate against.
    _issuer = _spec?.cluster?.oidcIssuer
    assert _issuer, "workload-identity-azure: spec.cluster.oidcIssuer is required — the OIDC issuer URL of the cluster whose ServiceAccount tokens may use this identity"

    # A federated credential is a child of the identity, so it cannot be
    # attached to one this Composition does not compose.
    assert not _spec?.identity?.existing, "workload-identity-azure: identity.existing is not expressible — a FederatedIdentityCredential needs the User Assigned Identity as its parent, so the identity must be composed here"

    _ksa = _spec.serviceAccount
    _ksa_ns = _ksa?.namespace or _ns
    _create_ksa = True if _ksa?.create == Undefined else _ksa.create

    # A namespaced composite composes only into its own namespace, so a
    # ServiceAccount elsewhere has to be created by whoever owns that namespace.
    assert not _create_ksa or _ksa_ns == _ns, "workload-identity-azure: serviceAccount.namespace '${_ksa_ns}' differs from this resource's namespace '${_ns}' — set serviceAccount.create=false to bind a ServiceAccount in another namespace"

    _grants = _spec?.accessPolicies or []

    # Azure role assignments are meaningless without a scope; there is no
    # provider-level default to fall back to.
    assert all _g in _grants {
        bool(_g?.scope)
    }, "workload-identity-azure: every accessPolicies entry needs a scope (/subscriptions/…, a resource group or a resource ID)"
    assert all _g in _grants {
        (_g?.scopeType or "project") == "project"
    }, "workload-identity-azure: accessPolicies[].scopeType is GCP-only — an Azure scope is the full resource path in scope"

    # Azure identities have no description field; carry displayName as a tag.
    _tags = _spec?.tags or {}
    if _spec?.displayName:
        _tags |= {"display-name" = _spec.displayName}

    _identity_name = _spec?.identity?.name or _name

    # 1) The identity itself.
    _items: [any] = [uai.UserAssignedIdentity {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.name = _identity_name
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        if _tags:
            spec.forProvider.tags = _tags
    }]

    # 2) The binding: the cluster's token for this ServiceAccount may act as
    # the identity. Bound to the identity via matchControllerRef, so no
    # observed state is needed.
    _items += [fic.FederatedIdentityCredential {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "binding"
            # The credential's Azure name comes from the external name.
            "crossplane.io/external-name" = "${_identity_name}-${_ksa_ns}-${_ksa.name}"
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.issuer = _issuer
        spec.forProvider.subject = ksa_subject(_ksa_ns, _ksa.name)
        spec.forProvider.audience = _spec?.cluster?.audiences or _default_audiences
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.parentIdSelector.matchControllerRef = True
    }]

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

    # 4) The workload's ServiceAccount, carrying the client ID the Azure
    # Workload Identity webhook projects into the pod, plus the label that
    # webhook selects on. Needs the client ID, so it waits for the first
    # observation.
    _client_id = _at?.clientId
    if _create_ksa and _client_id:
        _items += [corev1.ServiceAccount {
            metadata = {
                name = _ksa.name
                namespace = _ksa_ns
                labels = {"azure.workload.identity/use" = "true"}
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = "kubernetes-serviceaccount"
                    "azure.workload.identity/client-id" = _client_id
                }
            }
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _ns = oxr.metadata?.namespace or "default"
    _ksa = _spec.serviceAccount
    _ksa_ns = _ksa?.namespace or _ns
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "WorkloadIdentity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            ready = (_at?.clientId or "") != ""
            name = _spec?.identity?.name or oxr.metadata.name
            serviceAccount = "${_ksa_ns}/${_ksa.name}"
            subject = ksa_subject(_ksa_ns, _ksa.name)
            if _at?.clientId:
                clientId = _at.clientId
                annotation = _at.clientId
            if _at?.principalId:
                principalId = _at.principalId
                principal = _at.principalId
            if _at?.tenantId:
                tenantId = _at.tenantId
            if _at?.id:
                id = _at.id
                "cloud-url" = "https://portal.azure.com/#@/resource${_at.id}"
        }
    }
}
