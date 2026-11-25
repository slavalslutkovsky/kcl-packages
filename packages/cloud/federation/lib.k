"""
Federation — keyless access for CI pipelines (git clients) and the ticket
systems that start them, as data every cloud backend reads the same way.

  Binding (client + owner/repositories/subjects/workflows, optional ticket)
    -> GCP   a workload identity pool/provider (expand) and the principal(Set)
             members a grant names (gcp_members)
    -> AWS   an IAM role trust: the IAM OIDC provider ARN, `<host>:aud` and
             `<host>:sub` (aws_trust)
    -> Azure federated identity credentials: issuer, exact subjects, audience
             (azure_subjects, audiences_for)

AWS and Azure trust only a token's `sub` and `aud`, so what GCP checks in a
CEL condition (ticket trigger, workflow, extra CEL) needs explicit `subjects`
there — the values of a customized sub claim (GitHub: PUT
/repos/{owner}/{repo}/actions/oidc/customization/sub). A binding they cannot
express fails the render instead of granting more than it says.

Claim names come from each vendor's token reference:
  GitHub      docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect
  GitLab      docs.gitlab.com/ci/secrets/id_token_authentication (namespace_path, project_path, pipeline_source;
              sub project_path:<group>/<project>:ref_type:<type>:ref:<ref>)
  Bitbucket   support.atlassian.com/bitbucket-cloud/docs/integrate-pipelines-with-resource-servers-using-oidc
              (per-workspace issuer, aud ari:cloud:bitbucket::workspace/<uuid>, repositoryUuid, branchName;
              sub <repositoryUuid>[:<environmentUuid>]:<stepUuid>)
  Azure       learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure (vstoken issuer per
              organization id, sub sc://<org>/<project>/<connection>, aud api://AzureADTokenExchange;
              the vstoken issuer retires 2027-07-01, pass the Entra issuer as `issuerUri` instead)
"""

import regex

# ── Git clients ──────────────────────────────────────────────────────────────
# A built-in is picked by name (`client: github`); any other issuer is a
# Client written inline (`customClient: {...}`), so the set is open:
# Forgejo/Gitea Actions, Buildkite, CircleCI, a GHEC enterprise issuer, ...
schema Client:
  """One OIDC issuer family and how a binding's owner/repositories/ticket turn into a CEL condition."""
  # Short id: the default pool id of a ticket binding is "<ticket>-<id>".
  id: str
  # "GitHub Actions" -> pool "GitHub Actions Pool", provider "GitHub Actions Provider".
  label: str

  # Issuer URI. "{host}" and "{owner}" are filled from the binding (host
  # falls back to defaultHost); a binding's `issuerUri` replaces it whole.
  issuer: str
  defaultHost?: str
  # Default pool / provider ids; "<id>-pool" / "<id>-provider" when unset.
  pool?: str
  provider?: str
  attributeMapping: {str:str} = {"google.subject" = "assertion.sub"}

  # CEL operand compared with the binding's `owner` (`<ownerKey> == '<owner>'`).
  # Unset: the owner only fills "{owner}" in the issuer.
  ownerKey?: str
  # CEL operand for the binding's `repositories` (`<repositoryKey> in [...]`).
  repositoryKey?: str
  # Token claim naming what started the run; ticket bindings restrict it.
  triggerClaim?: str
  # Claim "<owner>/<repo>/<workflow path>@<ref>" of the workflow that runs;
  # the binding's `workflows` pin it.
  workflowKey?: str
  # Allowed audiences when the token's `aud` is not the GCP provider's resource name.
  audiences: [str] = []

  # Audience the client's cloud login asks for, per cloud ("aws", "azure"),
  # when `audiences` does not apply there.
  cloudAudiences: {str:[str]} = {}
  # The token's `aud` is fixed by the vendor and unknown here: every binding must set `audiences`.
  requireAudiences: bool = False

  # `sub` patterns (AWS StringLike) for the binding's owner / each repository;
  # "{owner}" / "{repo}" are filled in. Unset: AWS needs explicit `subjects`.
  subjectByOwner?: str
  subjectByRepository?: str
  # The issuer is shared by every tenant of the service (and defaultHost is
  # in use): a binding must narrow it, or any of their workflows gets in.
  multiTenant: bool = False

  check:
    regex.match(id, r"^[a-z][a-z0-9-]*$"), "client id '${id}' must be lowercase [a-z0-9-]"
    issuer.startswith("https://"), "client ${id}: GCP accepts only https:// OIDC issuers, got '${issuer}'"

