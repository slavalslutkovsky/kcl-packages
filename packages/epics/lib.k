"""
Epics — Jira epics in, tenant apps out. A map-reduce over the epic export
(`atlassian-ingest export-epics`), rendered into one `Project` XR per
customer (packages/platform/project) plus its Namespace.

  epics.json ──► map ──► [AppRecord…] ──► reduce ──► [Tenant…] ──► [Namespace, Project]…
                 (one per app label        (one per customer:          ──► report (-D report=true)
                  of a deployment epic)     plan, apps, resources,          a second reduce over
                                            placement, freeze)              all tenants

JIRA IS READ-ONLY. Epics are the only issue type; their existing statuses
are read, never changed, and nothing is written back. An epic is a
DEPLOYMENT epic when it carries at least one `app-<name>` label; every other
epic is ordinary planning and is ignored (and counted in the report). Its
status CATEGORY gates it: by default "In Progress" and "Done" deploy, "To Do"
does not — no new statuses, no new issue types.

JIRA LABELS → MEANING (prefixes configurable, `Vocabulary`):

  customer-<id>                 the tenant: namespace and Project `<id>`
  plan-<free|team|enterprise>   paying (team, enterprise) → dedicated nodes
  app-<catalog name>            deploy that catalog app for the customer
  cost-center-<x>               finops.shluviza.com/cost-center
  oncall-<team>                 sre.shluviza.com/oncall
  alert-<critical|warning>      jira.shluviza.com/alert (acted on by epic-watch)
  freeze                        jira.shluviza.com/freeze, and the customer's
                                Project is paused (crossplane.io/paused)

Everything a label can decide is decided HERE, at render time. The kube-rs
controller `epic-watch` (apps/operators/epic-watch) only reacts to live state
of the labelled workloads (degraded → alert event, frozen workload changed →
audit event); it never reads Jira either.

PLACEMENT IS SCHEDULING ONLY. A paying customer's pods get a nodeSelector
`<dedicatedLabel>=<customer>` and a matching NoSchedule toleration; everyone
else gets the shared pool's nodeSelector. The nodes must already carry those
labels and taints — the report lists exactly which ones.
"""

import regex

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Epic:
  """One row of the export: curated `jira_issues` columns plus `labels`."""
  key: str
  project_key?: str
  issue_type: str = "Epic"
  status?: str
  status_category?: str
  summary?: str
  updated?: str
  labels: [str] = []

schema Vocabulary:
  """Jira label prefixes (and the one exact label) this package reads. Matching is case-insensitive."""
  customer: str = "customer-"
  plan: str = "plan-"
  app: str = "app-"
  costCenter: str = "cost-center-"
  oncall: str = "oncall-"
  alert: str = "alert-"
  freeze: str = "freeze"

schema CatalogApp:
  """
    What `app-<name>` deploys. `app` is a Project app entry without `name`
    (the catalog key is the name): kind, image, port, uses, identity, route,
    overrides, ... `resources` are the Project resource lists the app needs
    (`databases`, `caches`, `queues`, `buckets`, `registries`); a customer
    with several apps gets their union, one entry per resource name.
    """
  app: {str:}
  resources: {str:[{str:}]} = {}

  check:
    "name" not in app, "a catalog app is named by its catalog key, not by app.name"
    "kind" in app and "image" in app, "a catalog app needs at least `kind` and `image`"
    all_true([_k in ["databases", "caches", "queues", "buckets", "registries"] for _k in resources]), "catalog resources are databases, caches, queues, buckets or registries"

schema Placement:
  """Where tenants' pods go. Scheduling only: nodes are labelled and tainted by whoever runs the cluster."""
  # Plans that pay for dedicated nodes.
  dedicatedPlans: [str] = ["team", "enterprise"]
  # Node label (and taint key) that marks a customer's dedicated nodes.
  dedicatedLabel: str = "platform.example.org/dedicated"
  # nodeSelector of the shared pool; {} schedules shared tenants anywhere untainted.
  sharedNodeSelector: {str:str} = {"platform.example.org/pool" = "shared"}

schema Config:
  """One values file: the catalog and the rules; the epics usually come from `-D data=`."""
  environment?: str
  # Project spec.cloud for every tenant (provider, region, ...).
  cloud: {str:}
  # Epic status categories that deploy. Jira's are "To Do", "In Progress", "Done".
  deployCategories: [str] = ["In Progress", "Done"]
  vocabulary: Vocabulary = Vocabulary {}
  placement: Placement = Placement {}
  catalog: {str:CatalogApp}
  epics: [Epic] = []

  check:
    all_true([regex.match(_n, _dns) for _n in catalog]), "catalog names are app names: lowercase DNS labels"

_dns = r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
# A Kubernetes label value: ≤ 63 chars, alphanumeric ends, - _ . inside.
_labelValue = r"^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$"
plan_rank = {free = 0, team = 1, enterprise = 2}
alert_levels = ["critical", "warning"]

