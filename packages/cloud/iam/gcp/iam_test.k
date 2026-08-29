import .iam

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Identity", metadata.name = "demo", spec = _spec}
}

# ocds carrying an observed service account.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    email = "demo@my-project.iam.gserviceaccount.com"
                    member = "serviceAccount:demo@my-project.iam.gserviceaccount.com"
                    id = "projects/my-project/serviceAccounts/demo@my-project.iam.gserviceaccount.com"
                    uniqueId = "12345"
                    project = "my-project"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = iam.render(_build({}), {})
    assert len(items) == 1, "empty spec must emit exactly one ServiceAccount"
    assert items[0].apiVersion == "cloudplatform.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "ServiceAccount", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "accountId must be pinned to the XR name"
    assert items[0].spec.forProvider.displayName == "demo", "displayName defaults to the XR name"
}

test_display_name = lambda {
    fp = iam.render(_build({displayName = "CI deployer"}), {})[0].spec.forProvider
    assert fp.displayName == "CI deployer", "displayName must be carried"
}

# ---- render: trust (impersonation) -------------------------------------------
test_trust_identities = lambda {
    items = iam.render(_build({trust.identities = ["user:alice@example.com", "principal://iam.googleapis.com/x"]}), {})
    assert len(items) == 3, "one ServiceAccountIAMMember per trusted identity"
    assert items[1].kind == "ServiceAccountIAMMember", "trust is a service-account IAM member"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "trust-0", "trust members are numbered"
    assert items[1].spec.forProvider.role == "roles/iam.serviceAccountTokenCreator", "trusted identities may mint tokens"
    assert items[1].spec.forProvider.member == "user:alice@example.com", "member carried"
    assert items[1].spec.forProvider.serviceAccountIdSelector.matchControllerRef == True, "trust binds to the composed service account"
    assert items[2].spec.forProvider.member == "principal://iam.googleapis.com/x", "workload-identity members pass through"
}

# ---- render: grants (access control) ----------------------------------------

# The member string only exists once the SA is observed: no grants on pass one.
test_grants_wait_for_observation = lambda {
    items = iam.render(_build({accessPolicies = [{role = "roles/storage.objectViewer"}]}), {})
    assert len(items) == 1, "grants must not render before the service account is observed"
}

test_grants_observed = lambda {
    items = iam.render(_build({accessPolicies = [
        {role = "roles/storage.objectViewer"}
        {role = "roles/storage.objectAdmin", scope = "my-other-project"}
    ]}), _observed)
    assert len(items) == 3, "one ProjectIAMMember per grant once observed"
    assert items[1].kind == "ProjectIAMMember", "grants are project IAM members"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    assert items[1].spec.forProvider.role == "roles/storage.objectViewer", "role carried"
    assert items[1].spec.forProvider.member == "serviceAccount:demo@my-project.iam.gserviceaccount.com", "member is the observed service account"
    assert items[1].spec.forProvider?.project == Undefined, "no scope -> ProviderConfig project"
    assert items[2].spec.forProvider.project == "my-other-project", "scope -> project"
}

test_grant_condition = lambda {
    _g = {
        role = "roles/storage.objectAdmin"
        condition = {expression = "resource.name.startsWith(\"x\")", description = "artifacts only"}
    }
    items = iam.render(_build({accessPolicies = [_g]}), _observed)
    cond = items[1].spec.forProvider.condition
    assert cond.expression == "resource.name.startsWith(\"x\")", "condition expression carried"
    assert cond.title == "demo-grant-0", "the GCP API requires a title; defaulted per grant"
    assert cond.description == "artifacts only", "condition description carried"
    _titled = iam.render(_build({accessPolicies = [_g | {condition.title = "mine"}]}), _observed)
    assert _titled[1].spec.forProvider.condition.title == "mine", "explicit title wins"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = iam.render(_build({deletionPolicy = "Orphan", accessPolicies = [{role = "roles/viewer"}]}), _observed)
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the service account"
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
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status?.email == Undefined, "no email before the service account exists"
}

test_status_observed = lambda {
    dxr = iam.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed email must mark the identity ready"
    assert dxr.status.email == "demo@my-project.iam.gserviceaccount.com", "email must be surfaced"
    assert dxr.status.principal == "serviceAccount:demo@my-project.iam.gserviceaccount.com", "principal is the IAM member string"
    assert dxr.status.id == "projects/my-project/serviceAccounts/demo@my-project.iam.gserviceaccount.com", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/iam-admin/serviceaccounts/details/12345?project=my-project", "cloud-url must point at the service account"
}