# The mapping every GitHub pool in projects/dev/terraform.tfvars uses, same order.
_github_mapping = {
  "attribute.actor" = "assertion.actor"
  "attribute.repository" = "assertion.repository"
  "attribute.repository_owner" = "assertion.repository_owner"
  "google.subject" = "assertion.sub"
}

# What aws-actions/configure-aws-credentials and azure/login request.
_github_cloud_audiences = {aws = ["sts.amazonaws.com"], azure = ["api://AzureADTokenExchange"]}

clients: {str:Client} = {
  github = Client {
    id = "github"
    label = "GitHub Actions"
    issuer = "https://token.actions.githubusercontent.com"
    pool = "github-actions-pool"
    provider = "github-actions-provider"
    attributeMapping = _github_mapping
    ownerKey = "assertion.repository_owner"
    repositoryKey = "attribute.repository"
    triggerClaim = "event_name"
    workflowKey = "assertion.workflow_ref"
    cloudAudiences = _github_cloud_audiences
    subjectByOwner = "repo:{owner}/*"
    subjectByRepository = "repo:{repo}:*"
    multiTenant = True
  }
  "github-enterprise" = Client {
    id = "github-enterprise"
    label = "GitHub Enterprise"
    issuer = "https://{host}/_services/token"
    attributeMapping = _github_mapping
    ownerKey = "assertion.repository_owner"
    repositoryKey = "attribute.repository"
    triggerClaim = "event_name"
    workflowKey = "assertion.workflow_ref"
    cloudAudiences = _github_cloud_audiences
    subjectByOwner = "repo:{owner}/*"
    subjectByRepository = "repo:{repo}:*"
  }
  gitlab = Client {
    id = "gitlab"
    label = "GitLab CI"
    issuer = "https://{host}"
    defaultHost = "gitlab.com"
    pool = "gitlab-ci-pool"
    provider = "gitlab-ci-provider"
    attributeMapping = {
      "attribute.namespace_path" = "assertion.namespace_path"
      "attribute.project_path" = "assertion.project_path"
      "attribute.ref" = "assertion.ref"
      "attribute.user_login" = "assertion.user_login"
      "google.subject" = "assertion.sub"
    }
    ownerKey = "assertion.namespace_path"
    repositoryKey = "attribute.project_path"
    triggerClaim = "pipeline_source"
    subjectByOwner = "project_path:{owner}/*"
    subjectByRepository = "project_path:{repo}:*"
    multiTenant = True
  }
  bitbucket = Client {
    id = "bitbucket"
    label = "Bitbucket Pipelines"
    # One issuer per workspace: `owner` is the workspace slug.
    issuer = "https://api.bitbucket.org/2.0/workspaces/{owner}/pipelines-config/identity/oidc"
    pool = "bitbucket-pipelines-pool"
    provider = "bitbucket-pipelines-provider"
    attributeMapping = {
      "attribute.workspace_uuid" = "assertion.workspaceUuid"
      "attribute.repository_uuid" = "assertion.repositoryUuid"
      "attribute.branch" = "assertion.branchName"
      "google.subject" = "assertion.sub"
    }
    # `repositories` are repository UUIDs, braces included: "{1b2c...}".
    repositoryKey = "attribute.repository_uuid"
    # The issuer is the workspace: owner alone admits all of it.
    subjectByOwner = "*"
    subjectByRepository = "{repo}:*"
    # aud = ari:cloud:bitbucket::workspace/<workspace uuid>
    requireAudiences = True
  }
  "azure-devops" = Client {
    id = "azure-devops"
    label = "Azure Pipelines"
    # `owner` is the organization id (a GUID), not its name.
    issuer = "https://vstoken.dev.azure.com/{owner}"
    pool = "azure-pipelines-pool"
    provider = "azure-pipelines-provider"
    # Narrow with `subjects`: sc://<organization>/<project>/<service connection>.
    audiences = ["api://AzureADTokenExchange"]
  }
}

