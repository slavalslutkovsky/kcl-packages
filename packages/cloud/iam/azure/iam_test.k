import .iam

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "Identity"
        metadata.name = "demo"
        spec = {region = "westeurope", resourceGroup = "demo-rg"} | _spec
    }
}

# ocds carrying an observed identity.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    id = "/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo"
                    principalId = "aaaa-bbbb"
                    clientId = "cccc-dddd"
                    tenantId = "eeee-ffff"
                }
            }
        }
    }
}

_scope = "/subscriptions/0b1f/resourceGroups/demo-rg"

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = iam.render(_build({}), {})
    assert len(items) == 1, "minimal spec must emit exactly one UserAssignedIdentity"
    assert items[0].apiVersion == "managedidentity.azure.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "UserAssignedIdentity", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.name == "demo", "identity name pinned to the XR name"
    assert fp.location == "westeurope", "region -> location"
    assert fp.resourceGroupName == "demo-rg", "resourceGroup carried"
}

test_display_name_and_tags = lambda {
    fp = iam.render(_build({displayName = "CI deployer", tags = {team = "platform"}}), {})[0].spec.forProvider
    assert fp.tags == {team = "platform", "display-name" = "CI deployer"}, "displayName rides along as a tag"
    bare = iam.render(_build({}), {})[0].spec.forProvider
    assert bare?.tags == Undefined, "no tags unless asked for"
}

# ---- render: trust (federation) ----------------------------------------------
test_trust_federated = lambda {
    items = iam.render(_build({
        trust.federated = {
            issuer = "https://token.actions.githubusercontent.com"
            subjects = ["repo:my-org/a:ref:refs/heads/main", "repo:my-org/b:ref:refs/heads/main"]
        }
    }), {})
    assert len(items) == 3, "one FederatedIdentityCredential per subject"
    assert items[1].kind == "FederatedIdentityCredential", "federation is a credential"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "federation-0", "credentials are numbered"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "demo-federation-0", "credential name pinned"
    fp = items[1].spec.forProvider
    assert fp.issuer == "https://token.actions.githubusercontent.com", "issuer carried"
    assert fp.subject == "repo:my-org/a:ref:refs/heads/main", "subject carried"
    assert fp.audience == ["api://AzureADTokenExchange"], "audience defaults to the token-exchange audience"
    assert fp.resourceGroupName == "demo-rg", "resource group carried"
    assert fp.parentIdSelector.matchControllerRef == True, "credential binds to the composed identity"
    assert items[2].spec.forProvider.subject == "repo:my-org/b:ref:refs/heads/main", "every subject gets its credential"
}

test_trust_federated_audiences = lambda {
    items = iam.render(_build({
        trust.federated = {
            issuer = "https://token.actions.githubusercontent.com"
            subjects = ["repo:x"]
            audiences = ["custom"]
        }
    }), {})
    assert items[1].spec.forProvider.audience == ["custom"], "explicit audiences win"
}

# ---- render: grants (access control) ----------------------------------------

# The principal ID only exists once the identity is observed: no grants on pass one.
test_grants_wait_for_observation = lambda {
    items = iam.render(_build({accessPolicies = [{role = "Reader", scope = _scope}]}), {})
    assert len(items) == 1, "grants must not render before the identity is observed"
}

test_grants_observed = lambda {
    items = iam.render(_build({accessPolicies = [
        {role = "Storage Blob Data Reader", scope = _scope}
        {role = "/subscriptions/0b1f/providers/Microsoft.Authorization/roleDefinitions/1234", scope = _scope}
    ]}), _observed)
    assert len(items) == 3, "one RoleAssignment per grant once observed"
    assert items[1].kind == "RoleAssignment", "grants are role assignments"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    fp = items[1].spec.forProvider
    assert fp.principalId == "aaaa-bbbb", "principal is the observed identity"
    assert fp.principalType == "ServicePrincipal", "assignments target the service principal"
    assert fp.skipServicePrincipalAadCheck == True, "fresh principals skip the AAD replication check"
    assert fp.roleDefinitionName == "Storage Blob Data Reader", "built-in role by name"
    assert fp?.roleDefinitionId == Undefined, "no id when the role is a name"
    assert fp.scope == _scope, "scope carried"
    assert items[2].spec.forProvider.roleDefinitionId == "/subscriptions/0b1f/providers/Microsoft.Authorization/roleDefinitions/1234", "roles starting with / are definition IDs"
    assert items[2].spec.forProvider?.roleDefinitionName == Undefined, "no name when the role is an ID"
}

test_grant_condition = lambda {
    items = iam.render(_build({accessPolicies = [{
        role = "Storage Blob Data Reader"
        scope = _scope
        condition = {expression = "@Resource[x] StringEquals 'artifacts'"}
    }]}), _observed)
    fp = items[1].spec.forProvider
    assert fp.condition == "@Resource[x] StringEquals 'artifacts'", "ABAC condition carried"
    assert fp.conditionVersion == "2.0", "conditions use version 2.0"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = iam.render(_build({deletionPolicy = "Orphan", accessPolicies = [{role = "Reader", scope = _scope}]}), _observed)
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the identity"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the grants"
    _deleted = iam.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = iam.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Identity", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status?.principalId == Undefined, "no principal before the identity exists"
}

test_status_observed = lambda {
    dxr = iam.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed principal must mark the identity ready"
    assert dxr.status.principalId == "aaaa-bbbb", "principalId must be surfaced"
    assert dxr.status.principal == "aaaa-bbbb", "principal is the object ID"
    assert dxr.status.clientId == "cccc-dddd", "clientId must be surfaced"
    assert dxr.status.tenantId == "eeee-ffff", "tenantId must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource/subscriptions/0b1f/resourceGroups/demo-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/demo", "cloud-url must point at the identity"
}
