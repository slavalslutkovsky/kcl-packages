import .organization

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Organization", metadata.name = "demo", spec = _spec}
}

_render = lambda _spec {
    organization.render(_build(_spec))
}

# The composed resource carrying a given composition-resource-name.
_named = lambda items, name: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name][0]
}

_kinds = lambda items, kind: str {
    [i for i in items if i.kind == kind]
}

# ---- render: folder tree ----------------------------------------------------

# A folder with no parent hangs off the organization itself, by literal name —
# there is nothing to reference.
test_root_folder_parents_the_org = lambda {
    items = _render({orgId = "477132171939", folders = [{name = "platform"}]})
    assert len(items) == 1, "one folder must render exactly one Folder"
    f = items[0]
    assert f.apiVersion == "cloudplatform.gcp.m.upbound.io/v1beta1" and f.kind == "Folder"
    assert f.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "folder-platform"
    assert f.spec.forProvider.parent == "organizations/477132171939", "a root folder parents the organization directly"
    assert f.spec.forProvider?.parentSelector == Undefined, "nothing to select: the organization is not a composed resource"
    assert f.spec.forProvider.displayName == "platform", "displayName defaults to the folder key"
    assert f.spec.forProvider.deletionProtection == False, "the XRD default is false, unlike GCP's own API default"
}

# A nested folder binds its parent by the label this module stamps, which is
# also what makes the child wait for the parent instead of racing it.
test_nested_folder_binds_parent_by_label = lambda {
    items = _render({orgId = "1", folders = [
        {name = "workloads"}
        {name = "prod", parent = "workloads", displayName = "Production", deletionProtection = True}
    ]})
    parent = _named(items, "folder-workloads")
    child = _named(items, "folder-prod")
    assert parent.metadata.labels[organization.folder_label] == "workloads", "every folder carries its key as a label"
    sel = child.spec.forProvider.parentSelector
    assert sel.matchControllerRef == True, "the selector must stay inside this XR"
    assert sel.matchLabels[organization.folder_label] == "workloads", "the child selects the parent by its key"
    assert child.spec.forProvider?.parent == Undefined, "a nested folder has no literal parent"
    assert child.spec.forProvider.displayName == "Production"
    assert child.spec.forProvider.deletionProtection == True
}

# Folder order in the spec is irrelevant: the parent may be declared after the
# child, because the binding is a reference and not a position.
test_folder_order_is_irrelevant = lambda {
    items = _render({orgId = "1", folders = [
        {name = "prod", parent = "workloads"}
        {name = "workloads"}
    ]})
    assert _named(items, "folder-prod").spec.forProvider.parentSelector.matchLabels[organization.folder_label] == "workloads"
}

# The depth walk is what rejects a cycle; it returns -1 instead of looping.
test_folder_depth_detects_cycles_and_overnesting = lambda {
    chain = {a = "", b = "a", c = "b"}
    assert organization.folder_depth("a", chain, 10) == 0, "a root folder is at depth 0"
    assert organization.folder_depth("c", chain, 10) == 2, "depth counts hops to the organization"
    cycle = {x = "y", y = "x"}
    assert organization.folder_depth("x", cycle, 10) == -1, "a cycle must be reported, not walked"
    assert organization.folder_depth("c", chain, 1) == -1, "a chain longer than GCP allows must be reported"
    assert organization.max_folder_depth == 10, "GCP allows ten folder levels beneath an organization"
}

# ---- render: projects and their APIs ---------------------------------------
test_project_defaults_and_placement = lambda {
    items = _render({
        orgId = "1"
        billingAccount = "012345-6789AB-CDEF01"
        folders = [{name = "platform"}]
        projects = [{name = "yk-admin-gke", displayName = "Admin GKE", folder = "platform"}]
    })
    p = _named(items, "project-yk-admin-gke")
    fp = p.spec.forProvider
    assert p.kind == "Project"
    assert fp.projectId == "yk-admin-gke", "the spec key is the project id"
    assert fp.name == "Admin GKE"
    assert fp.billingAccount == "012345-6789AB-CDEF01", "a project inherits the org-level billing account"
    assert fp.autoCreateNetwork == False, "the legacy default VPC is not kept"
    assert fp.deletionPolicy == "DELETE", "whenDeleted defaults to delete, not GCP's PREVENT"
    assert fp.folderIdSelector.matchLabels[organization.folder_label] == "platform", "the project binds its folder by key"
    assert fp?.orgId == Undefined, "a project in a folder must not also name the organization"
    assert fp?.labels == Undefined, "no labels unless tags or labels are asked for"
}