# Ticket systems. None of them mints OIDC tokens GCP can verify: Jira Cloud's
# only signed token is the Forge Invocation Token, issuer
# "forge/invocation-token" (not an https:// URI, which GCP requires); ClickUp,
# monday.com, Asana, Trello, Linear, ServiceNow, ... have none. What a ticket
# system CAN do is start a run in a git client through that client's
# dispatch/trigger API: directly when its automation can send an authenticated
# POST with a JSON body (Jira Automation "Send web request"), through a small
# relay when it only fires fixed webhooks. The run's token is the client's,
# and its trigger claim says how it was started.
#
# So a ticket binding is a git client binding narrowed to the runs a ticket
# system can start: `<client.triggerClaim> in [<triggers[claim]>]`. Its pool is
# separate ("<ticket>-<client>") so IAM can grant ticket-driven runs less than
# the client's pushes. Every external system reaches the same dispatch API, so
# two ticket bindings over the same repositories are told apart only by the
# workflow that runs (`workflows`, GitHub's workflow_ref) or by disjoint
# repositories; `expand` rejects two that admit the same tokens. What a pool
# proves is "this workflow ran from a dispatch", not "Jira sent it": the caller
# is whoever holds the dispatch token, so give each system its own token.
#
# A built-in is picked by name (`ticket: clickup`); any other system is a
# Ticket written inline (`customTicket: {id, label, triggers}`).
schema Ticket:
  """A system that starts git client runs, and the trigger values those runs carry."""
  id: str
  label: str
  # Trigger claim -> values a run started by this system carries.
  triggers: {str:[str]}

  check:
    regex.match(id, r"^[a-z][a-z0-9-]*$"), "ticket id '${id}' must be lowercase [a-z0-9-]"
    len(triggers) > 0, "ticket ${id}: needs at least one trigger claim"

# Runs started through a client's API by an outside system:
#   GitHub  POST /repos/{owner}/{repo}/dispatches              -> repository_dispatch
#           POST /repos/{owner}/{repo}/actions/workflows/.../dispatches -> workflow_dispatch
#   GitLab  POST /projects/:id/trigger/pipeline (trigger token) -> trigger
#           POST /projects/:id/pipeline (access token)          -> api
_external = {
  event_name = ["repository_dispatch", "workflow_dispatch"]
  pipeline_source = ["trigger", "api"]
}

# Ticket managers whose automations or webhooks call the dispatch/trigger API.
_external_systems = {
  jira = "Jira"
  clickup = "ClickUp"
  monday = "monday.com"
  asana = "Asana"
  trello = "Trello"
  linear = "Linear"
  shortcut = "Shortcut"
  youtrack = "YouTrack"
  servicenow = "ServiceNow"
  zendesk = "Zendesk"
  "azure-boards" = "Azure Boards"
}

tickets: {str:Ticket} = {
  **{_id: Ticket {id = _id, label = _label, triggers = _external} for _id, _label in _external_systems}
  # GitHub Issues starts workflows natively, on issue and comment events.
  "github-issues" = Ticket {
    id = "github-issues"
    label = "GitHub Issues"
    triggers = {event_name = ["issues", "issue_comment"]}
  }
}

