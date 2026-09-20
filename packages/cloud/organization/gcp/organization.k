# organization (gcp) — Crossplane Composition logic (function-kcl module).
# One Organization XR is the whole GCP resource hierarchy: a Folder per folders[]
# entry (nested through parentSelector), a Project per projects[] entry with one
# ProjectService per enabled API, an Org Policy v2 Policy per policies[] entry,
# an OrganizationIAMAuditConfig per audited service, and an
# Organization/FolderIAMMember per iamBindings[] entry.
#
# Everything the XR declares is resolved BY REFERENCE, never by a numeric id the
# author would have to know: a folder's parent, a project's folder and a policy's
# or binding's scope are all matched on the label this module stamps on the
# composed Folder. That is also what orders creation — a child waits for its
# parent instead of racing it.
#
# Not composed here: service accounts (Identity), networks/clusters/databases
# (their own XRs, which take a project id), billing accounts and the
# organization itself (not creatable through any API).
import regex
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder as folder
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project as project
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_service as projectservice
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_audit_config as auditconfig
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_member as orgmember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder_i_a_m_member as foldermember
import gcp_orgpolicy.models.v1beta1.orgpolicy_gcpm_upbound_io_v1beta1_policy as orgpolicy

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Label stamped on every composed Folder, and the key every parent/folder
# reference in this module selects on. Renaming it re-creates every folder.
folder_label = "organization.cloud.example.org/folder"

# GCP allows at most 10 levels of folders beneath an organization.
max_folder_depth = 10

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# "Carries a value": unset, null and an EMPTY string/list/dict all count as
# absent, so an `allowedValues: []` or a `tags: {}` left over from an edit is
# not mistaken for a rule or for metadata worth sending.
_set = lambda v -> bool {
    False if v in [None, Undefined] else (len(v) > 0 if typeof(v) in ["str", "list", "dict"] else True)
}

# composition-resource-name fragment: lowercase, anything outside [a-z0-9-]
# (dots in an API name or a constraint, ":" and "@" in an IAM member) -> "-".
# Renaming a composed resource deletes and recreates it, so this is contract.
slug = lambda value: str -> str {
    regex.replace(value.lower(), "[^a-z0-9-]", "-")
}

# Distance from `name` up to the organization, or -1 when the chain does not
# terminate within `fuel` hops — which is either a cycle or nesting deeper than
# GCP accepts. Both are render errors, not something to discover in the API.
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

# Scope key of a policy or an IAM binding: the folder it attaches to, or the
# organization itself.
_scope = lambda entry -> str {
    "folder-${entry.folder}" if _set(entry?.folder) else "org"
}

