# organization (azure) — Crossplane Composition logic (function-kcl module).
# One Organization XR is the whole Azure management hierarchy: a ManagementGroup
# per folders[] entry (nested through parentManagementGroupIdSelector), a
# ManagementGroupPolicyAssignment per policies[] entry, and a RoleAssignment
# scoped to a management group per iamBindings[] entry.
#
# Azure is the thinnest of the three backends, and deliberately so. A management
# group is a naming and policy boundary and nothing else: it holds no accounts
# this module can create, carries no tags, and has no deletion-protection flag.
# Everything the XRD says azure cannot honour FAILS the render below rather than
# being dropped silently.
#
# Ignored on purpose, as the XRD documents field by field:
#   spec.billingAccount  a subscription is billed by the agreement it was bought
#                        under; this backend creates none, so there is nothing
#                        to link
#   spec.owner           an account owner address, and this backend composes no
#                        accounts
#   spec.tags            an Azure management group carries no tags at all, and a
#                        policy assignment or a role assignment carries none on
#                        any cloud
#
# Not composed here: subscriptions (see the spec.projects rejection), managed
# identities and their grants (that is Identity), networks/clusters/databases
# (their own XRs, which take a subscription id).
import regex
import azure_management.models.v1beta1.management_azurem_upbound_io_v1beta1_management_group as mgmtgroup
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_management_group_policy_assignment as policyassignment
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment as roleassignment

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Label stamped on every composed ManagementGroup, and the key every parent and
# scope selector in this module selects on. Renaming it re-creates the tree.
folder_label = "organization.cloud.example.org/folder"

# Azure nests management groups six LEVELS below the root management group
# (the root itself and the subscription level are not counted). folder_depth
# below reports the distance to the root, so a group at the deepest allowed
# level has distance max_folder_depth - 1, which is the hop budget it is given.
max_folder_depth = 6

# ARM id template of a management group. The "{name}" segment is the upjet
# external-name — the generated schema carries no `name` field at all — and this
# module pins it to the folder key, so every id in the tree is computable before
# Azure has answered.
mg_prefix = "/providers/Microsoft.Management/managementGroups/"

# Tenant-level scope a BUILT-IN policy definition lives at, which is what a bare
# `constraint` (a definition name rather than a path) expands to.
definition_prefix = "/providers/Microsoft.Authorization/policyDefinitions/"

# Azure caps a policy assignment name at 24 characters when the assignment is
# scoped to a management group (128 elsewhere).
max_assignment_name = 24

# An Azure object id: the principal a role assignment grants to.
guid_pattern = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# "Carries a value": unset, null and an EMPTY string/list/dict all count as
# absent, so an `allowedValues: []` left over from an edit is not mistaken for a
# rule the backend would then have to refuse.
_set = lambda v -> bool {
    False if v in [None, Undefined] else (len(v) > 0 if typeof(v) in ["str", "list", "dict"] else True)
}

# "Declared at all", for a field this backend refuses: an explicit `false` is
# still an author asking for behaviour that does not exist here.
_declared = lambda v -> bool {
    v not in [None, Undefined]
}

# composition-resource-name fragment: lowercase, anything outside [a-z0-9-]
# (dots and slashes in a definition path, hyphens aside in a GUID) -> "-".
# Renaming a composed resource deletes and recreates it, so this is contract.
slug = lambda value: str -> str {
    regex.replace(value.lower(), "[^a-z0-9-]", "-")
}

# The last "/"-separated segment of a path, or the value itself when it has none.
_tail = lambda value: str -> str {
    regex.replace(value, "^.*/", "")
}

# ARM id of a management group, from its name.
mg_id = lambda name: str -> str {
    "${mg_prefix}${name}"
}

# The policy definition a policies[] entry assigns. A value starting with "/" is
# already a definition path (built-in, or one defined at a management group) and
# is passed through verbatim; a bare value is a built-in definition name.
definition_id = lambda constraint: str -> str {
    constraint if constraint.startswith("/") else "${definition_prefix}${constraint}"
}

