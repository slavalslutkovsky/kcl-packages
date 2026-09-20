import .organization

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# A tenant id, which is what the root management group is named after.
_tenant = "72f988bf-86f1-41af-91ab-2d7cd011db47"
_root = "/providers/Microsoft.Management/managementGroups/${_tenant}"

# Object ids: what an Azure role assignment grants to.
_group_oid = "11111111-2222-3333-4444-555555555555"
_sp_oid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

# Built-in policy definition: "Audit VMs that do not use managed disks".
_managed_disks = "06a78e20-9358-41c9-923c-fb736d382a4d"

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

# ---- render: the management-group tree --------------------------------------

# A folder with no parent hangs off spec.orgId by literal ARM id — the root is
# not a composed resource, so there is nothing to reference.
test_root_management_group = lambda {
    items = _render({orgId = _tenant, folders = [{name = "platform"}]})
    assert len(items) == 1, "one folder must render exactly one ManagementGroup"
    mg = items[0]
    assert mg.apiVersion == "management.azure.m.upbound.io/v1beta1" and mg.kind == "ManagementGroup"
    assert mg.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "folder-platform"
    assert mg.spec.forProvider.parentManagementGroupId == _root, "a top-level group parents the root management group"
    assert mg.spec.forProvider?.parentManagementGroupIdSelector == Undefined, "nothing to select: the root is not composed here"
    assert mg.spec.forProvider.displayName == "platform", "displayName defaults to the folder key"
}

# The management group's NAME is its external-name, and it is the folder key:
# that is what makes every ARM id in the tree computable ahead of creation.
test_external_name_is_pinned_to_the_key = lambda {
    items = _render({orgId = _tenant, folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]})
    assert _named(items, "folder-workloads").metadata.annotations["crossplane.io/external-name"] == "workloads"
    assert _named(items, "folder-prod").metadata.annotations["crossplane.io/external-name"] == "prod", "a nested group is named by its key too, not by its path"
    assert organization.mg_id("prod") == "/providers/Microsoft.Management/managementGroups/prod", "the pinned name is the id's last segment"
}

# A nested group binds its parent by the label this module stamps, which is
# also what makes the child wait for the parent instead of racing it.
test_nested_management_group_binds_parent_by_label = lambda {
    items = _render({orgId = _tenant, folders = [
        {name = "workloads"}
        {name = "prod", parent = "workloads", displayName = "Production"}
    ]})
    parent = _named(items, "folder-workloads")
    child = _named(items, "folder-prod")
    assert parent.metadata.labels[organization.folder_label] == "workloads", "every group carries its key as a label"
    sel = child.spec.forProvider.parentManagementGroupIdSelector
    assert sel.matchControllerRef == True, "the selector must stay inside this XR"
    assert sel.matchLabels[organization.folder_label] == "workloads", "the child selects the parent by its key"
    assert child.spec.forProvider?.parentManagementGroupId == Undefined, "a nested group has no literal parent id"
    assert child.spec.forProvider.displayName == "Production"
}

# Folder order in the spec is irrelevant: the parent may be declared after the
# child, because the binding is a reference and not a position.
test_folder_order_is_irrelevant = lambda {
    items = _render({orgId = _tenant, folders = [
        {name = "prod", parent = "workloads"}
        {name = "workloads"}
    ]})
    assert _named(items, "folder-prod").spec.forProvider.parentManagementGroupIdSelector.matchLabels[organization.folder_label] == "workloads"
}

# The depth walk is what rejects a cycle; it returns -1 instead of looping.
# render() gives it max_folder_depth - 1 hops, because a group at the deepest
# level Azure allows is that many hops from the root.
test_folder_depth_detects_cycles_and_overnesting = lambda {
    chain = {a = "", b = "a", c = "b"}
    assert organization.folder_depth("a", chain, 5) == 0, "a top-level group is at distance 0 from the root"
    assert organization.folder_depth("c", chain, 5) == 2, "distance counts hops to the root management group"
    cycle = {x = "y", y = "x"}
    assert organization.folder_depth("x", cycle, 5) == -1, "a cycle must be reported, not walked"
    assert organization.max_folder_depth == 6, "Azure nests six management-group levels below the root"

    # Six levels fit; the seventh does not.
    deep = {l1 = "", l2 = "l1", l3 = "l2", l4 = "l3", l5 = "l4", l6 = "l5", l7 = "l6"}
    budget = organization.max_folder_depth - 1
    assert organization.folder_depth("l6", deep, budget) == 5, "the sixth level is the deepest Azure accepts"
    assert organization.folder_depth("l7", deep, budget) == -1, "a seventh level must be reported, not sent to the API"
}

