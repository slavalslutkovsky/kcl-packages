# organization (aws) — Crossplane Composition logic (function-kcl module).
# One Organization XR is the whole AWS Organizations hierarchy: an
# OrganizationalUnit per folders[] entry, an Account per projects[] entry, and
# one service control policy per policies[] entry — a Policy carrying the
# document plus the PolicyAttachment that binds it to a node of the tree.
#
# Not composed here: the Organization itself (CreateOrganization turns the
# calling account into a management account, which is a once-per-account,
# one-way act — spec.orgId names a root that already exists), the
# DelegatedAdministrator of a service (a member-account privilege, not part of
# the hierarchy this XR declares), IAM inside an account (the Identity XR) and
# the accounts' networks, clusters and databases (their own XRs, which take an
# account id).
#
# ── why render() needs the observed state ────────────────────────────────────
# Nothing in this backend resolves by reference, because the generated schemas
# carry no reference to resolve with. Verified field by field against
# packages/providers/aws-organizations/models/v1beta1:
#
#   OrganizationalUnit.forProvider = {name, parentId, tags}
#       -> parentId has NO parentIdRef and NO parentIdSelector
#   Account.forProvider = {closeOnDeletion, createGovcloud, email,
#                          iamUserAccessToBilling, name, parentId, tags}
#       -> parentId has NO parentIdRef and NO parentIdSelector
#   PolicyAttachment.forProvider = {policyId, policyIdRef, policyIdSelector,
#                                   skipDestroy, targetId}
#       -> only policyId is referenceable; targetId has neither ref nor selector
#
# So placement needs a SECOND PASS: render(oxr, ocds) reads the parent OU's
# observed id out of ocds["folder-<parent>"] and emits the child OU, the account
# or the attachment only once that id is known. A node whose parent is not
# observed yet is simply not emitted this iteration — emitting it with a guessed
# parentId would create the OU or the account in the wrong place, and AWS does
# not re-parent on update. It appears one reconcile later. This is the pattern
# docs/hubspoke.md ("Ordering the backends cannot avoid") documents for the
# azure and gcp hubs; status.ready is where the XR says whether the tree is
# complete yet.
#
# ── why nothing pins crossplane.io/external-name ─────────────────────────────
# upjet omits the field that IS the external name from forProvider (compare
# aws-iam Role, whose forProvider carries no `name`). Here `name` is present on
# the OU, the Account and the Policy, so the external name of each is the
# identifier AWS assigns — "ou-…", the 12-digit account id, "p-…" — and pinning
# the SCP name as external-name would make the provider look for a policy whose
# id is that name and fail. The SCP name therefore goes in forProvider.name.
import regex
import json
import aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_organizational_unit as ou
import aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_account as account
import aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_policy as policy
import aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_policy_attachment as attachment

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Label stamped on every composed OrganizationalUnit, carrying its spec key, so
# a selector (or a human) can find the node for a folder. Renaming it re-creates
# nothing — the OUs are addressed by composition-resource-name — but it is the
# handle everything outside this XR uses.
folder_label = "organization.cloud.example.org/folder"

# Label that ties a PolicyAttachment to the Policy it attaches. One XR composes
# n Policies, so matchControllerRef alone is ambiguous and Crossplane refuses to
# resolve it — the same technique as packages/cloud/hubspoke/aws, which
# distinguishes its two route tables the same way.
policy_label = "organization.cloud.example.org/policy"

# AWS allows five levels of organizational units beneath the root.
max_folder_depth = 5

# IAM policy language version. Not configurable: it is a document format, and
# "2012-10-17" is the only one SCPs accept.
policy_version = "2012-10-17"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# "Carries a value": unset, null and an EMPTY string/list/dict all count as
# absent, so a `deniedValues: []` or a `tags: {}` left over from an edit is not
# mistaken for a rule or for metadata worth sending.
_set = lambda v -> bool {
    False if v in [None, Undefined] else (len(v) > 0 if typeof(v) in ["str", "list", "dict"] else True)
}

# composition-resource-name fragment: lowercase, anything outside [a-z0-9-]
# (the ":" in an IAM action, dots in an SCP name) -> "-".
# Renaming a composed resource deletes and recreates it, so this is contract.
slug = lambda value: str -> str {
    regex.replace(value.lower(), "[^a-z0-9-]", "-")
}