# The assignment's own name, which is its external-name: the id is
# "<scope>/providers/Microsoft.Authorization/policyAssignments/<name>", and the
# schema has no `name` field. Derived from the definition's last segment so it
# is deterministic and recognisable, and truncated to the 24 characters Azure
# accepts at management-group scope (a built-in definition name is a 36-char
# GUID, so truncation is the common case, not the exception). A trailing "-"
# left by the cut is dropped.
assignment_name = lambda constraint: str -> str {
    regex.replace(slug(_tail(constraint))[0:max_assignment_name:], "-+$", "")
}

# Distance from `name` up to the root management group, or -1 when the chain
# does not terminate within `fuel` hops — which is either a cycle or nesting
# deeper than Azure accepts. Both are render errors, not something to discover
# in the API.
folder_depth = lambda name: str, parents: {str:str}, fuel: int -> int {
    _parent = parents[name] or ""
    _result = 0
    if _set(_parent):
        if fuel <= 0:
            _result = -1
        else:
            _up = folder_depth(_parent, parents, fuel - 1)
            _result = -1 if _up < 0 else _up + 1

    _result
}

# Scope key of a policy or an IAM binding: the management group it attaches to,
# or the root of the hierarchy.
_scope = lambda entry -> str {
    "folder-${entry.folder}" if _set(entry?.folder) else "org"
}

# `enforce: false` and `dryRun: true` both mean audit-only, and the assignment
# has exactly one switch for it: `enforce` (the schema's spelling of Azure's
# enforcementMode — false is DoNotEnforce). Sent explicitly rather than left to
# the provider default, so the composed object states what the XR asked for.
_enforced = lambda p -> bool {
    not (_flag(p?.dryRun, False) or p?.enforce == False)
}