# Binding: the short form of one workload identity provider. `expand` turns a
# list of bindings into the Fabric-shaped `workloadIdentityPools` map
# (pool id -> {displayName, description, providers}), so the rendering, the
# external names and the Terraform parity stay where they are.
#
#   - client: github                      # or customClient: {id, label, issuer, ...}
#     owner: my-org                       # -> assertion.repository_owner == 'my-org'
#   - client: github
#     ticket: jira                        # or customTicket: {id, label, triggers}
#     repositories: [my-org/deployer]     # -> attribute.repository in ['my-org/deployer']
#                                         #    && assertion.event_name in ['repository_dispatch', 'workflow_dispatch']
schema Binding:
  """One provider in one pool, described by who may federate instead of by its CEL."""
  # Built-in git client name (`clients`) xor an inline Client.
  client?: str
  customClient?: Client
  # Built-in ticket system name (`tickets`) xor an inline Ticket: only runs it can start.
  ticket?: str
  customTicket?: Ticket
  # Ids; default: the client's (github-actions-pool / github-actions-provider),
  # "<ticket>-<client>" for the pool of a ticket binding.
  pool?: str
  provider?: str
  # Pool display name / description; only the first binding of a pool may set them.
  displayName?: str
  description?: str
  # Self-managed instance (fills "{host}" in the client's issuer).
  host?: str
  # Replaces the client's issuer (a GHEC enterprise issuer, the Entra issuer of Azure DevOps).
  issuerUri?: str
  # Org / group / workspace / organization id: the client's ownerKey and/or "{owner}".
  owner?: str
  # Repositories in the client's terms: owner/name, group/project, {uuid}.
  repositories: [str] = []
  # Exact token subjects: assertion.sub in [...].
  subjects: [str] = []

  # Workflows that may federate, "<owner>/<repo>/<path>" (any ref) or
  # "<owner>/<repo>/<path>@<ref>" (that ref): the client's workflowKey.
  workflows: [str] = []
  # Allowed audiences; default (and when empty) the client's.
  audiences?: [str]
  # Merged over the client's mapping.
  attributeMapping?: {str:str}
  # Extra CEL, ANDed with the generated condition.
  condition?: str

  check:
    bool(client) != bool(customClient), "a workload identity binding needs exactly one of client or customClient"
    not (ticket and customTicket), "a workload identity binding takes ticket or customTicket, not both"
    not client or client in clients, "unknown git client '${client}' (built-in: ${', '.join([_k for _k in clients])}); describe any other issuer with customClient"
    not ticket or ticket in tickets, "unknown ticket system '${ticket}' (built-in: ${', '.join([_k for _k in tickets])}); describe any other with customTicket"
    # Values are spliced into single-quoted CEL strings.
    all_true([regex.match(_v, _cel_safe) for _v in repositories + subjects + workflows + ([owner] if owner else [])]), "owner, repositories, subjects and workflows must not contain quotes or backslashes"
    all_true([regex.match(_w, r"^[^/@]+/[^/@]+/[^@]+(@.+)?$") for _w in workflows]), "workflows are <owner>/<repo>/<path>[@<ref>], got ${workflows}"

_cel_safe = r"^[^'\"\\]+$"
# GCP pool and provider ids: 4-32 of [a-z0-9-], "gcp-" is reserved.
_id_pattern = r"^[a-z0-9-]{4,32}$"

client_of = lambda b: Binding -> Client {
  b.customClient if b.customClient else clients[b.client]
}

ticket_of = lambda b: Binding -> any {
  b.customTicket if b.customTicket else (tickets[b.ticket] if b.ticket else None)
}

pool_id = lambda b: Binding -> str {
  _c = client_of(b)
  _t = ticket_of(b)
  b.pool or ("${_t.id}-${_c.id}" if _t else (_c.pool or "${_c.id}-pool"))
}

provider_id = lambda b: Binding -> str {
  _c = client_of(b)
  b.provider or _c.provider or "${_c.id}-provider"
}

_where = lambda b: Binding -> str {
  "workload identity ${pool_id(b)}/${provider_id(b)}"
}

issuer_uri = lambda b: Binding -> str {
  _c = client_of(b)
  _host = b.host or _c.defaultHost or ""
  assert not b.host or "{host}" in _c.issuer or b.issuerUri, "${_where(b)}: client ${_c.id} has a fixed issuer, `host` does nothing"
  _uri = b.issuerUri or _c.issuer
  if not b.issuerUri:
    assert "{host}" not in _c.issuer or _host, "${_where(b)}: client ${_c.id} needs `host` (issuer ${_c.issuer})"
    assert "{owner}" not in _c.issuer or b.owner, "${_where(b)}: client ${_c.id} needs `owner` (issuer ${_c.issuer})"
    _uri = _c.issuer.replace("{host}", _host).replace("{owner}", b.owner or "")

  assert _uri.startswith("https://"), "${_where(b)}: GCP accepts only https:// issuers, got '${_uri}'"
  _uri
}