# Distance from `name` up to the root, or -1 when the chain does not terminate
# within `fuel` hops — which is either a cycle or nesting deeper than AWS
# accepts. Both are render errors, not something to discover in the API.
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

# Scope key of a policy: the folder it attaches to, or the root itself.
_scope = lambda entry -> str {
    "folder-${entry.folder}" if _set(entry?.folder) else "org"
}

# The label value that pairs one PolicyAttachment with its own Policy. Scope is
# part of it, because the same SCP name at two scopes is two policies.
_policy_key = lambda p -> str {
    "${_scope(p)}-${slug(p.constraint)}"
}

# The SCP document for one policies[] entry. Exactly what is emitted:
#
#   deniedValues:  [a, b] -> Deny  Action=[a, b]     Resource="*"
#   allowedValues: [a, b] -> Allow Action=[a, b]     Resource="*"
#                          + Deny  NotAction=[a, b]  Resource="*"
#
# The second statement of an allow list is not decoration. An SCP is a filter
# over what IAM inside the account may grant, and AWS attaches its own
# FullAWSAccess policy (Allow "*") to every root, OU and account, so the union
# of Allows is already everything: a bare Allow list would change nothing at
# all, which is the silent no-op this repo refuses. Denying everything the list
# does not name is what makes an allow list mean "only these actions", and it
# does so without detaching FullAWSAccess — an org-wide, irreversible act that
# this provider exposes no resource for.
#
# Both lists on one entry emit all three statements: the allow list decides what
# gets through, the deny list then subtracts from it. Deny always wins in IAM,
# so the order of the statements carries no meaning — it is fixed only so the
# document does not churn between renders.
#
# Resource is "*" throughout: an SCP constrains actions on every resource the
# account can reach, and the XRD's value lists carry actions, not ARNs.
_policy_document = lambda p -> str {
    _allowed = p?.allowedValues or []
    _denied = p?.deniedValues or []

    _allow_statements = [
        {
            Sid = "AllowListedActions"
            Effect = "Allow"
            Action = _allowed
            Resource = "*"
        }
        {
            Sid = "DenyUnlistedActions"
            Effect = "Deny"
            NotAction = _allowed
            Resource = "*"
        }
    ] if _set(_allowed) else []

    _deny_statements = [{
        Sid = "DenyListedActions"
        Effect = "Deny"
        Action = _denied
        Resource = "*"
    }] if _set(_denied) else []

    json.encode({
        Version = policy_version
        Statement = _allow_statements + _deny_statements
    })
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _org = _spec.orgId
    _folders = _spec?.folders or []
    _projects = _spec?.projects or []
    _policies = _spec?.policies or []
    _tags = _spec?.tags or {}
    _cds = ocds or {}

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Observed state of a composed resource; Undefined until the first reconcile.
    _at = lambda res: str -> any {
        (_cds[res]?.Resource?.status?.atProvider) if res in _cds else Undefined
    }

    # The id a node hangs from: the Organizations root for a top-level node, the
    # parent OU's OBSERVED id for a nested one — "" while that OU does not exist
    # yet, which is what holds the child back for one reconcile.
    _placement = lambda parent -> str {
        (_at("folder-${parent}")?.id or "") if _set(parent) else _org
    }

    # ── what this backend refuses, and what to reach for instead ─────────────
    assert _spec?.auditLogging in [None, Undefined], "organization-aws: spec.auditLogging is not supported — an organization CloudTrail needs a destination (a bucket), which this API deliberately does not carry because it would be a cloud-specific field; compose a Bucket XR and an explicit organization trail writing to it"
    assert not _set(_spec?.iamBindings), "organization-aws: spec.iamBindings is not supported — AWS Organizations has no IAM at root or OU scope; constrain the tree with service control policies (spec.policies), and grant roles inside an account with the Identity XR"
    assert all p in _projects {not _set(p?.services)}, "organization-aws: spec.projects[].services is not supported — an AWS service is available to every account in the organization, so there is no per-account enablement to perform; it is a GCP-only field and must be dropped"
    assert all p in _projects {not _flag(p?.autoCreateNetwork, False)}, "organization-aws: spec.projects[].autoCreateNetwork: true is not supported — creating an AWS account creates no network this XR could keep; drop the field and compose the VPC with the Network XR"
    assert all f in _folders {not _flag(f?.deletionProtection, False)}, "organization-aws: spec.folders[].deletionProtection: true is not supported — an AWS organizational unit carries no protection flag, and honouring it would mean pretending the node is protected; set spec.deletionPolicy: Orphan to stop managing the tree instead of deleting it"

    assert all p in _policies {p?.enforce in [None, Undefined]}, "organization-aws: a spec.policies[] entry sets enforce — an SCP always names IAM actions and has no boolean switch to turn on; express the guardrail as deniedValues (or allowedValues)"
    assert all p in _policies {p?.allowAll in [None, Undefined]}, "organization-aws: a spec.policies[] entry sets allowAll — an SCP statement needs an explicit Action list, so name the actions in allowedValues"
    assert all p in _policies {p?.denyAll in [None, Undefined]}, "organization-aws: a spec.policies[] entry sets denyAll — an SCP statement needs an explicit Action list, so name the actions in deniedValues"
    assert all p in _policies {p?.inheritFromParent in [None, Undefined]}, "organization-aws: a spec.policies[] entry sets inheritFromParent — SCPs have no inheritance switch: every policy attached above a node already applies to it, and the effective permissions are the intersection of all of them"
    assert all p in _policies {not _flag(p?.reset, False)}, "organization-aws: a spec.policies[] entry sets reset — an SCP has nothing to reset; remove the entry, which detaches the policy"
    assert all p in _policies {not _flag(p?.dryRun, False)}, "organization-aws: a spec.policies[] entry sets dryRun: true — an attached SCP always denies and AWS has no audit-only mode for one; attach it to a sandbox OU first (spec.policies[].folder) instead of to the root"
    assert all p in _policies {_set(p?.allowedValues) or _set(p?.deniedValues)}, "organization-aws: a spec.policies[] entry carries neither allowedValues nor deniedValues — an SCP is a list of IAM actions to allow or deny, so there would be nothing to write into the policy document"

    # ── the shape has to be right before anything is composed ────────────────
    _folder_names = [f.name for f in _folders]
    _parents = {f.name: (f?.parent or "") for f in _folders}
    assert isunique(_folder_names), "organization-aws: spec.folders has duplicate names ${_folder_names} — the name keys the folder inside the XR and must be unique"
    assert all f in _folders {not _set(f?.parent) or f.parent in _folder_names}, "organization-aws: a spec.folders[].parent names a folder that is not declared in spec.folders — declare it, or drop the parent to put the organizational unit directly under the root"

    # A node at the deepest allowed level has max_folder_depth - 1 ancestors,
    # which is the hop budget the walk gets — the same accounting as the gcp
    # and azure backends.
    assert all n in _folder_names {folder_depth(n, _parents, max_folder_depth - 1) >= 0}, "organization-aws: spec.folders contains a parent cycle, or nests deeper than the ${max_folder_depth} organizational-unit levels AWS allows beneath the root"

    _project_names = [p.name for p in _projects]
    assert isunique(_project_names), "organization-aws: spec.projects has duplicate names ${_project_names} — the name keys the account inside the XR and is part of its composed resource name"
    assert all p in _projects {not _set(p?.folder) or p.folder in _folder_names}, "organization-aws: a spec.projects[].folder names a folder that is not declared in spec.folders — declare it, or drop the folder to put the account directly under the root"
    assert all p in _projects {_set(p?.owner) or _set(_spec?.owner)}, "organization-aws: an account needs an owner email — set spec.owner, or spec.projects[].owner on every account; AWS creates a member account against a unique, never-reused root email and cannot invent one"

    _policy_keys = [_policy_key(p) for p in _policies]
    assert isunique(_policy_keys), "organization-aws: spec.policies declares the same constraint twice at the same scope ${_policy_keys} — the two attachments would fight over the same target"
    assert all p in _policies {not _set(p?.folder) or p.folder in _folder_names}, "organization-aws: a spec.policies[].folder names a folder that is not declared in spec.folders"

    # The attachment finds its own Policy through this label, so the label value
    # has to be one: at most 63 characters, starting and ending alphanumeric.
    assert all k in _policy_keys {regex.match(k, "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")}, "organization-aws: a spec.policies[] entry produces the label value ${_policy_keys}, which is not a valid Kubernetes label value — at most 63 characters (scope included), starting and ending in a letter or a digit; shorten the constraint name and do not end it in punctuation, or the composed PolicyAttachment cannot select its Policy"

    # ── organizational units ─────────────────────────────────────────────────
    # A nested OU is emitted only once its parent's id is observed; see the
    # header for why that cannot be a reference.
    _folder_items = [ou.OrganizationalUnit {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "folder-${f.name}"}
        # The handle everything outside this XR finds the node by.
        metadata.labels = {"${folder_label}" = f.name}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            name = f?.displayName or f.name
            parentId = _placement(f?.parent)
            # Empty tags are left unset rather than sent as {}: the provider
            # would otherwise treat "no tags" as a value to reconcile.
            if _set(_tags):
                tags = _tags
        }
    } for f in _folders if _set(_placement(f?.parent))]

    # ── accounts ─────────────────────────────────────────────────────────────
    # Same second pass: an account in an OU waits for the OU's id.
    # createGovcloud and iamUserAccessToBilling are deliberately never set —
    # both re-create the account when changed, and neither is in this API.
    _project_items = [account.Account {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "project-${p.name}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            name = p?.displayName or p.name
            # The root email of the member account. Unique per account in AWS,
            # which is why the render fails rather than inventing one.
            email = p?.owner or _spec.owner
            parentId = _placement(p?.folder)
            # whenDeleted=delete closes the account; prevent and abandon both
            # leave it in the organization. AWS cannot refuse the removal of the
            # managed resource — it can only decline to close the account.
            closeOnDeletion = (p?.whenDeleted or "delete") == "delete"
            if _set(_tags) or _set(p?.labels):
                tags = _tags | (p?.labels or {})
        }
    } for p in _projects if _set(_placement(p?.folder))]

    # ── service control policies ─────────────────────────────────────────────
    # The document depends on nothing observed, so the Policy is composed
    # immediately; only its attachment waits for a target.
    _policy_items = [policy.Policy {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "policy-${_scope(p)}-${slug(p.constraint)}"}
        # What the attachment below selects on. spec.tags deliberately do not
        # reach a policy: the XRD says metadata stops at accounts and OUs.
        metadata.labels = {"${policy_label}" = _policy_key(p)}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            name = p.constraint
            # The API's own default, stated anyway: a Policy whose type is left
            # to the API is one field away from silently becoming a tag policy.
            $type = "SERVICE_CONTROL_POLICY"
            content = _policy_document(p)
        }
    } for p in _policies]

    # targetId has no ref and no selector, so a folder-scoped policy can only be
    # attached once its OU exists; a root-scoped one attaches straight away.
    _attachment_items = [attachment.PolicyAttachment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "attachment-${_scope(p)}-${slug(p.constraint)}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider = {
            targetId = _placement(p?.folder)
            # matchControllerRef alone would be ambiguous the moment a second
            # policy exists, and Crossplane then refuses to resolve either.
            policyIdSelector = {
                matchControllerRef = True
                matchLabels = {"${policy_label}" = _policy_key(p)}
            }
        }
    } for p in _policies if _set(_placement(p?.folder))]

    _folder_items + _project_items + _policy_items + _attachment_items
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
        folderId = _at("folder-${f.name}")?.id or ""
        parent = _at("folder-${f.name}")?.parentId or ""
    } for f in (_spec?.folders or [])]

    _projects = [{
        name = p.name
        # The 12-digit account id, which AWS assigns; unlike GCP there is
        # nothing in the spec that predicts it.
        projectId = _at("project-${p.name}")?.id or ""
        # AWS has exactly one identifier for an account and it is projectId.
        number = ""
    } for p in (_spec?.projects or [])]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Organization"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            # Also the answer to "is the tree complete?". A node whose parent is
            # not observed yet is not emitted at all, so an unnumbered folder or
            # account means a second pass is still outstanding. Policies and
            # their attachments are not part of this.
            ready = all f in _folders {f.folderId != ""} and all p in _projects {p.projectId != ""}
            id = _spec.orgId
            folders = _folders
            projects = _projects
            folderCount = len(_folders)
            projectCount = len(_projects)
            policyCount = len(_spec?.policies or [])
            # The Organizations console is global, served out of us-east-1.
            "cloud-url" = "https://us-east-1.console.aws.amazon.com/organizations/v2/home/accounts"
        }
    }
}