render = lambda oxr {
    _spec = oxr.spec
    _org = _spec.orgId
    _root = mg_id(_org)
    _folders = _spec?.folders or []
    _policies = _spec?.policies or []
    _bindings = _spec?.iamBindings or []

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # ── what this backend cannot honour, refused before anything is composed ─
    # Creating a subscription needs the azurerm_subscription resource. The kind
    # is genuinely absent from packages/providers/** — checked across every
    # generated schema package: azure-management ships ManagementGroup and
    # ManagementGroupSubscriptionAssociation only, and the sole other azure
    # "Subscription" kinds are apimanagement.Subscription and the authorization
    # SubscriptionPolicy* kinds, none of which creates one.
    assert not _set(_spec?.projects), "organization-azure: spec.projects is not supported — a subscription is created by the azurerm_subscription resource, which the installed provider family does not ship, so there is nothing for this backend to compose — buy or transfer the subscriptions out of band and attach them to a management group separately (ManagementGroupSubscriptionAssociation), then hand their ids to the workload XRs"
    assert not _declared(_spec?.auditLogging), "organization-azure: spec.auditLogging is not supported — a management-group diagnostic setting has to name a destination (a storage account, an event hub or a Log Analytics workspace) and this API deliberately carries no cloud-specific destination field — configure the diagnostic setting next to the XR that owns the destination, and omit the block here"
    assert all f in _folders {not _flag(f?.deletionProtection, False)}, "organization-azure: a spec.folders[].deletionProtection is true — an Azure management group has no deletion-protection flag, so accepting it would claim protection that does not exist — drop the field and set spec.deletionPolicy: Orphan, which stops Crossplane from deleting the hierarchy at all"

    # ── the shape has to be right before anything is composed ────────────────
    _folder_names = [f.name for f in _folders]
    _parents = {f.name: (f?.parent or "") for f in _folders}
    assert isunique(_folder_names), "organization-azure: spec.folders has duplicate names ${_folder_names} — the name keys the folder inside the XR, and it is also the management-group name, which is tenant-wide unique"
    assert all f in _folders {not _set(f?.parent) or f.parent in _folder_names}, "organization-azure: a spec.folders[].parent names a folder that is not declared in spec.folders — declare it, or drop the parent to put the management group directly under spec.orgId"
    assert all n in _folder_names {folder_depth(n, _parents, max_folder_depth - 1) >= 0}, "organization-azure: spec.folders contains a parent cycle, or nests deeper than the ${max_folder_depth} management-group levels Azure allows beneath the root"

    _policy_keys = ["${_scope(p)}/${p.constraint}" for p in _policies]
    assert isunique(_policy_keys), "organization-azure: spec.policies assigns the same definition twice at the same scope ${_policy_keys} — both entries would resolve to one policy assignment, so the second would silently overwrite the first"
    assert all p in _policies {not _set(p?.folder) or p.folder in _folder_names}, "organization-azure: a spec.policies[].folder names a folder that is not declared in spec.folders"

    # A policy assignment carries a definition and an enforcement mode. It has
    # no value lists (those are parameters the definition itself declares), no
    # inheritance switch and nothing to reset — the XRD says so field by field.
    assert all p in _policies {not (_set(p?.allowedValues) or _set(p?.deniedValues))}, "organization-azure: a spec.policies[] entry sets allowedValues or deniedValues — an Azure policy assignment takes parameters declared by the policy definition it assigns, which are definition-specific and not portable across clouds — assign a definition that already encodes the list you want"
    assert all p in _policies {not (_declared(p?.allowAll) or _declared(p?.denyAll))}, "organization-azure: a spec.policies[] entry sets allowAll or denyAll — there is no value list on an Azure policy assignment to open or close, only a definition and an enforcement mode — pick a definition whose effect is the allow-all or deny-all you meant, and switch it with enforce"
    assert all p in _policies {not _declared(p?.inheritFromParent)}, "organization-azure: a spec.policies[] entry sets inheritFromParent — Azure policy always accumulates down the management-group tree and offers no switch to stop it — remove the field; to exempt a subtree, scope the assignment lower or exclude it with a policy exemption"
    assert all p in _policies {not _declared(p?.reset)}, "organization-azure: a spec.policies[] entry sets reset — a policy assignment has nothing to reset, since it IS the rule rather than an override of an inherited one — delete the entry to detach the assignment instead"
    assert all p in _policies {not (p?.enforce == True and _flag(p?.dryRun, False))}, "organization-azure: a spec.policies[] entry sets enforce: true together with dryRun: true — both map onto the single enforcement mode of a policy assignment and they ask for the opposite thing — keep dryRun: true while the guardrail is being introduced, then drop it and leave enforce: true"

    # The assignment name is derived, truncated and then has to stay unique
    # within its scope, or two entries would fight over one assignment.
    assert all p in _policies {_set(assignment_name(p.constraint))}, "organization-azure: a spec.policies[].constraint yields an empty policy-assignment name — the name is derived from the last segment of the definition id, so the constraint must end in one (a built-in definition name, or a full /providers/Microsoft.Authorization/policyDefinitions/<id> path)"
    _assignment_keys = ["${_scope(p)}/${assignment_name(p.constraint)}" for p in _policies]
    assert isunique(_assignment_keys), "organization-azure: two spec.policies[] entries at the same scope derive the same policy-assignment name ${_assignment_keys} — Azure caps the name at ${max_assignment_name} characters at management-group scope, so two longer definition ids were truncated into a collision — assign definitions whose last segment already differs within its first ${max_assignment_name} characters"

    _binding_keys = ["${_scope(b)}/${b.role}/${b.member}" for b in _bindings]
    assert isunique(_binding_keys), "organization-azure: spec.iamBindings repeats the same member/role/scope ${_binding_keys}"
    assert all b in _bindings {not _set(b?.folder) or b.folder in _folder_names}, "organization-azure: a spec.iamBindings[].folder names a folder that is not declared in spec.folders"
    assert all b in _bindings {regex.match(b.member, guid_pattern)}, "organization-azure: a spec.iamBindings[].member is not an object id — an Azure role assignment grants to the object (principal) id GUID of a user, group or service principal, never to an email address or a gcp-style user:/group:/serviceAccount: prefix — resolve it first (az ad user show --id <upn> --query id -o tsv, or az ad group show / az ad sp show) and put the GUID here"
    assert all b in _bindings {not _declared(b?.condition)}, "organization-azure: a spec.iamBindings[].condition is set — an Azure role-assignment condition is written in Azure's own ABAC dialect over a different attribute set, so a portable expression cannot be carried across — drop the condition and narrow the grant instead, with a smaller role or a lower scope (a folder rather than the root)"

    # ── the management-group tree ────────────────────────────────────────────
    _folder_items = [mgmtgroup.ManagementGroup {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "folder-${f.name}"
            # A management group's NAME is its external-name: the ARM id is
            # "<mg_prefix><name>" and the schema carries no name field. Pinning
            # it to the folder key is what makes the id of every node in the
            # tree deterministic and tenant-wide unique — which is in turn what
            # lets a role assignment scope itself, and status report a folderId,
            # before Azure has created anything.
            "crossplane.io/external-name" = f.name
        }
        # The handle every parent and scope selector below selects on.
        metadata.labels = {"${folder_label}" = f.name}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            displayName = f?.displayName or f.name
            if _set(f?.parent):
                # The reference resolves to the parent's ARM id, which is
                # exactly the form parentManagementGroupId takes — and, unlike a
                # literal id, it makes the child wait for the parent instead of
                # racing it.
                parentManagementGroupIdSelector = {
                    matchControllerRef = True
                    matchLabels = {"${folder_label}" = f.parent}
                }
            else:
                # Top of the tree: the root is spec.orgId, which is not a
                # composed resource, so there is nothing to reference.
                parentManagementGroupId = _root
        }
    } for f in _folders]

    # ── policy assignments ───────────────────────────────────────────────────
    _policy_items = [policyassignment.ManagementGroupPolicyAssignment {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "policy-${_scope(p)}-${slug(p.constraint)}"
            "crossplane.io/external-name" = assignment_name(p.constraint)
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            policyDefinitionId = definition_id(p.constraint)
            enforce = _enforced(p)
            if _set(p?.folder):
                # Same reference, same ordering guarantee as a nested folder.
                managementGroupIdSelector = {
                    matchControllerRef = True
                    matchLabels = {"${folder_label}" = p.folder}
                }
            else:
                managementGroupId = _root
        }
    } for p in _policies]

    # ── role assignments at the top of the hierarchy ─────────────────────────
    # Additive by construction: a role assignment is one (principal, role,
    # scope) triple and never clobbers grants made outside this XR.
    _binding_items = [roleassignment.RoleAssignment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "iam-${_scope(b)}-${slug(b.role)}-${slug(b.member)}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            # RoleAssignment.scope is a plain string: the generated schema
            # offers no scopeRef/scopeSelector, so the management group is
            # addressed by the id its pinned external-name makes computable.
            # The cost is ordering — until the group exists the API call fails
            # and Crossplane retries, which is the normal path, not an error.
            scope = mg_id(b.folder) if _set(b?.folder) else _root
            principalId = b.member
            if b.role.startswith("/"):
                roleDefinitionId = b.role
            else:
                roleDefinitionName = b.role
        }
    } for b in _bindings]

    _folder_items + _policy_items + _binding_items
}

