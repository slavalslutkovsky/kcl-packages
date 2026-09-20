import json
import .organization

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` / `ocds`
# parameters — KCL normalizes the leading underscore, so a helper named `_ocds`
# shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Organization", metadata.name = "demo", spec = _spec}
}

# render() needs the observed composed resources: placement on AWS is a second
# pass, so every test says explicitly what has been observed so far.
_render = lambda _spec, seen {
    organization.render(_build(_spec), seen)
}

# The composed resource carrying a given composition-resource-name.
_named = lambda items, name: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name][0]
}

_names = lambda items {
    [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in items]
}

_kinds = lambda items, kind: str {
    [i for i in items if i.kind == kind]
}

# One observed composed resource, in the shape function-kcl passes as ocds.
_seen = lambda res: str, at {
    {
        "${res}" = {Resource.status.atProvider = at}
    }
}

# ---- render: the organizational-unit tree -----------------------------------

# A folder with no parent hangs off the Organizations root, by literal id —
# there is nothing composed to reference.
test_root_ou_parents_the_root = lambda {
    items = _render({orgId = "r-abc1", folders = [{name = "platform"}]}, {})
    assert len(items) == 1, "one folder must render exactly one OrganizationalUnit"
    f = items[0]
    assert f.apiVersion == "organizations.aws.m.upbound.io/v1beta1" and f.kind == "OrganizationalUnit"
    assert _names(items) == ["folder-platform"]
    assert f.spec.forProvider.parentId == "r-abc1", "a top-level OU parents the Organizations root id"
    assert f.spec.forProvider.name == "platform", "the OU name defaults to the folder key"
    assert f.metadata.labels[organization.folder_label] == "platform", "every OU carries its key as a label"
    assert f.spec.forProvider?.tags == Undefined, "no tags unless spec.tags asks for them"
    assert f.metadata.annotations?["crossplane.io/external-name"] == Undefined, "the OU id is assigned by AWS, so there is nothing to pin"
}

# THE SECOND PASS. parentId carries no reference in the generated schema, so a
# nested OU cannot be emitted before its parent's id is observed: rendering it
# now would create the OU under the root, and AWS does not re-parent on update.
# Declaring the child before the parent also proves order is irrelevant.
test_nested_ou_waits_for_its_parent = lambda {
    spec = {orgId = "r-abc1", folders = [
        {name = "prod", parent = "workloads", displayName = "Production"}
        {name = "workloads"}
    ]}
    first = _render(spec, {})
    assert _names(first) == ["folder-workloads"], "a child OU must not be emitted with a guessed parent; only the root-level node renders on the first pass"

    second = _render(spec, _seen("folder-workloads", {id = "ou-abc1-111111"}))
    assert _names(second) == ["folder-prod", "folder-workloads"], "once the parent's id is observed the child appears, in spec order"
    child = _named(second, "folder-prod")
    assert child.spec.forProvider.parentId == "ou-abc1-111111", "the child parents the OBSERVED parent OU id"
    assert child.spec.forProvider.name == "Production", "displayName is the OU name in the console"
}

# The depth walk is what rejects a cycle; it returns -1 instead of looping.
test_folder_depth_detects_cycles_and_overnesting = lambda {
    chain = {a = "", b = "a", c = "b"}
    assert organization.folder_depth("a", chain, 5) == 0, "a root-level OU is at depth 0"
    assert organization.folder_depth("c", chain, 5) == 2, "depth counts hops to the root"
    cycle = {x = "y", y = "x"}
    assert organization.folder_depth("x", cycle, 5) == -1, "a cycle must be reported, not walked"
    assert organization.folder_depth("c", chain, 1) == -1, "a chain longer than AWS allows must be reported"
    assert organization.max_folder_depth == 5, "AWS allows five organizational-unit levels beneath the root"
}

# ---- render: accounts -------------------------------------------------------

# An account in an OU waits for that OU exactly as a child OU does.
test_account_waits_for_its_ou_then_lands_in_it = lambda {
    spec = {
        orgId = "r-abc1"
        owner = "aws-accounts@example.com"
        folders = [{name = "platform"}]
        projects = [{name = "platform-prod", displayName = "Platform Prod", folder = "platform"}]
    }
    assert _kinds(_render(spec, {}), "Account") == [], "an account whose OU has no observed id must not be created under the root instead"

    items = _render(spec, _seen("folder-platform", {id = "ou-abc1-222222"}))
    a = _named(items, "project-platform-prod")
    fp = a.spec.forProvider
    assert a.kind == "Account"
    assert fp.parentId == "ou-abc1-222222", "the account lands in the observed OU"
    assert fp.name == "Platform Prod", "displayName is the account name shown in Organizations"
    assert fp.email == "aws-accounts@example.com", "an account without its own owner inherits spec.owner"
    assert fp.closeOnDeletion == True, "whenDeleted defaults to delete, which closes the account"
    assert fp?.tags == Undefined, "no tags unless spec.tags or labels ask for them"
    assert fp?.createGovcloud == Undefined and fp?.iamUserAccessToBilling == Undefined, "neither is in this API, and changing either re-creates the account"
}

test_account_at_root_needs_no_second_pass = lambda {
    items = _render({
        orgId = "r-abc1"
        owner = "aws-accounts@example.com"
        projects = [{name = "sandbox-acct", owner = "sandbox-root@example.com"}]
    }, {})
    fp = _named(items, "project-sandbox-acct").spec.forProvider
    assert fp.parentId == "r-abc1", "an account with no folder sits directly under the root, so it waits for nothing"
    assert fp.email == "sandbox-root@example.com", "the account's own owner wins over spec.owner"
}

# delete closes the account; prevent and abandon leave it in the organization.
# AWS cannot refuse the removal of the managed resource — it can only decline to
# close the account.
test_close_on_deletion_per_when_deleted = lambda {
    _close = lambda when: str -> bool {
        _named(_render({
            orgId = "r-abc1"
            owner = "a@example.com"
            projects = [{name = "some-acct", whenDeleted = when}]
        }, {}), "project-some-acct").spec.forProvider.closeOnDeletion
    }
    assert _close("delete") == True, "delete closes the account"
    assert _close("prevent") == False, "prevent cannot block the deletion, so it declines to close"
    assert _close("abandon") == False, "abandon leaves the account in the organization"
}

# spec.tags reach the OU nodes and the accounts; an account's own labels win.
test_tags_reach_ou_and_account = lambda {
    items = _render({
        orgId = "r-abc1"
        owner = "a@example.com"
        tags = {"managed-by" = "crossplane", team = "platform"}
        folders = [{name = "platform"}]
        projects = [{name = "data-acct", labels = {team = "data", purpose = "data-platform"}}]
    }, {})
    assert _named(items, "folder-platform").spec.forProvider.tags == {"managed-by" = "crossplane", team = "platform"}, "OU tags are spec.tags verbatim"
    assert _named(items, "project-data-acct").spec.forProvider.tags == {"managed-by" = "crossplane", team = "data", purpose = "data-platform"}, "account labels override tags per key"
}

# ---- render: service control policies ---------------------------------------
test_deny_list_becomes_one_deny_statement = lambda {
    actions = ["cloudtrail:StopLogging", "organizations:LeaveOrganization"]
    items = _render({orgId = "r-abc1", policies = [{constraint = "deny-danger", deniedValues = actions}]}, {})
    p = _named(items, "policy-org-deny-danger")
    assert p.kind == "Policy"
    assert p.spec.forProvider.name == "deny-danger", "the constraint is the SCP name"
    assert p.spec.forProvider.$type == "SERVICE_CONTROL_POLICY", "a Policy whose type is left to the API is one field away from being a tag policy"
    assert p.metadata.annotations?["crossplane.io/external-name"] == Undefined, "the policy id is p-… and AWS assigns it, so nothing is pinned"
    doc = json.decode(p.spec.forProvider.content)
    assert doc.Version == "2012-10-17"
    assert len(doc.Statement) == 1, "a deny list is one statement"
    st = doc.Statement[0]
    assert st.Effect == "Deny" and st.Action == actions and st.Resource == "*", "the denied values are the statement's actions, on every resource"
    assert st?.NotAction == Undefined
}

# An allow list is inert on its own: AWS attaches its FullAWSAccess policy
# (Allow "*") to every root, OU and account, so the union of Allows is already
# everything. Denying what the list does not name is what makes it mean "only
# these actions".
test_allow_list_also_denies_everything_else = lambda {
    actions = ["s3:*", "ec2:Describe*"]
    p = _named(_render({orgId = "r-abc1", policies = [{constraint = "allow-only", allowedValues = actions}]}, {}), "policy-org-allow-only")
    doc = json.decode(p.spec.forProvider.content)
    assert [s.Effect for s in doc.Statement] == ["Allow", "Deny"], "an allow list emits the Allow and the Deny that makes it bite"
    assert doc.Statement[0].Action == actions and doc.Statement[0].Resource == "*"
    assert doc.Statement[1].NotAction == actions, "everything outside the list is denied"
    assert doc.Statement[1]?.Action == Undefined, "the guard statement is a NotAction, not an Action"
    assert isunique([s.Sid for s in doc.Statement]), "statement ids must be unique within one policy document"
}

# Both lists on one entry: the allow list decides what gets through, the deny
# list then subtracts from it.
test_both_lists_emit_all_three_statements = lambda {
    p = _named(_render({orgId = "r-abc1", policies = [
        {constraint = "s3-narrow", allowedValues = ["s3:*"], deniedValues = ["s3:DeleteBucket"]}
    ]}, {}), "policy-org-s3-narrow")
    doc = json.decode(p.spec.forProvider.content)
    assert [s.Effect for s in doc.Statement] == ["Allow", "Deny", "Deny"]
    assert doc.Statement[2].Action == ["s3:DeleteBucket"], "the deny list still applies inside what the allow list permits"
}

# The attachment is the half that needs a target, and with more than one Policy
# in the XR it must name its own by label — matchControllerRef alone is
# ambiguous and Crossplane then refuses to resolve either.
test_attachment_target_and_policy_binding = lambda {
    spec = {orgId = "r-abc1", folders = [{name = "sandbox"}], policies = [
        {constraint = "org-wide", deniedValues = ["iam:CreateUser"]}
        {constraint = "sandbox-only", folder = "sandbox", deniedValues = ["ec2:PurchaseReservedInstancesOffering"]}
    ]}
    first = _render(spec, {})
    assert _names(first) == [
        "folder-sandbox"
        "policy-org-org-wide"
        "policy-folder-sandbox-sandbox-only"
        "attachment-org-org-wide"
    ], "both policy documents exist at once; only the folder-scoped attachment waits for the OU id"

    root = _named(first, "attachment-org-org-wide")
    assert root.kind == "PolicyAttachment"
    assert root.spec.forProvider.targetId == "r-abc1", "a root-scoped policy attaches to the Organizations root"
    sel = root.spec.forProvider.policyIdSelector
    assert sel.matchControllerRef == True, "the selector must stay inside this XR"
    assert sel.matchLabels[organization.policy_label] == "org-org-wide", "and it must pick out one Policy of several"
    assert _named(first, "policy-org-org-wide").metadata.labels[organization.policy_label] == "org-org-wide", "the Policy carries the label the attachment selects on"

    second = _render(spec, _seen("folder-sandbox", {id = "ou-abc1-333333"}))
    fld = _named(second, "attachment-folder-sandbox-sandbox-only")
    assert fld.spec.forProvider.targetId == "ou-abc1-333333", "a folder-scoped policy attaches to the observed OU, never to the root"
    assert fld.spec.forProvider.policyIdSelector.matchLabels[organization.policy_label] == "folder-sandbox-sandbox-only", "scope is part of the label, so the same SCP name at two scopes stays two policies"
}

# The same constraint at two scopes is two policies and two attachments, and
# their composed names must differ or one would overwrite the other.
test_same_constraint_at_two_scopes = lambda {
    items = _render({orgId = "r-abc1", folders = [{name = "sandbox"}], policies = [
        {constraint = "region-lock", deniedValues = ["ec2:RunInstances"]}
        {constraint = "region-lock", folder = "sandbox", deniedValues = ["ec2:RunInstances"]}
    ]}, _seen("folder-sandbox", {id = "ou-abc1-444444"}))
    assert isunique(_names(items)), "scope is part of every composed name"
    assert _names(_kinds(items, "Policy")) == ["policy-org-region-lock", "policy-folder-sandbox-region-lock"]
    assert _names(_kinds(items, "PolicyAttachment")) == ["attachment-org-region-lock", "attachment-folder-sandbox-region-lock"]
}

# ---- render: the tree, once everything is observed --------------------------

# Orphan must reach EVERY composed object; one resource left on Delete would
# still schedule an OU for deletion or close an account.
test_orphan_reaches_every_resource = lambda {
    items = _render({
        orgId = "r-abc1"
        owner = "a@example.com"
        deletionPolicy = "Orphan"
        folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]
        projects = [{name = "platform-prod", folder = "prod"}]
        policies = [
            {constraint = "org-wide", deniedValues = ["iam:CreateUser"]}
            {constraint = "prod-only", folder = "prod", deniedValues = ["ec2:TerminateInstances"]}
        ]
    }, {
        "folder-workloads" = {
            Resource.status.atProvider = {id = "ou-abc1-111111"}
        }
        "folder-prod" = {
            Resource.status.atProvider = {id = "ou-abc1-222222"}
        }
    })
    assert _names(items) == [
        "folder-workloads"
        "folder-prod"
        "project-platform-prod"
        "policy-org-org-wide"
        "policy-folder-prod-prod-only"
        "attachment-org-org-wide"
        "attachment-folder-prod-prod-only"
    ], "with both OU ids observed the whole tree renders: 2 OUs, the account, 2 policies and both attachments"
    assert all i in items {i.spec.managementPolicies == _orphan}, "Orphan must reach every composed resource"
}

test_delete_leaves_management_policies_to_the_provider = lambda {
    items = _render({orgId = "r-abc1", folders = [{name = "platform"}]}, {})
    assert items[0].spec?.managementPolicies == ["*"], "Delete sets nothing; the provider default applies"
}

# ---- status -----------------------------------------------------------------
test_status_before_observation = lambda {
    xr = _build({
        orgId = "r-abc1"
        owner = "a@example.com"
        folders = [{name = "workloads"}]
        projects = [{name = "platform-prod", folder = "workloads"}]
        policies = [{constraint = "org-wide", deniedValues = ["iam:CreateUser"]}]
    })
    s = organization.status(xr, {}).status
    assert s.provider == "aws"
    assert s.ready == False, "nothing is numbered yet, so the tree is not complete"
    assert s.id == "r-abc1", "the hierarchy root is the Organizations root id"
    assert s.folders == [{name = "workloads", folderId = "", parent = ""}]
    assert s.projects == [{name = "platform-prod", projectId = "", number = ""}], "unlike GCP, nothing in the spec predicts an AWS account id"
    assert s.folderCount == 1 and s.projectCount == 1 and s.policyCount == 1
    assert s["cloud-url"] == "https://us-east-1.console.aws.amazon.com/organizations/v2/home/accounts"
}

test_status_after_observation = lambda {
    xr = _build({
        orgId = "r-abc1"
        owner = "a@example.com"
        folders = [{name = "workloads"}]
        projects = [{name = "platform-prod", folder = "workloads"}]
    })
    s = organization.status(xr, {
        "folder-workloads" = {
            Resource.status.atProvider = {id = "ou-abc1-111111", parentId = "r-abc1"}
        }
        "project-platform-prod" = {
            Resource.status.atProvider = {id = "123456789012", parentId = "ou-abc1-111111"}
        }
    }).status
    assert s.ready == True, "the tree is complete once every OU and every account is numbered"
    assert s.folders == [{name = "workloads", folderId = "ou-abc1-111111", parent = "r-abc1"}]
    assert s.projects == [{name = "platform-prod", projectId = "123456789012", number = ""}], "the 12-digit account id is the only identifier AWS has, so number stays empty"
}

# A half-built hierarchy is not ready, however many pieces already exist — which
# is also how the XR says a second pass is still outstanding.
test_status_partial_observation_is_not_ready = lambda {
    xr = _build({
        orgId = "r-abc1"
        owner = "a@example.com"
        folders = [{name = "workloads"}, {name = "prod", parent = "workloads"}]
    })
    s = organization.status(xr, {
        "folder-workloads" = {
            Resource.status.atProvider = {id = "ou-abc1-111111", parentId = "r-abc1"}
        }
    }).status
    assert s.ready == False, "the nested OU has not been created yet, so the tree is incomplete"
    assert s.folders[1].folderId == "" and s.folders[1].parent == ""
}