test_project_at_org_root_and_billing_override = lambda {
    p = _named(_render({
        orgId = "42"
        billingAccount = "aaa"
        projects = [{name = "yk-sandbox", billingAccount = "bbb", whenDeleted = "prevent", autoCreateNetwork = True}]
    }), "project-yk-sandbox")
    fp = p.spec.forProvider
    assert fp.orgId == "42", "a project with no folder sits directly under the organization"
    assert fp?.folderIdSelector == Undefined
    assert fp.billingAccount == "bbb", "the project-level billing account wins"
    assert fp.deletionPolicy == "PREVENT", "whenDeleted maps to the GCP deletion policy"
    assert fp.autoCreateNetwork == True, "keeping the default network stays possible"
}

# spec.tags are project labels; the project's own labels win a collision.
test_project_labels_merge_tags = lambda {
    p = _named(_render({
        orgId = "1"
        billingAccount = "aaa"
        tags = {"managed-by" = "crossplane", team = "platform"}
        projects = [{name = "yk-data-platform", labels = {team = "data", purpose = "data-platform"}}]
    }), "project-yk-data-platform")
    assert p.spec.forProvider.labels == {"managed-by" = "crossplane", team = "data", purpose = "data-platform"}, "project labels override tags per key"
}

# One ProjectService per API, bound to the project by its literal id.
test_services_fan_out = lambda {
    items = _render({
        orgId = "1"
        billingAccount = "aaa"
        projects = [{name = "yk-admin-gke", services = ["container.googleapis.com", "compute.googleapis.com"]}]
    })
    svcs = _kinds(items, "ProjectService")
    assert len(svcs) == 2, "one ProjectService per enabled API"
    assert [s.metadata.annotations["krm.kcl.dev/composition-resource-name"] for s in svcs] == [
        "service-yk-admin-gke-container-googleapis-com"
        "service-yk-admin-gke-compute-googleapis-com"
    ], "the composed name is derived from project and API, and is stable"
    assert all s in svcs {s.spec.forProvider.project == "yk-admin-gke"}, "Service Usage takes the bare project id, never projects/<id>"
    assert all s in svcs {s.spec.forProvider.disableOnDestroy == False}, "dropping an API stops managing it; it does not disable it under a running workload"
}

# ---- render: organization policies ------------------------------------------
test_boolean_policy = lambda {
    items = _render({orgId = "7", policies = [{constraint = "compute.requireOsLogin", enforce = True}]})
    p = _named(items, "policy-org-compute-requireoslogin")
    assert p.apiVersion == "orgpolicy.gcp.m.upbound.io/v1beta1" and p.kind == "Policy"
    assert p.metadata.annotations["crossplane.io/external-name"] == "compute.requireOsLogin", "the policy name is the constraint it governs"
    assert p.spec.forProvider.parent == "organizations/7"
    rules = p.spec.forProvider.spec.rules
    assert len(rules) == 1 and rules[0].enforce == "TRUE", "boolean constraints carry the enforcement as a string"
    assert rules[0]?.values == Undefined and rules[0]?.allowAll == Undefined, "a boolean rule carries nothing else"
    assert p.spec.forProvider?.dryRunSpec == Undefined
}

test_boolean_policy_can_switch_enforcement_off = lambda {
    p = _named(_render({orgId = "7", policies = [{constraint = "compute.requireOsLogin", enforce = False}]}), "policy-org-compute-requireoslogin")
    assert p.spec.forProvider.spec.rules[0].enforce == "FALSE", "enforce=false is an explicit allow, not an absent rule"
}

test_list_policy_shapes = lambda {
    items = _render({orgId = "7", folders = [{name = "sandbox"}], policies = [
        {constraint = "compute.vmExternalIpAccess", denyAll = True}
        {constraint = "compute.vmExternalIpAccess", folder = "sandbox", allowAll = True}
        {constraint = "gcp.resourceLocations", allowedValues = ["in:eu-locations"], deniedValues = ["in:us-locations"], inheritFromParent = True}
    ]})
    deny = _named(items, "policy-org-compute-vmexternalipaccess")
    allow = _named(items, "policy-folder-sandbox-compute-vmexternalipaccess")
    values = _named(items, "policy-org-gcp-resourcelocations")
    assert deny.spec.forProvider.spec.rules[0].denyAll == "TRUE"
    assert allow.spec.forProvider.spec.rules[0].allowAll == "TRUE"
    assert allow.spec.forProvider.parentSelector.matchLabels[organization.folder_label] == "sandbox", "a folder-scoped policy attaches to the composed folder"
    assert allow.spec.forProvider?.parent == Undefined
    vrule = values.spec.forProvider.spec.rules[0]
    assert vrule.values.allowedValues == ["in:eu-locations"] and vrule.values.deniedValues == ["in:us-locations"]
    assert vrule?.enforce == Undefined, "a list rule must not also carry a boolean enforcement"
    assert values.spec.forProvider.spec.inheritFromParent == True, "list constraints may merge what is set above them"
}