render = lambda oxr {
    _spec = oxr.spec
    _org = _spec.orgId
    _org_parent = "organizations/${_org}"
    _folders = _spec?.folders or []
    _projects = _spec?.projects or []
    _policies = _spec?.policies or []
    _bindings = _spec?.iamBindings or []
    _audit = _spec?.auditLogging
    _tags = _spec?.tags or {}

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # ── the shape has to be right before anything is composed ────────────────
    _folder_names = [f.name for f in _folders]
    _parents = {f.name: (f?.parent or "") for f in _folders}
    assert isunique(_folder_names), "organization-gcp: spec.folders has duplicate names ${_folder_names} — the name keys the folder inside the XR and must be unique"
    assert all f in _folders {not _set(f?.parent) or f.parent in _folder_names}, "organization-gcp: a spec.folders[].parent names a folder that is not declared in spec.folders — declare it, or drop the parent to put the folder under the organization"

    # A node at the deepest allowed level has max_folder_depth - 1 ancestors,
    # which is the hop budget the walk gets — the same accounting as the aws
    # and azure backends.
    assert all n in _folder_names {folder_depth(n, _parents, max_folder_depth - 1) >= 0}, "organization-gcp: spec.folders contains a parent cycle, or nests deeper than the ${max_folder_depth} folder levels GCP allows"

    _project_names = [p.name for p in _projects]
    assert isunique(_project_names), "organization-gcp: spec.projects has duplicate names ${_project_names} — the name is the project id and is globally unique in GCP"

    # The XRD's pattern is the portable one (an AWS account name is freer than
    # a GCP project id), so the stricter GCP rule is enforced here rather than
    # left to the API: 6-30 characters, starting with a letter.
    assert all p in _projects {regex.match(p.name, "^[a-z][-a-z0-9]{4,28}[a-z0-9]$")}, "organization-gcp: a spec.projects[].name is not a valid GCP project id — 6 to 30 characters, starting with a lowercase letter, then lowercase letters, digits or hyphens, not ending in a hyphen"
    assert all p in _projects {not _set(p?.folder) or p.folder in _folder_names}, "organization-gcp: a spec.projects[].folder names a folder that is not declared in spec.folders — declare it, or drop the folder to put the project under the organization"
    assert all p in _projects {_set(p?.billingAccount) or _set(_spec?.billingAccount)}, "organization-gcp: a project needs a billing account — set spec.billingAccount, or spec.projects[].billingAccount on every project; an unlinked project cannot run billable services"

    _policy_keys = ["${_scope(p)}/${p.constraint}" for p in _policies]
    assert isunique(_policy_keys), "organization-gcp: spec.policies declares the same constraint twice at the same scope ${_policy_keys} — one policy object exists per constraint per resource, so the second would silently overwrite the first"
    assert all p in _policies {not _set(p?.folder) or p.folder in _folder_names}, "organization-gcp: a spec.policies[].folder names a folder that is not declared in spec.folders"

    # A boolean constraint takes `enforce`; a list constraint takes values,
    # allowAll or denyAll. Mixing them is rejected by the API, and `reset`
    # means "inherit nothing, enforce the constraint default", which is
    # incompatible with carrying any rule at all.
    assert all p in _policies {not (p?.enforce != Undefined and (_set(p?.allowedValues) or _set(p?.deniedValues) or p?.allowAll != Undefined or p?.denyAll != Undefined))}, "organization-gcp: a spec.policies[] entry sets both enforce (boolean constraint) and a list field — a constraint is one or the other"
    assert all p in _policies {not (p?.allowAll == True and p?.denyAll == True)}, "organization-gcp: a spec.policies[] entry sets both allowAll and denyAll"
    assert all p in _policies {not (_flag(p?.reset, False) and (p?.enforce != Undefined or _set(p?.allowedValues) or _set(p?.deniedValues) or p?.allowAll != Undefined or p?.denyAll != Undefined))}, "organization-gcp: a spec.policies[] entry sets reset together with rules — reset restores the constraint default and must carry none"
    assert all p in _policies {p?.enforce != Undefined or _set(p?.allowedValues) or _set(p?.deniedValues) or p?.allowAll != Undefined or p?.denyAll != Undefined or _flag(p?.reset, False)}, "organization-gcp: a spec.policies[] entry carries no rule — set enforce, allowedValues/deniedValues, allowAll/denyAll, or reset"

    _binding_keys = ["${_scope(b)}/${b.role}/${b.member}" for b in _bindings]
    assert isunique(_binding_keys), "organization-gcp: spec.iamBindings repeats the same member/role/scope ${_binding_keys}"
    assert all b in _bindings {not _set(b?.folder) or b.folder in _folder_names}, "organization-gcp: a spec.iamBindings[].folder names a folder that is not declared in spec.folders"

    # ── folders ──────────────────────────────────────────────────────────────
    _folder_items = [folder.Folder {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "folder-${f.name}"}
        # The handle every parent/folder reference below selects on.
        metadata.labels = {"${folder_label}" = f.name}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            displayName = f?.displayName or f.name
            # GCP's own API default is true; the XRD default is false, so a
            # folder this XR created can also be removed by editing the XR.
            deletionProtection = _flag(f?.deletionProtection, False)
            if _set(f?.parent):
                # The Folder reference resolves to "folders/<id>", which is
                # exactly the form `parent` takes — and it makes the child wait
                # for the parent instead of racing it.
                parentSelector = {
                    matchControllerRef = True
                    matchLabels = {"${folder_label}" = f.parent}
                }
            else:
                parent = _org_parent
        }
    } for f in _folders]

    # ── projects, and the APIs enabled on them ───────────────────────────────
    _project_items = [project.Project {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "project-${p.name}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            projectId = p.name
            name = p?.displayName or p.name
            billingAccount = p?.billingAccount or _spec.billingAccount
            # A default VPC is an unaudited open network in every region; the
            # network XR is how a VPC is meant to appear.
            autoCreateNetwork = _flag(p?.autoCreateNetwork, False)
            deletionPolicy = (p?.whenDeleted or "delete").upper()
            # Empty labels are left unset rather than sent as {}: the provider
            # would otherwise treat "no labels" as a value to reconcile.
            if _set(_tags) or _set(p?.labels):
                labels = _tags | (p?.labels or {})
            if _set(p?.folder):
                # google_project trims the "folders/" prefix the reference
                # resolves to, so the selector works as-is.
                folderIdSelector = {
                    matchControllerRef = True
                    matchLabels = {"${folder_label}" = p.folder}
                }
            else:
                orgId = _org
        }
    } for p in _projects]

    # The project id is known from the spec, so `project` is set literally
    # rather than through projectSelector: the reference would resolve to the
    # Project's terraform id ("projects/<id>"), which Service Usage does not
    # accept. The cost is ordering — until the project exists the API call
    # fails and Crossplane retries, which is the normal path, not an error.
    _service_items = [projectservice.ProjectService {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "service-${p.name}-${slug(s)}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            project = p.name
            service = s
            # Dropping an API from the list stops managing it; it does not tear
            # down whatever is still running on it.
            disableOnDestroy = False
        }
    } for p in _projects for s in (p?.services or [])]

    # ── organization policies ────────────────────────────────────────────────
    _policy_items = [orgpolicy.Policy {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "policy-${_scope(p)}-${slug(p.constraint)}"
            # The policy's name is its external-name (id is
            # "<parent>/policies/<name>"), and it is the constraint it governs.
            "crossplane.io/external-name" = p.constraint
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            if _set(p?.folder):
                parentSelector = {
                    matchControllerRef = True
                    matchLabels = {"${folder_label}" = p.folder}
                }
            else:
                parent = _org_parent
            # A dry-run policy logs violations and blocks nothing: the way to
            # introduce a constraint on a populated organization.
            if _flag(p?.dryRun, False):
                dryRunSpec = _policy_spec(p)
            else:
                spec = _policy_spec(p)
        }
    } for p in _policies]

    # ── organization-wide data-access audit logging ──────────────────────────
    _audit_items = [auditconfig.OrganizationIAMAuditConfig {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "audit-${slug(s)}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            orgId = _org
            service = s
            auditLogConfig = [{
                logType = t
                if _set(_audit?.exemptedMembers):
                    exemptedMembers = _audit.exemptedMembers
            } for t in (_audit?.logTypes or ["ADMIN_READ", "DATA_READ", "DATA_WRITE"])]
        }
    } for s in ((_audit?.services or ["allServices"]) if _audit not in [None, Undefined] else [])]

    # ── IAM at the top of the hierarchy ──────────────────────────────────────
    # Member-level (additive) bindings only: an authoritative binding would
    # wipe every grant made outside this XR.
    _binding_items = [item for b in _bindings for item in _binding(b, _org, _mp)]

    _folder_items + _project_items + _service_items + _policy_items + _audit_items + _binding_items
}