# ── Map ──────────────────────────────────────────────────────────────────────
# Values of every label with this prefix, lower-cased, prefix stripped.
_labelValues = lambda e: Epic, prefix: str -> [str] {
  [_l.lower()[len(prefix)::] for _l in e.labels if _l.lower().startswith(prefix.lower()) and len(_l) > len(prefix)]
}

_one = lambda e: Epic, prefix: str, what: str -> str {
  _v = _labelValues(e, prefix)
  assert len(_v) <= 1, "epic ${e.key} has ${len(_v)} ${what} labels (${', '.join([prefix + _x for _x in _v])}); keep one"
  _v[0] if _v else ""
}

is_deployment = lambda c: Config, e: Epic -> bool {
  e.issue_type.lower() == "epic" and len(_labelValues(e, c.vocabulary.app)) > 0
}

deploys = lambda c: Config, e: Epic -> bool {
  is_deployment(c, e) and (e.status_category or "") in c.deployCategories
}

# The labels one epic puts on each of its apps.
epic_labels = lambda c: Config, e: Epic -> {str:str} {
  _v = c.vocabulary
  _cc = _one(e, _v.costCenter, "cost-center")
  _on = _one(e, _v.oncall, "oncall")
  _al = _one(e, _v.alert, "alert")
  _frozen = _v.freeze.lower() in [_l.lower() for _l in e.labels]
  assert not _al or _al in alert_levels, "epic ${e.key}: ${_v.alert}${_al} is not a level (${', '.join(alert_levels)})"
  _out = {
    "jira.shluviza.com/epic" = e.key
    if e.project_key:
      "jira.shluviza.com/project" = e.project_key
    if _al:
      "jira.shluviza.com/alert" = _al
    if _frozen:
      "jira.shluviza.com/freeze" = "true"
    if _on:
      "sre.shluviza.com/oncall" = _on
    if _cc:
      "finops.shluviza.com/cost-center" = _cc
  }
  _bad = [_k for _k in _out if not regex.match(_out[_k], _labelValue)]
  assert not _bad, "epic ${e.key}: not a valid Kubernetes label value for ${_bad}"
  _out
}

# map: one deployment epic → one record per app label.
map_epic = lambda c: Config, e: Epic -> [{str:}] {
  _v = c.vocabulary
  _customer = _one(e, _v.customer, "customer")
  _plan = _one(e, _v.plan, "plan") or "free"
  _apps = _labelValues(e, _v.app)
  assert _customer, "deployment epic ${e.key} has no ${_v.customer}<id> label: whose apps are ${_apps}?"
  assert regex.match(_customer, _dns), "epic ${e.key}: customer '${_customer}' must be a lowercase DNS label — it names the namespace"
  assert _plan in plan_rank, "epic ${e.key}: ${_v.plan}${_plan} is not a plan (${', '.join([_p for _p in plan_rank])})"
  _unknown = [_a for _a in _apps if _a not in c.catalog]
  assert not _unknown, "epic ${e.key}: ${', '.join([_v.app + _a for _a in _unknown])} not in the catalog (${', '.join(sorted([_n for _n in c.catalog]))})"
  _labels = epic_labels(c, e)
  [{
    customer = _customer
    plan = _plan
    epic = e.key
    frozen = "jira.shluviza.com/freeze" in _labels
    app = _a
    labels = _labels
  } for _a in _apps]
}

# ── Reduce ───────────────────────────────────────────────────────────────────
_maxPlan = lambda plans: [str] -> str {
  [_p for _p in ["enterprise", "team", "free"] if _p in plans][0]
}

# Union of resource lists, one entry per name; the first declaration wins.
_mergeResources = lambda c: Config, apps: [str] -> {str:[{str:}]} {
  _decls = [{list = _k, entry = _r} for _a in apps for _k in sorted([_x for _x in c.catalog[_a].resources]) for _r in c.catalog[_a].resources[_k]]
  {_k: [_d.entry for _i, _d in _decls if _d.list == _k and _d.entry.name not in [_p.entry.name for _p in _decls[:_i:] if _p.list == _k]] for _k in sorted({_d.list: 1 for _d in _decls})}
}

placement_for = lambda c: Config, customer: str, plan: str -> {str:} {
  _p = c.placement
  {
    kind = "dedicated"
    nodeSelector = {"${_p.dedicatedLabel}" = customer}
    tolerations = [{key = _p.dedicatedLabel, operator = "Equal", value = customer, effect = "NoSchedule"}]
  } if plan in _p.dedicatedPlans else {
    kind = "shared"
    nodeSelector = _p.sharedNodeSelector
    tolerations = []
  }
}