# The same constraint at two scopes is two policies, and their composed names
# must differ or one would overwrite the other.
test_same_constraint_at_two_scopes = lambda {
    items = _render({orgId = "7", folders = [{name = "sandbox"}], policies = [
        {constraint = "compute.vmExternalIpAccess", denyAll = True}
        {constraint = "compute.vmExternalIpAccess", folder = "sandbox", allowAll = True}
    ]})
    names = [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in _kinds(items, "Policy")]
    assert isunique(names), "scope is part of the composed name"
    assert names == ["policy-org-compute-vmexternalipaccess", "policy-folder-sandbox-compute-vmexternalipaccess"]
}

test_dry_run_policy_blocks_nothing = lambda {
    p = _named(_render({orgId = "7", policies = [
        {constraint = "gcp.resourceLocations", allowedValues = ["in:eu-locations"], dryRun = True}
    ]}), "policy-org-gcp-resourcelocations")
    assert p.spec.forProvider.dryRunSpec.rules[0].values.allowedValues == ["in:eu-locations"], "a dry-run policy carries its rules in dryRunSpec"
    assert p.spec.forProvider?.spec == Undefined, "and nothing in the live spec, or it would enforce"
}

test_reset_policy_carries_no_rules = lambda {
    p = _named(_render({orgId = "7", folders = [{name = "sandbox"}], policies = [
        {constraint = "compute.requireOsLogin", folder = "sandbox", reset = True}
    ]}), "policy-folder-sandbox-compute-requireoslogin")
    assert p.spec.forProvider.spec.reset == True, "reset restores the constraint default"
    assert p.spec.forProvider.spec?.rules == Undefined, "and must carry no rules"
}

# ---- render: audit logging --------------------------------------------------
test_audit_logging_fans_out_per_service = lambda {
    items = _render({orgId = "7", auditLogging = {
        services = ["allServices", "storage.googleapis.com"]
        logTypes = ["DATA_READ", "DATA_WRITE"]
        exemptedMembers = ["serviceAccount:noisy@x.iam.gserviceaccount.com"]
    }})
    configs = _kinds(items, "OrganizationIAMAuditConfig")
    assert len(configs) == 2, "one audit config per service"
    all_services = _named(items, "audit-allservices")
    assert all_services.spec.forProvider.orgId == "7"
    assert all_services.spec.forProvider.service == "allServices"
    logs = all_services.spec.forProvider.auditLogConfig
    assert [c.logType for c in logs] == ["DATA_READ", "DATA_WRITE"], "one entry per requested log type"
    assert all c in logs {c.exemptedMembers == ["serviceAccount:noisy@x.iam.gserviceaccount.com"]}, "exempted members apply to every log type in the config"
    assert _named(items, "audit-storage-googleapis-com").spec.forProvider.service == "storage.googleapis.com"
}

# Omitting the block configures nothing — data-access logs are charged by
# volume, so they are never turned on implicitly.
test_no_audit_block_composes_nothing = lambda {
    items = _render({orgId = "7", folders = [{name = "platform"}]})
    assert len(_kinds(items, "OrganizationIAMAuditConfig")) == 0
}

# An empty block still means "audit", and falls back to the XRD defaults an
# unvalidated XR would not carry.
test_audit_block_defaults = lambda {
    items = _render({orgId = "7", auditLogging = {}})
    cfg = _named(items, "audit-allservices")
    assert [c.logType for c in cfg.spec.forProvider.auditLogConfig] == ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    assert all c in cfg.spec.forProvider.auditLogConfig {c?.exemptedMembers == Undefined}, "nobody is exempt unless asked for"
}

# ---- render: IAM ------------------------------------------------------------
test_iam_binding_scopes = lambda {
    items = _render({orgId = "7", folders = [{name = "workloads"}], iamBindings = [
        {member = "group:platform@example.com", role = "roles/resourcemanager.organizationViewer"}
        {member = "serviceAccount:cp@p.iam.gserviceaccount.com", role = "roles/resourcemanager.folderAdmin", folder = "workloads"}
    ]})
    org = _named(items, "iam-org-roles-resourcemanager-organizationviewer-group-platform-example-com")
    fld = _named(items, "iam-folder-workloads-roles-resourcemanager-folderadmin-serviceaccount-cp-p-iam-gserviceaccount-com")
    assert org.kind == "OrganizationIAMMember" and org.spec.forProvider.orgId == "7"
    assert org.spec.forProvider.member == "group:platform@example.com"
    assert fld.kind == "FolderIAMMember", "a folder-scoped grant is a different kind, not a different field"
    assert fld.spec.forProvider.folderSelector.matchLabels[organization.folder_label] == "workloads"
    assert fld.spec.forProvider.role == "roles/resourcemanager.folderAdmin", "a folder grant carries no organization id at all — the kind is the scope"
}