# ---- render: policy assignments ---------------------------------------------

# A bare constraint is a built-in definition name and is expanded; a full path
# is passed through untouched.
test_definition_id_expansion = lambda {
    items = _render({orgId = _tenant, policies = [
        {constraint = _managed_disks}
        {constraint = "/providers/Microsoft.Management/managementGroups/${_tenant}/providers/Microsoft.Authorization/policyDefinitions/require-costcentre"}
    ]})
    bare = _named(items, "policy-org-06a78e20-9358-41c9-923c-fb736d382a4d")
    full = _named(items, "policy-org--providers-microsoft-management-managementgroups-72f988bf-86f1-41af-91ab-2d7cd011db47-providers-microsoft-authorization-policydefinitions-require-costcentre")
    assert bare.apiVersion == "authorization.azure.m.upbound.io/v1beta1" and bare.kind == "ManagementGroupPolicyAssignment"
    assert bare.spec.forProvider.policyDefinitionId == "/providers/Microsoft.Authorization/policyDefinitions/${_managed_disks}", "a bare name is a built-in definition, at the tenant-level definition scope"
    assert full.spec.forProvider.policyDefinitionId == "/providers/Microsoft.Management/managementGroups/${_tenant}/providers/Microsoft.Authorization/policyDefinitions/require-costcentre", "a path is already an id and must not be rewritten"
}

# The assignment name is its external-name, and Azure caps it at 24 characters
# at management-group scope — a 36-character built-in GUID has to be cut.
test_assignment_name_is_derived_and_truncated = lambda {
    assert organization.assignment_name(_managed_disks) == "06a78e20-9358-41c9-923c", "a GUID is cut to 24 characters and the trailing hyphen dropped"
    assert len(organization.assignment_name(_managed_disks)) <= organization.max_assignment_name
    assert organization.assignment_name("/providers/Microsoft.Authorization/policyDefinitions/require-tls") == "require-tls", "the name comes from the definition's last segment, never from the whole path"
    p = _named(_render({orgId = _tenant, policies = [{constraint = _managed_disks}]}), "policy-org-06a78e20-9358-41c9-923c-fb736d382a4d")
    assert p.metadata.annotations["crossplane.io/external-name"] == "06a78e20-9358-41c9-923c", "the assignment's name is pinned; the schema has no name field to put it in"
}

# Root scope is the literal root id; a folder-scoped assignment references the
# composed management group, so it also waits for it.
test_policy_assignment_scope = lambda {
    items = _render({orgId = _tenant, folders = [{name = "sandbox"}], policies = [
        {constraint = _managed_disks}
        {constraint = _managed_disks, folder = "sandbox"}
    ]})
    org = _named(items, "policy-org-06a78e20-9358-41c9-923c-fb736d382a4d")
    fld = _named(items, "policy-folder-sandbox-06a78e20-9358-41c9-923c-fb736d382a4d")
    assert org.spec.forProvider.managementGroupId == _root
    assert org.spec.forProvider?.managementGroupIdSelector == Undefined
    assert fld.spec.forProvider.managementGroupIdSelector.matchControllerRef == True
    assert fld.spec.forProvider.managementGroupIdSelector.matchLabels[organization.folder_label] == "sandbox", "a folder-scoped assignment attaches to the composed group"
    assert fld.spec.forProvider?.managementGroupId == Undefined, "the reference is the scope; a literal id beside it would race the group"
    assert org.metadata.annotations["crossplane.io/external-name"] == fld.metadata.annotations["crossplane.io/external-name"], "the same definition keeps the same assignment name at both scopes — the scope is the other half of the id"
}

# enforce and dryRun both land on the one enforcement switch the assignment has.
test_enforcement_mapping = lambda {
    items = _render({orgId = _tenant, policies = [
        {constraint = "audit-managed-disks", enforce = True}
        {constraint = "audit-public-ip", enforce = False}
        {constraint = "audit-tls", dryRun = True}
        {constraint = "audit-sku"}
    ]})
    assert _named(items, "policy-org-audit-managed-disks").spec.forProvider.enforce == True
    assert _named(items, "policy-org-audit-public-ip").spec.forProvider.enforce == False, "enforce: false is audit-only, not an absent assignment"
    assert _named(items, "policy-org-audit-tls").spec.forProvider.enforce == False, "dryRun means DoNotEnforce — the way to introduce a guardrail on a populated tenant"
    assert _named(items, "policy-org-audit-sku").spec.forProvider.enforce == True, "an assignment with neither flag enforces, which is Azure's own default"
}