# reduce: every record of one customer → one tenant.
reduce_customer = lambda c: Config, customer: str, records: [{str:}] -> {str:} {
  _apps = [_r.app for _r in records]
  _dups = sorted({_a: 1 for _i, _a in _apps if _a in _apps[:_i:]})
  assert not _dups, "customer ${customer}: " + "; ".join(["app ${_a} is in ${', '.join([_r.epic for _r in records if _r.app == _a])}" for _a in _dups]) + " — one epic per app"
  _plan = _maxPlan([_r.plan for _r in records])
  {
    customer = customer
    plan = _plan
    epics = sorted({_r.epic: 1 for _r in records})
    frozen = any _r in records {
      _r.frozen
    }
    placement = placement_for(c, customer, _plan)
    apps = [[_r for _r in records if _r.app == _a][0] for _a in sorted(_apps)]
    resources = _mergeResources(c, sorted(_apps))
  }
}

# The whole pipeline: filter → map → shuffle by customer → reduce.
tenants = lambda c: Config -> [{str:}] {
  _records = [_r for _e in c.epics if deploys(c, _e) for _r in map_epic(c, _e)]
  _customers = sorted({_r.customer: 1 for _r in _records})
  [reduce_customer(c, _cu, [_r for _r in _records if _r.customer == _cu]) for _cu in _customers]
}

# ── Render ───────────────────────────────────────────────────────────────────
_tenantLabels = lambda t: {str:} -> {str:str} {
  {
    "platform.example.org/customer" = t.customer
    "platform.example.org/plan" = t.plan
    "platform.example.org/placement" = t.placement.kind
    "app.kubernetes.io/managed-by" = "epics"
  }
}

namespace = lambda t: {str:} -> {str:} {
  {
    apiVersion = "v1"
    kind = "Namespace"
    metadata = {name = t.customer, labels = _tenantLabels(t)}
  }
}

project = lambda c: Config, t: {str:} -> {str:} {
  _res = t.resources
  {
    apiVersion = "platform.example.org/v1alpha1"
    kind = "Project"
    metadata = {
      name = t.customer
      namespace = t.customer
      labels = _tenantLabels(t)
      annotations = {
        "jira.shluviza.com/epics" = ",".join(t.epics)
        # A frozen epic freezes its customer's whole Project: Crossplane
        # stops reconciling it, so nothing the next render changes rolls
        # out until the label is gone.
        if t.frozen:
          "crossplane.io/paused" = "true"
      }
    }
    spec = {
      client = t.customer
      if c.environment:
        environment = c.environment
      cloud = c.cloud
      labels = {_k: _v for _k, _v in _tenantLabels(t) if _k != "app.kubernetes.io/managed-by"}
      placement = {
        nodeSelector = t.placement.nodeSelector
        if t.placement.tolerations:
          tolerations = t.placement.tolerations
      }
      apps = [{name = _r.app, labels = _r.labels, **c.catalog[_r.app].app} for _r in t.apps]
    } | _res
  }
}

render = lambda c: Config -> [any] {
  [_o for _t in tenants(c) for _o in [namespace(_t), project(c, _t)]]
}

# ── Second reduce: the report ────────────────────────────────────────────────
report = lambda c: Config -> {str:} {
  _ts = tenants(c)
  _kinds = [c.catalog[_r.app].app.kind for _t in _ts for _r in _t.apps]
  {
    summary = {
      epics = len(c.epics)
      deploymentEpics = len([_e for _e in c.epics if is_deployment(c, _e)])
      deployed = len([_e for _e in c.epics if deploys(c, _e)])
      customers = len(_ts)
      dedicated = len([_t for _t in _ts if _t.placement.kind == "dedicated"])
      shared = len([_t for _t in _ts if _t.placement.kind == "shared"])
      frozen = len([_t for _t in _ts if _t.frozen])
      apps = len(_kinds)
      byKind = {_k: len([_x for _x in _kinds if _x == _k]) for _k in sorted({_x: 1 for _x in _kinds})}
      byPlan = {_p: len([_t for _t in _ts if _t.plan == _p]) for _p in sorted({_t.plan: 1 for _t in _ts})}
    }
    # What ops must have done before the dedicated tenants schedule.
    dedicatedNodes = [{
      customer = _t.customer
      plan = _t.plan
      label = "${c.placement.dedicatedLabel}=${_t.customer}"
      taint = "${c.placement.dedicatedLabel}=${_t.customer}:NoSchedule"
    } for _t in _ts if _t.placement.kind == "dedicated"]
    sharedNodeSelector = c.placement.sharedNodeSelector
    tenants = [{
      customer = _t.customer
      plan = _t.plan
      placement = _t.placement.kind
      frozen = _t.frozen
      epics = _t.epics
      apps = [_r.app for _r in _t.apps]
      resources = sorted([_r.name for _k in _t.resources for _r in _t.resources[_k]])
    } for _t in _ts]
    # Deployment epics whose status category does not deploy (yet).
    waiting = [{key = _e.key, status = _e.status or "", category = _e.status_category or ""} for _e in c.epics if is_deployment(c, _e) and not deploys(c, _e)]
  }
}