_list = lambda xs: [str] -> str {
  "[" + ", ".join(["'${_x}'" for _x in xs]) + "]"
}

# The provider's attributeCondition; "" when nothing narrows it.
attribute_condition = lambda b: Binding -> str {
  _c = client_of(b)
  _t = ticket_of(b)
  _owner_in_issuer = "{owner}" in _c.issuer and not b.issuerUri
  assert not b.owner or _c.ownerKey or _owner_in_issuer, "${_where(b)}: client ${_c.id} has no owner claim, narrow it with repositories, subjects or condition"
  assert not b.repositories or _c.repositoryKey, "${_where(b)}: client ${_c.id} has no repository claim, narrow it with subjects or condition"
  _parts: [str] = []
  if b.owner and _c.ownerKey:
    _parts += ["${_c.ownerKey} == '${b.owner}'"]

  if b.repositories:
    _parts += ["${_c.repositoryKey} in ${_list(b.repositories)}"]

  if b.subjects:
    _parts += ["assertion.sub in ${_list(b.subjects)}"]

  if _t:
    assert _c.triggerClaim, "${_where(b)}: ${_c.label} tokens carry no trigger claim, so runs started by ${_t.label} cannot be told apart; bind ${_c.id} without a ticket and narrow it with repositories"
    assert _c.triggerClaim in _t.triggers, "${_where(b)}: ${_t.label} has no ${_c.triggerClaim} triggers (it has ${', '.join([_k for _k in _t.triggers])})"
    _parts += ["assertion.${_c.triggerClaim} in ${_list(_t.triggers[_c.triggerClaim])}"]

  if b.workflows:
    assert _c.workflowKey, "${_where(b)}: ${_c.label} tokens carry no workflow claim, narrow it with repositories or condition"
    _w = ["${_c.workflowKey} == '${_x}'" if "@" in _x else "${_c.workflowKey}.startsWith('${_x}@')" for _x in b.workflows]
    _parts += [_w[0] if len(_w) == 1 else "(" + " || ".join(_w) + ")"]

  # Shared issuer on its default host: owner, repositories or subjects are
  # mandatory (a ticket trigger alone admits every tenant's dispatches).
  _shared = _c.multiTenant and not b.host and not b.issuerUri
  assert not _shared or b.condition or (b.owner and _c.ownerKey) or b.repositories or b.subjects or b.workflows, "${_where(b)}: ${_c.issuer} is shared by every ${_c.label} user; set owner, repositories, subjects, workflows or condition"
  if b.condition:
    _parts += ["(${b.condition})" if _parts else b.condition]

  " && ".join(_parts)
}

# One Fabric-shaped provider entry.
provider_spec = lambda b: Binding -> {str:} {
  _c = client_of(b)
  _cond = attribute_condition(b)
  _aud = b.audiences or _c.audiences
  assert not _c.requireAudiences or _aud, "${_where(b)}: ${_c.label} tokens carry a vendor audience, set `audiences`"
  _name = "${_c.label} Provider"
  assert len(_name) <= 32, "${_where(b)}: provider display name '${_name}' is over GCP's 32 characters, shorten the client label"
  {
    displayName = _name
    attributeMapping = _c.attributeMapping | (b.attributeMapping or {})
    if _cond:
      attributeCondition = _cond
    identityProvider = {
      oidc = {
        issuerUri = issuer_uri(b)
        if _aud:
          allowedAudiences = _aud
      }
    }
  }
}

_pool_display = lambda b: Binding -> str {
  _c = client_of(b)
  _t = ticket_of(b)
  b.displayName or ("${_t.label} via ${_c.label}" if _t else "${_c.label} Pool")
}

_pool_description = lambda b: Binding -> str {
  _c = client_of(b)
  _t = ticket_of(b)
  b.description or ("Identity pool for ${_t.label} automations run by ${_c.label}" if _t else "Identity pool for ${_c.label} integrations")
}

_disjoint = lambda xs: [str], ys: [str] -> bool {
  bool(xs) and bool(ys) and not any _x in xs {
    _x in ys
  }
}