# ---- render: role assignments -----------------------------------------------
test_role_assignment_scope_and_role_selection = lambda {
    items = _render({orgId = _tenant, folders = [{name = "workloads"}], iamBindings = [
        {member = _group_oid, role = "Reader"}
        {member = _sp_oid, role = "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c", folder = "workloads"}
    ]})
    org = _named(items, "iam-org-reader-11111111-2222-3333-4444-555555555555")
    fld = _named(items, "iam-folder-workloads--providers-microsoft-authorization-roledefinitions-b24988ac-6180-42a0-ab88-20f7382dd24c-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    assert org.apiVersion == "authorization.azure.m.upbound.io/v1beta1" and org.kind == "RoleAssignment"
    assert org.spec.forProvider.scope == _root, "a root grant is scoped to the root management group"
    assert org.spec.forProvider.principalId == _group_oid, "the member is the object id, verbatim"
    assert org.spec.forProvider.roleDefinitionName == "Reader", "a bare role is a built-in role NAME"
    assert org.spec.forProvider?.roleDefinitionId == Undefined
    assert fld.spec.forProvider.scope == "/providers/Microsoft.Management/managementGroups/workloads", "a folder grant is scoped to the group id the pinned external-name makes computable"
    assert fld.spec.forProvider.roleDefinitionId == "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c", "a role starting with / is a definition id"
    assert fld.spec.forProvider?.roleDefinitionName == Undefined
    assert fld.metadata?.labels == Undefined, "only a management group carries the folder label — it is what gets selected"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach EVERY composed object; one resource left on Delete would
# still tear a management group out of the tree.
test_orphan_reaches_every_resource = lambda {
    items = _render({
        orgId = _tenant
        deletionPolicy = "Orphan"
        folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]
        policies = [{constraint = _managed_disks, folder = "prod"}]
        iamBindings = [{member = _group_oid, role = "Reader"}]
    })
    assert len(items) == 4, "two groups + assignment + grant"
    assert all i in items {i.spec.managementPolicies == _orphan}, "Orphan must reach every composed resource"
}

test_delete_leaves_management_policies_to_the_provider = lambda {
    items = _render({orgId = _tenant, folders = [{name = "platform"}]})
    assert items[0].spec?.managementPolicies == ["*"], "Delete sets nothing; the provider default applies"
}

# ---- status -----------------------------------------------------------------
test_status_before_observation = lambda {
    xr = _build({
        orgId = _tenant
        folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]
        policies = [{constraint = _managed_disks}]
    })
    s = organization.status(xr, {}).status
    assert s.provider == "azure"
    assert s.ready == False, "nothing has been observed yet"
    assert s.id == _root
    assert s.folders == [
        {name = "workloads", folderId = "workloads", parent = ""}
        {name = "prod", folderId = "prod", parent = ""}
    ], "the management-group name is the pinned key, so it is known before creation; the parent id is not"
    assert s.projects == [], "this backend composes no accounts"
    assert s.folderCount == 2 and s.projectCount == 0 and s.policyCount == 1
    assert s["cloud-url"] == "https://portal.azure.com/#view/Microsoft_Azure_ManagementGroups/ManagementGroupBrowseBlade/~/MGBrowse_overview"
}

test_status_after_observation = lambda {
    xr = _build({orgId = _tenant, folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]})
    ocds = {
        "folder-workloads" = {
            Resource.status.atProvider = {
                id = "/providers/Microsoft.Management/managementGroups/workloads"
                parentManagementGroupId = _root
            }
        }
        "folder-prod" = {
            Resource.status.atProvider = {
                id = "/providers/Microsoft.Management/managementGroups/prod"
                parentManagementGroupId = "/providers/Microsoft.Management/managementGroups/workloads"
            }
        }
    }
    s = organization.status(xr, ocds).status
    assert s.ready == True, "the hierarchy exists once Azure has answered for every group"
    assert s.folders == [
        {name = "workloads", folderId = "workloads", parent = _root}
        {name = "prod", folderId = "prod", parent = "/providers/Microsoft.Management/managementGroups/workloads"}
    ], "folderId is the group's own name, read back out of the observed ARM id"
}

# A half-built hierarchy is not ready, however many groups already exist — and
# readiness cannot be read off folderId, which is pinned and never empty.
test_status_partial_observation_is_not_ready = lambda {
    xr = _build({orgId = _tenant, folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]})
    s = organization.status(xr, {
        "folder-workloads" = {
            Resource.status.atProvider = {id = "/providers/Microsoft.Management/managementGroups/workloads"}
        }
    }).status
    assert s.ready == False, "one unobserved group must keep the XR unready"
    assert s.folders[1].folderId == "prod", "the pinned name is still reported"
    assert s.folders[1].parent == "", "but nothing is invented for what Azure has not said"
}