# The management group's own name, read back out of an observed ARM id.
_mg_name = lambda observed_id, fallback: str -> str {
    _name = fallback
    if _set(observed_id):
        _name = _tail(observed_id)

    _name
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _cds = ocds or {}
    _at = lambda resource_name: str -> any {
        (_cds[resource_name]?.Resource?.status?.atProvider) if resource_name in _cds else Undefined
    }

    _declarations = _spec?.folders or []

    _folders = [{
        name = f.name
        # The name is the external-name this module pinned, so it is known
        # ahead of creation; observing the group only confirms it.
        folderId = _mg_name(_at("folder-${f.name}")?.id, f.name)
        parent = _at("folder-${f.name}")?.parentManagementGroupId or ""
    } for f in _declarations]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Organization"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            # The hierarchy exists once Azure has answered for every declared
            # management group. Policy assignments and grants are not part of
            # this — folderId alone would never say so, since it is pinned.
            ready = all f in _declarations {_set(_at("folder-${f.name}")?.id)}
            id = mg_id(_spec.orgId)
            folders = _folders
            # This backend composes no accounts — render() refuses spec.projects
            # outright — so the list is empty rather than absent.
            projects = []
            folderCount = len(_folders)
            projectCount = 0
            policyCount = len(_spec?.policies or [])
            # A management group is not addressable through the portal's
            # /resource blade; the browse blade is the hierarchy's own view.
            "cloud-url" = "https://portal.azure.com/#view/Microsoft_Azure_ManagementGroups/ManagementGroupBrowseBlade/~/MGBrowse_overview"
        }
    }
}
