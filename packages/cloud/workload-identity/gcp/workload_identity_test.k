import .workload_identity as wi

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "WorkloadIdentity"
        metadata = {name = "demo", namespace = "apps"}
        spec = _spec | {serviceAccount = _spec?.serviceAccount or {name = "demo-sa"}, cluster = _spec?.cluster or {project = "my-project"}}
    }
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
    items = wi.render(_build({}), {})
    assert len(items) == 2, "a minimal spec must emit the service account and the binding"
    assert items[0].kind == "ServiceAccount", "the identity comes first"
    assert items[0].apiVersion == "cloudplatform.gcp.m.upbound.io/v1beta1", "the identity is a GCP service account, not the Kubernetes one"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "accountId defaults to the XR name"
    assert items[1].kind == "ServiceAccountIAMMember", "the binding is a service-account IAM member"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "binding", "the binding is named"
    assert items[1].spec.forProvider.role == "roles/iam.workloadIdentityUser", "GKE workload identity impersonates via workloadIdentityUser"
    assert items[1].spec.forProvider.member == "serviceAccount:my-project.svc.id.goog[apps/demo-sa]", "the member is the KSA in the project's pool"
    assert items[1].spec.forProvider.serviceAccountIdSelector.matchControllerRef == True, "the binding targets the composed service account"
}

test_identity_name_and_display_name = lambda {
    items = wi.render(_build({displayName = "Crossplane Controller", identity.name = "crossplane-controller"}), {})
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "crossplane-controller", "identity.name pins the accountId"
    assert items[0].spec.forProvider.displayName == "Crossplane Controller", "displayName carried"
}

test_pool_override = lambda {
    items = wi.render(_build({
        cluster = {workloadIdentityPool = "fleet-host.svc.id.goog"}
    }), {})
    assert items[1].spec.forProvider.member == "serviceAccount:fleet-host.svc.id.goog[apps/demo-sa]", "an explicit pool wins over cluster.project"
}

test_service_account_namespace_default = lambda {
    items = wi.render(_build({
        serviceAccount = {name = "external-secrets", namespace = "apps"}
    }), {})
    assert items[1].spec.forProvider.member == "serviceAccount:my-project.svc.id.goog[apps/external-secrets]", "an explicit namespace is carried into the member"
}

# ---- render: existing identity ----------------------------------------------
test_existing_identity = lambda {
    items = wi.render(_build({identity.existing = "shared@my-project.iam.gserviceaccount.com"}), {})
    assert len(items) == 2, "an existing identity is not created; the binding and the KSA are"
    assert items[0].kind == "ServiceAccountIAMMember", "no service account is composed"
    assert items[0].spec.forProvider.serviceAccountId == "projects/-/serviceAccounts/shared@my-project.iam.gserviceaccount.com", "an existing identity is addressed by its fully-qualified name"
    assert items[0].spec.forProvider?.serviceAccountIdSelector == Undefined, "there is no composed service account to select"
    assert items[1].kind == "ServiceAccount", "the Kubernetes ServiceAccount needs no observation when the e-mail is given"
    assert items[1].apiVersion == "v1", "that one is the core Kubernetes ServiceAccount"
    assert items[1].metadata.annotations["iam.gke.io/gcp-service-account"] == "shared@my-project.iam.gserviceaccount.com", "the annotation points at the existing identity"
}

# ---- render: grants ---------------------------------------------------------

# The member string only exists once the SA is observed: no grants on pass one.
test_grants_wait_for_observation = lambda {
    items = wi.render(_build({accessPolicies = [{role = "roles/secretmanager.secretAccessor"}]}), {})
    assert len(items) == 2, "grants must not render before the service account is observed"
}