# Two ticket bindings of different systems admit the same tokens unless
# something in the token tells them apart: issuer, trigger values, pinned
# workflows (any ref = the part before "@"), repositories, or a hand-written
# condition (trusted, not analysed).
_separated = lambda a: Binding, b: Binding -> bool {
  _ca = client_of(a)
  _ta = ticket_of(a)
  _tb = ticket_of(b)
  issuer_uri(a) != issuer_uri(b) or bool(a.condition) or bool(b.condition) or _disjoint(_ta.triggers[_ca.triggerClaim], _tb.triggers[client_of(b).triggerClaim]) or _disjoint([_w.split("@")[0] for _w in a.workflows], [_w.split("@")[0] for _w in b.workflows]) or _disjoint(a.repositories, b.repositories) or _disjoint(a.subjects, b.subjects)
}

# bindings -> {pool id: {displayName, description, providers: {provider id: ...}}}
expand = lambda bindings: [any] -> {str:} {
  _bs = [Binding {**_b} for _b in bindings]
  _keys = ["${pool_id(_b)}/${provider_id(_b)}" for _b in _bs]
  _dups = sorted({_k: None for _i, _k in _keys if _k in _keys[:_i:]})
  assert not _dups, "workload identity providers bound twice: ${_dups}"
  _bad = [_id for _id in _keys if not all_true([regex.match(_x, _id_pattern) and not _x.startswith("gcp-") for _x in _id.split("/")])]
  assert not _bad, "workload identity pool/provider ids must be 4-32 of [a-z0-9-] and not start with gcp-: ${_bad}"
  _pools = [pool_id(_b) for _b in _bs]
  _first = {_p: [_b for _b in _bs if pool_id(_b) == _p][0] for _p in _pools}
  _late = ["${pool_id(_b)}/${provider_id(_b)}" for _i, _b in _bs if (_b.displayName or _b.description) and pool_id(_b) in _pools[:_i:]]
  assert not _late, "only the first binding of a pool may set displayName/description: ${_late}"
  _long = [_pool_display(_f) for _, _f in _first if len(_pool_display(_f)) > 32]
  assert not _long, "pool display names over GCP's 32 characters, set displayName: ${_long}"
  # Each binding's own errors (missing trigger claim, ...) before comparing them.
  _conds = [attribute_condition(_b) for _b in _bs]
  _ticketed = [_b for _b in _bs if ticket_of(_b)]
  _same = ["${ticket_of(_y).label} (${pool_id(_y)}) and ${ticket_of(_x).label} (${pool_id(_x)})" for _i, _x in _ticketed for _y in _ticketed[:_i:] if ticket_of(_x).id != ticket_of(_y).id and not _separated(_x, _y)]
  assert not _same, "ticket pools that admit the same tokens: ${_same}; pin each to its own `workflows` or disjoint `repositories`"
  {_p: {
    displayName = _pool_display(_f)
    description = _pool_description(_f)
    providers = {provider_id(_b): provider_spec(_b) for _b in _bs if pool_id(_b) == _p}
  } for _p, _f in _first}
}

# The explicit Fabric map plus the expanded bindings; a pool id in both is an error.
merge = lambda pools: {str:}, bindings: [any] -> {str:} {
  _short = expand(bindings or [])
  _both = [_p for _p in _short if _p in (pools or {})]
  assert not _both, "pools both in workloadIdentityPools and workloadIdentity: ${_both}"
  (pools or {}) | _short
}

# ── Access: a binding granted something on one cloud resource ────────────────
schema Access(Binding):
  """A Binding plus what it may do; each cloud backend maps `role` onto its own roles or actions."""
  role: "read" | "write" | "admin" = "read"

# Validated entries: ids, narrowing and ticket overlap are checked by expand,
# exactly as for GCP pools, whichever cloud the entries end up on.
access_list = lambda entries: [any] -> [Access] {
  _es = entries or []
  _pools = expand([{_k: _v for _k, _v in _e if _k != "role"} for _e in _es])
  [Access {**_e} for _e in _es if _pools != None]
}

# Stable name of an entry's composed resources: its pool id, plus the provider
# id when one is set (entries may share a pool).
access_name = lambda b: Binding -> str {
  pool_id(b) + ("-${b.provider}" if b.provider else "")
}

