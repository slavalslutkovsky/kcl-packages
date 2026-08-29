import .workload_identity as wi

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_issuer = "https://westeurope.oic.prod-aks.azure.com/tenant/cluster/"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_base = {
    serviceAccount = {name = "demo-sa"}
    region = "westeurope"
    resourceGroup = "platform"
    cluster = {oidcIssuer = _issuer}
}
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "WorkloadIdentity"
        metadata = {name = "demo", namespace = "apps"}
        spec = _base | _spec
    }
}

# ocds carrying an observed identity.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    clientId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                    principalId = "11111111-2222-3333-4444-555555555555"
                    tenantId = "99999999-8888-7777-6666-555555555555"
                    id = "/subscriptions/sub/resourceGroups/platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = wi.render(_build({}), {})
    assert len(items) == 2, "a minimal spec must emit the identity and the federated credential"
    assert items[0].apiVersion == "managedidentity.azure.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "UserAssignedIdentity", "the identity is a user assigned identity"
    assert items[0].spec.forProvider.name == "demo", "the identity name defaults to the XR name"
    assert items[0].spec.forProvider.location == "westeurope", "region -> location"
    assert items[0].spec.forProvider.resourceGroupName == "platform", "resourceGroup carried"
}

test_binding = lambda {
    cred = wi.render(_build({}), {})[1]
    assert cred.kind == "FederatedIdentityCredential", "the binding is a federated credential"
    assert cred.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "binding", "the binding is named"
    assert cred.metadata.annotations["crossplane.io/external-name"] == "demo-apps-demo-sa", "the credential's Azure name is derived from identity and ServiceAccount"
    assert cred.spec.forProvider.issuer == _issuer, "the cluster's issuer is trusted"
    assert cred.spec.forProvider.subject == "system:serviceaccount:apps:demo-sa", "only the bound ServiceAccount may use the identity"
    assert cred.spec.forProvider.audience == ["api://AzureADTokenExchange"], "the AAD token-exchange audience is required by default"
    assert cred.spec.forProvider.resourceGroupName == "platform", "the credential lives in the identity's resource group"
    assert cred.spec.forProvider.parentIdSelector.matchControllerRef == True, "the credential binds to the composed identity"
}

test_audiences_and_identity_name = lambda {
    items = wi.render(_build({identity.name = "external-secrets", cluster = {oidcIssuer = _issuer, audiences = ["api://custom"]}}), {})
    assert items[0].spec.forProvider.name == "external-secrets", "identity.name pins the identity name"
    assert items[1].spec.forProvider.audience == ["api://custom"], "explicit audiences win"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "external-secrets-apps-demo-sa", "the credential name follows identity.name"
}

test_display_name_becomes_tag = lambda {
    fp = wi.render(_build({displayName = "External Secrets", tags = {team = "platform"}}), {})[0].spec.forProvider
    assert fp.tags == {team = "platform", "display-name" = "External Secrets"}, "Azure identities have no description; displayName is a tag"
}

test_service_account_other_namespace = lambda {
    _spec = {
        serviceAccount = {name = "flux", namespace = "flux-system", create = False}
    }
    items = wi.render(_build(_spec), _observed)
    assert len(items) == 2, "create=false must leave the ServiceAccount to its owner"
    assert items[1].spec.forProvider.subject == "system:serviceaccount:flux-system:flux", "the subject follows the ServiceAccount's namespace"
}

# ---- render: grants ---------------------------------------------------------

# The principal ID only exists once the identity is observed: none on pass one.
test_grants_wait_for_observation = lambda {
    items = wi.render(_build({accessPolicies = [{role = "Key Vault Secrets User", scope = "/subscriptions/sub"}]}), {})
    assert len(items) == 2, "grants must not render before the identity is observed"
}

test_grants_observed = lambda {
    items = wi.render(_build({accessPolicies = [
        {role = "Key Vault Secrets User", scope = "/subscriptions/sub/resourceGroups/platform"}
        {role = "/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/abc", scope = "/subscriptions/sub"}
    ]}), _observed)
    # 2 base + 2 grants + the Kubernetes ServiceAccount
    assert len(items) == 5, "one RoleAssignment per grant, plus the annotated ServiceAccount"
    assert items[2].kind == "RoleAssignment", "grants are role assignments"
    assert items[2].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    assert items[2].spec.forProvider.principalId == "11111111-2222-3333-4444-555555555555", "grants use the observed service principal"
    assert items[2].spec.forProvider.principalType == "ServicePrincipal", "a user assigned identity is a service principal"
    assert items[2].spec.forProvider.skipServicePrincipalAadCheck == True, "the brand-new principal must skip the AAD replication check"
    assert items[2].spec.forProvider.roleDefinitionName == "Key Vault Secrets User", "a bare name is a built-in role"
    assert items[2].spec.forProvider.scope == "/subscriptions/sub/resourceGroups/platform", "scope carried"
    assert items[3].spec.forProvider.roleDefinitionId == "/subscriptions/sub/providers/Microsoft.Authorization/roleDefinitions/abc", "a leading slash is a role definition ID"
    assert items[3].spec.forProvider?.roleDefinitionName == Undefined, "a role definition ID is not a name"
}

test_grant_condition = lambda {
    _g = {role = "Storage Blob Data Reader", scope = "/subscriptions/sub", condition = {expression = "@Resource[name] StringEquals 'x'"}}
    fp = wi.render(_build({accessPolicies = [_g]}), _observed)[2].spec.forProvider
    assert fp.condition == "@Resource[name] StringEquals 'x'", "condition expression carried"
    assert fp.conditionVersion == "2.0", "ABAC conditions are version 2.0"
}

# ---- render: the Kubernetes ServiceAccount ----------------------------------
test_kubernetes_service_account = lambda {
    items = wi.render(_build({}), _observed)
    assert len(items) == 3, "the annotated ServiceAccount appears once the identity is observed"
    ksa = items[2]
    assert ksa.apiVersion == "v1" and ksa.kind == "ServiceAccount", "core Kubernetes ServiceAccount"
    assert ksa.metadata.name == "demo-sa", "named after spec.serviceAccount.name"
    assert ksa.metadata.namespace == "apps", "composed into the XR's namespace"
    assert ksa.metadata.annotations["azure.workload.identity/client-id"] == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "the webhook projects the client ID from this annotation"
    assert ksa.metadata.labels["azure.workload.identity/use"] == "true", "the webhook only mutates labelled ServiceAccounts"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = wi.render(_build({deletionPolicy = "Orphan", accessPolicies = [{role = "Reader", scope = "/subscriptions/sub"}]}), _observed)
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the identity"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the binding"
    assert _orphaned[2].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the grants"
    _deleted = wi.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = wi.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "WorkloadIdentity", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.serviceAccount == "apps/demo-sa", "the bound KSA is reported before creation"
    assert dxr.status.subject == "system:serviceaccount:apps:demo-sa", "the trusted subject is known before creation"
    assert dxr.status?.clientId == Undefined, "no client ID before the identity exists"
}

test_status_observed = lambda {
    dxr = wi.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed client ID must mark the binding ready"
    assert dxr.status.clientId == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "client ID must be surfaced"
    assert dxr.status.annotation == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "the annotation value is the client ID"
    assert dxr.status.principalId == "11111111-2222-3333-4444-555555555555", "principal ID must be surfaced"
    assert dxr.status.principal == "11111111-2222-3333-4444-555555555555", "the principal is the object ID"
    assert dxr.status.tenantId == "99999999-8888-7777-6666-555555555555", "tenant must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource/subscriptions/sub/resourceGroups/platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo", "cloud-url must point at the identity"
}