# The Org Policy v2 spec (live or dry-run) for one policies[] entry.
_policy_spec = lambda p -> any {
    {
        if _flag(p?.reset, False):
            # reset takes no rules and cannot inherit.
            reset = True
        else:
            rules = [{
                if p?.enforce != Undefined:
                    # Boolean constraints carry the enforcement as a string.
                    enforce = "TRUE" if p.enforce else "FALSE"
                if p?.allowAll != Undefined:
                    allowAll = "TRUE" if p.allowAll else "FALSE"
                if p?.denyAll != Undefined:
                    denyAll = "TRUE" if p.denyAll else "FALSE"
                if _set(p?.allowedValues) or _set(p?.deniedValues):
                    values = {
                        if _set(p?.allowedValues):
                            allowedValues = p.allowedValues
                        if _set(p?.deniedValues):
                            deniedValues = p.deniedValues
                    }
            }]
            if p?.inheritFromParent != Undefined:
                inheritFromParent = p.inheritFromParent
    }
}

# One IAM member binding, at a folder or at the organization. Returns a
# single-element list: the two kinds are different types, so a conditional
# assignment to one variable would not typecheck.
_binding = lambda b, org: str, mp -> [any] {
    _res_name = "iam-${_scope(b)}-${slug(b.role)}-${slug(b.member)}"

    # The API requires a title on a condition; name it after the role rather
    # than failing a render over a cosmetic field.
    _condition = {
        expression = b.condition.expression
        title = b.condition?.title or "${b.role} condition"
        if _set(b.condition?.description):
            description = b.condition.description
    } if b?.condition else Undefined

    [foldermember.FolderIAMMember {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _res_name}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            folderSelector = {
                matchControllerRef = True
                matchLabels = {"${folder_label}" = b.folder}
            }
            role = b.role
            member = b.member
            if _condition:
                condition = _condition
        }
    }] if _set(b?.folder) else [orgmember.OrganizationIAMMember {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = _res_name}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            orgId = org
            role = b.role
            member = b.member
            if _condition:
                condition = _condition
        }
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _cds = ocds or {}
    _at = lambda resource_name: str -> any {
        (_cds[resource_name]?.Resource?.status?.atProvider) if resource_name in _cds else Undefined
    }

    _folders = [{
        name = f.name
        folderId = _at("folder-${f.name}")?.folderId or ""
        parent = _at("folder-${f.name}")?.parent or ""
    } for f in (_spec?.folders or [])]

    _projects = [{
        name = p.name
        projectId = _at("project-${p.name}")?.projectId or p.name
        number = _at("project-${p.name}")?.number or ""
    } for p in (_spec?.projects or [])]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Organization"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            # The hierarchy exists once GCP has numbered every folder and every
            # project. Policies and API enablement are not part of this.
            ready = all f in _folders {f.folderId != ""} and all p in _projects {p.number != ""}
            id = "organizations/${_spec.orgId}"
            folders = _folders
            projects = _projects
            folderCount = len(_folders)
            projectCount = len(_projects)
            policyCount = len(_spec?.policies or [])
            "cloud-url" = "https://console.cloud.google.com/cloud-resource-manager?organizationId=${_spec.orgId}"
        }
    }
}