# The API rejects a condition without a title, so one is always sent.
test_iam_condition_title_defaults_to_the_role = lambda {
    items = _render({orgId = "7", iamBindings = [
        {member = "user:a@example.com", role = "roles/viewer", condition = {expression = "request.time < timestamp(\"2030-01-01T00:00:00Z\")"}}
        {member = "user:b@example.com", role = "roles/viewer", condition = {expression = "true", title = "always", description = "why"}}
    ]})
    a = _named(items, "iam-org-roles-viewer-user-a-example-com")
    b = _named(items, "iam-org-roles-viewer-user-b-example-com")
    assert a.spec.forProvider.condition.title == "roles/viewer condition", "a missing title must not fail the render"
    assert a.spec.forProvider.condition?.description == Undefined
    cond = b.spec.forProvider.condition
    assert cond.expression == "true" and cond.title == "always" and cond.description == "why", "an explicit condition is passed through verbatim"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach EVERY composed object; one resource left on Delete would
# still schedule a folder or a project for deletion.
test_orphan_reaches_every_resource = lambda {
    items = _render({
        orgId = "7"
        billingAccount = "aaa"
        deletionPolicy = "Orphan"
        folders = [{name = "platform"}]
        projects = [{name = "yk-admin-gke", folder = "platform", services = ["compute.googleapis.com"]}]
        policies = [{constraint = "compute.requireOsLogin", enforce = True}]
        auditLogging = {}
        iamBindings = [{member = "user:a@example.com", role = "roles/viewer"}]
    })
    assert len(items) == 6, "folder + project + service + policy + audit + binding"
    assert all i in items {i.spec.managementPolicies == _orphan}, "Orphan must reach every composed resource"
}

test_delete_leaves_management_policies_to_the_provider = lambda {
    items = _render({orgId = "7", folders = [{name = "platform"}]})
    assert items[0].spec?.managementPolicies == ["*"], "Delete sets nothing; the provider default applies"
}

# ---- status -----------------------------------------------------------------
test_status_before_observation = lambda {
    xr = _build({
        orgId = "7"
        billingAccount = "aaa"
        folders = [{name = "platform"}]
        projects = [{name = "yk-admin-gke", folder = "platform"}]
        policies = [{constraint = "compute.requireOsLogin", enforce = True}]
    })
    s = organization.status(xr, {}).status
    assert s.provider == "gcp"
    assert s.ready == False, "nothing is numbered yet"
    assert s.id == "organizations/7"
    assert s.folders == [{name = "platform", folderId = "", parent = ""}]
    assert s.projects == [{name = "yk-admin-gke", projectId = "yk-admin-gke", number = ""}], "the project id is known from the spec before creation"
    assert s.folderCount == 1 and s.projectCount == 1 and s.policyCount == 1
    assert s["cloud-url"] == "https://console.cloud.google.com/cloud-resource-manager?organizationId=7"
}

test_status_after_observation = lambda {
    xr = _build({
        orgId = "7"
        billingAccount = "aaa"
        folders = [{name = "platform"}]
        projects = [{name = "yk-admin-gke", folder = "platform"}]
    })
    ocds = {
        "folder-platform" = {
            Resource.status.atProvider = {folderId = "1234567890", parent = "organizations/7"}
        }
        "project-yk-admin-gke" = {
            Resource.status.atProvider = {projectId = "yk-admin-gke", number = "987654321"}
        }
    }
    s = organization.status(xr, ocds).status
    assert s.ready == True, "the hierarchy exists once every folder and project is numbered"
    assert s.folders == [{name = "platform", folderId = "1234567890", parent = "organizations/7"}]
    assert s.projects[0].number == "987654321", "the project number is what IAM principals refer to"
}

# A half-built hierarchy is not ready, however many pieces already exist.
test_status_partial_observation_is_not_ready = lambda {
    xr = _build({
        orgId = "7"
        billingAccount = "aaa"
        folders = [{name = "platform"}, {name = "data"}]
    })
    s = organization.status(xr, {
        "folder-platform" = {
            Resource.status.atProvider = {folderId = "1"}
        }
    }).status
    assert s.ready == False, "one folder still missing must keep the XR unready"
    assert s.folders[1].folderId == ""
}