# The issuer without its scheme: the IAM OIDC provider's URL and the prefix of
# its AWS condition keys.
issuer_host = lambda b: Binding -> str {
  issuer_uri(b)[len("https://")::]
}

# Audiences a token must carry on `cloud` ("gcp" | "aws" | "azure"). GCP's
# default (the provider's resource name) needs no list; AWS and Azure do.
audiences_for = lambda b: Binding, cloud: str -> [str] {
  _c = client_of(b)
  _aud = b.audiences or (_c.cloudAudiences[cloud] if cloud in _c.cloudAudiences else []) or _c.audiences
  assert cloud == "gcp" or _aud, "${_where(b)}: set `audiences`; ${_c.label} has no default audience on ${cloud} (it is whatever the pipeline requests its token for)"
  _aud
}

# GCP IAM members for the binding's pool in project `projectNumber`: each
# subject, else each repository (when the client maps it to an attribute),
# else the whole pool. The pool's provider condition already enforces owner,
# workflows, ticket trigger and `condition`.
gcp_members = lambda b: Binding, projectNumber: str -> [str] {
  _c = client_of(b)
  _pool = "iam.googleapis.com/projects/${projectNumber}/locations/global/workloadIdentityPools/${pool_id(b)}"
  _attr = _c.repositoryKey if _c.repositoryKey and _c.repositoryKey.startswith("attribute.") else ""
  _members = ["principalSet://${_pool}/*"]
  if b.subjects:
    _members = ["principal://${_pool}/subject/${_s}" for _s in b.subjects]
  elif b.repositories and _attr:
    _members = ["principalSet://${_pool}/${_attr}/${_r}" for _r in b.repositories]

  _members
}

# `<host>:sub` patterns of an AWS trust: `subjects` as given, else one pattern
# per repository, else the owner's. A ticket, workflows or condition is not in
# the default sub claim, so without `subjects` it fails here.
aws_subjects = lambda b: Binding -> [str] {
  _c = client_of(b)
  _subs = b.subjects
  if not _subs:
    _gcp_only = [_k for _k, _on in {ticket = bool(ticket_of(b)), workflows = bool(b.workflows), condition = bool(b.condition)} if _on]
    assert not _gcp_only, "${_where(b)}: ${', '.join(_gcp_only)} cannot be expressed in an AWS trust policy, which sees only the token's sub and aud; customize the sub claim to carry it (GitHub: PUT /repos/{owner}/{repo}/actions/oidc/customization/sub, include_claim_keys e.g. [repo, context, job_workflow_ref]) and list the resulting values in `subjects`"
    if b.repositories:
      assert _c.subjectByRepository, "${_where(b)}: ${_c.label} has no sub pattern per repository; list `subjects`"
      _subs = [_c.subjectByRepository.replace("{repo}", _r) for _r in b.repositories]
    else:
      assert b.owner and _c.subjectByOwner, "${_where(b)}: an AWS trust needs `subjects`, `repositories` or an `owner` ${_c.label} has a sub pattern for"
      _subs = [_c.subjectByOwner.replace("{owner}", b.owner)]

  _subs
}

# The trust policy of an IAM role: the account's IAM OIDC provider for the
# binding's issuer (it must exist, one per issuer and account), aud, sub.
aws_trust = lambda b: Binding, accountId: str -> {str:} {
  _host = issuer_host(b)
  {
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {Federated = "arn:aws:iam::${accountId}:oidc-provider/${_host}"}
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {"${_host}:aud" = audiences_for(b, "aws")}
        StringLike = {"${_host}:sub" = aws_subjects(b)}
      }
    }]
  }
}

# Subjects of Azure federated identity credentials: matched exactly, no
# wildcards, at most 20 per identity — so they are always listed explicitly.
azure_subjects = lambda b: Binding -> [str] {
  assert b.subjects, "${_where(b)}: Azure federated credentials match the token's sub exactly, without wildcards; list `subjects` (e.g. repo:acme/app:ref:refs/heads/main, project_path:acme/app:ref_type:branch:ref:main, sc://org/project/connection)"
  assert len(b.subjects) <= 20, "${_where(b)}: an Azure identity holds at most 20 federated credentials, got ${len(b.subjects)} subjects"
  b.subjects
}