test_grants_by_scope_type = lambda {
    items = wi.render(_build({accessPolicies = [
        {role = "roles/secretmanager.secretAccessor"}
        {role = "roles/dns.admin", scope = "dns-project"}
        {role = "roles/viewer", scope = "1234567890", scopeType = "folder"}
        {role = "roles/browser", scope = "9876543210", scopeType = "organization"}
    ]}), _observed)
    # 2 base + 4 grants + the Kubernetes ServiceAccount
    assert len(items) == 7, "one IAM member per grant, plus the annotated ServiceAccount"
    assert items[2].kind == "ProjectIAMMember", "project is the default scope level"
    assert items[2].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    assert items[2].spec.forProvider.member == "serviceAccount:demo@my-project.iam.gserviceaccount.com", "grants use the observed service account"
    assert items[2].spec.forProvider?.project == Undefined, "no scope -> ProviderConfig project"
    assert items[3].spec.forProvider.project == "dns-project", "scope -> project"
    assert items[4].kind == "FolderIAMMember", "scopeType folder -> folder IAM member"
    assert items[4].spec.forProvider.folder == "1234567890", "the folder id is the scope"
    assert items[5].kind == "OrganizationIAMMember", "scopeType organization -> organization IAM member"
    assert items[5].spec.forProvider.orgId == "9876543210", "the organization id is the scope"
}

test_grant_condition = lambda {
    _g = {
        role = "roles/storage.objectAdmin"
        condition = {expression = "resource.name.startsWith(\"x\")", description = "artifacts only"}
    }
    items = wi.render(_build({accessPolicies = [_g]}), _observed)
    cond = items[2].spec.forProvider.condition
    assert cond.expression == "resource.name.startsWith(\"x\")", "condition expression carried"
    assert cond.title == "demo-grant-0", "the GCP API requires a title; defaulted per grant"
    assert cond.description == "artifacts only", "condition description carried"
    _titled = wi.render(_build({accessPolicies = [_g | {condition.title = "mine"}]}), _observed)
    assert _titled[2].spec.forProvider.condition.title == "mine", "explicit title wins"
}

# ---- render: the Kubernetes ServiceAccount ----------------------------------
test_kubernetes_service_account = lambda {
    items = wi.render(_build({}), _observed)
    assert len(items) == 3, "the annotated ServiceAccount appears once the identity is observed"
    ksa = items[2]
    assert ksa.apiVersion == "v1" and ksa.kind == "ServiceAccount", "core Kubernetes ServiceAccount"
    assert ksa.metadata.name == "demo-sa", "named after spec.serviceAccount.name"
    assert ksa.metadata.namespace == "apps", "composed into the XR's namespace"
    assert ksa.metadata.annotations["iam.gke.io/gcp-service-account"] == "demo@my-project.iam.gserviceaccount.com", "GKE reads the impersonation target off this annotation"
    assert ksa.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "kubernetes-serviceaccount", "composed resources are named"
}

test_service_account_not_created = lambda {
    items = wi.render(_build({
        serviceAccount = {name = "demo-sa", create = False}
    }), _observed)
    assert len(items) == 2, "create=false must leave the ServiceAccount to its owner"
    assert items[1].spec.forProvider.member == "serviceAccount:my-project.svc.id.goog[apps/demo-sa]", "the binding is still made"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = wi.render(_build({deletionPolicy = "Orphan", accessPolicies = [{role = "roles/viewer"}]}), _observed)
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the service account"
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
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.serviceAccount == "apps/demo-sa", "the bound KSA is reported before creation"
    assert dxr.status.subject == "serviceAccount:my-project.svc.id.goog[apps/demo-sa]", "the trusted subject is known before creation"
    assert dxr.status?.email == Undefined, "no email before the service account exists"
}

test_status_observed = lambda {
    dxr = wi.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed email must mark the binding ready"
    assert dxr.status.email == "demo@my-project.iam.gserviceaccount.com", "email must be surfaced"
    assert dxr.status.annotation == "demo@my-project.iam.gserviceaccount.com", "the annotation value is the e-mail"
    assert dxr.status.principal == "serviceAccount:demo@my-project.iam.gserviceaccount.com", "principal is the IAM member string"
    assert dxr.status.id == "projects/my-project/serviceAccounts/demo@my-project.iam.gserviceaccount.com", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/iam-admin/serviceaccounts/details/12345?project=my-project", "cloud-url must point at the service account"
}

test_status_existing_identity = lambda {
    dxr = wi.status(_build({identity.existing = "shared@my-project.iam.gserviceaccount.com"}), {})
    assert dxr.status.ready == True, "an existing identity is ready immediately"
    assert dxr.status.annotation == "shared@my-project.iam.gserviceaccount.com", "the annotation is the existing e-mail"
}
