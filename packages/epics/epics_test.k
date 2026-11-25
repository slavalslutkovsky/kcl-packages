# Tests for the epics map-reduce: which epics deploy, the per-customer
# reduce, placement, the Jira-derived labels, the errors a bad label raises,
# and the report.
# Run: kcl test
import file
import runtime
import yaml

# NOTE: test helpers share the package scope with lib.k (and the leading
# underscore is normalised), so every helper here is prefixed `_fx`.
_fxCatalog = {
  web = {
    app = {kind = "ui", image = "r/web:1"}
  }
  api = {app = {kind = "api", image = "r/api:2", uses = ["db"]}, resources = {databases = [{name = "db", spec = {memoryGb = 2}}]}}
  job = {app = {kind = "cli", image = "r/api:2", uses = ["db"]}, resources = {databases = [{name = "db", spec = {memoryGb = 8}}], caches = [{name = "cache"}]}}
}

_fxConfig = lambda _fxEpics: [{str:}] {
  Config {
    cloud = {provider = "aws", region = "eu-west-1"}
    catalog = _fxCatalog
    epics = _fxEpics
  }
}

_fxEpic = lambda _fxKey: str, _fxCat: str, _fxLabels: [str] {
  {key = _fxKey, project_key = "PLAT", status = _fxCat, status_category = _fxCat, labels = _fxLabels}
}

_fxProject = lambda _fxOut, _fxName: str {
  [o for o in _fxOut if o.kind == "Project" and o.metadata.name == _fxName][0]
}

_fxErr = lambda _fxEpics: [{str:}] {
  runtime.catch(lambda {
    render(_fxConfig(_fxEpics))
  })
}

# ── Map: which epics deploy ──────────────────────────────────────────────────
test_only_deployment_epics_in_a_deploying_category = lambda {
  _out = render(_fxConfig([
    _fxEpic("PLAT-1", "In Progress", ["customer-acme", "app-web"])
    _fxEpic("PLAT-2", "To Do", ["customer-initech", "app-web"])
    _fxEpic("PLAT-3", "In Progress", ["security", "platform"])
    {key = "PLAT-4", issue_type = "Story", status_category = "Done", labels = ["customer-umbrella", "app-web"]}
  ]))
  assert [o.metadata.name for o in _out] == ["acme", "acme"], "only PLAT-1: To Do waits, unlabelled epics are planning, non-epics are not read"
  assert [o.kind for o in _out] == ["Namespace", "Project"]
}

test_custom_vocabulary = lambda {
  _c = _fxConfig([_fxEpic("OPS-7", "Done", ["Client:Acme", "Svc:web", "Tier:Team"])]) | {
    vocabulary = Vocabulary {customer = "client:", app = "svc:", plan = "tier:"}
  }
  _p = _fxProject(render(_c), "acme")
  assert _p.spec.apps[0].name == "web" and _p.metadata.labels["platform.example.org/plan"] == "team", "prefixes are configurable and case-insensitive"
}

# ── Reduce: one tenant per customer ──────────────────────────────────────────
test_reduce_merges_epics_per_customer = lambda {
  _out = render(_fxConfig([
    _fxEpic("PLAT-1", "In Progress", ["customer-acme", "app-web", "app-api"])
    _fxEpic("PLAT-2", "Done", ["customer-acme", "plan-team", "app-job"])
  ]))
  _p = _fxProject(_out, "acme")
  assert [a.name for a in _p.spec.apps] == ["api", "job", "web"]
  assert _p.metadata.annotations["jira.shluviza.com/epics"] == "PLAT-1,PLAT-2"
  assert _p.metadata.labels["platform.example.org/plan"] == "team", "the highest plan among a customer's epics wins"
  # Resources are a union by name; the first app (sorted) declaring one wins.
  assert _p.spec.databases == [{name = "db", spec = {memoryGb = 2}}]
  assert _p.spec.caches == [{name = "cache"}]
}

test_paying_customers_get_dedicated_nodes = lambda {
  _out = render(_fxConfig([
    _fxEpic("PLAT-1", "Done", ["customer-acme", "plan-enterprise", "app-web"])
    _fxEpic("PLAT-2", "Done", ["customer-globex", "app-web"])
  ]))
  _paid = _fxProject(_out, "acme").spec.placement
  assert _paid.nodeSelector == {"platform.example.org/dedicated" = "acme"}
  assert _paid.tolerations == [{key = "platform.example.org/dedicated", operator = "Equal", value = "acme", effect = "NoSchedule"}]
  _free = _fxProject(_out, "globex").spec.placement
  assert _free.nodeSelector == {"platform.example.org/pool" = "shared"} and "tolerations" not in _free, "a free tenant tolerates nothing"
  assert [o for o in _out if o.kind == "Namespace" and o.metadata.name == "acme"][0].metadata.labels["platform.example.org/placement"] == "dedicated"
}

# ── Labels and freeze ────────────────────────────────────────────────────────
test_jira_labels_reach_each_app = lambda {
  _out = render(_fxConfig([
    _fxEpic("PLAT-1", "Done", ["customer-acme", "app-web", "alert-critical", "oncall-payments", "cost-center-4711"])
    _fxEpic("PLAT-2", "Done", ["customer-acme", "app-api"])
  ]))
  _apps = {a.name: a for a in _fxProject(_out, "acme").spec.apps}
  assert _apps.web.labels == {"jira.shluviza.com/epic" = "PLAT-1", "jira.shluviza.com/project" = "PLAT", "jira.shluviza.com/alert" = "critical", "sre.shluviza.com/oncall" = "payments", "finops.shluviza.com/cost-center" = "4711"}
  assert _apps.api.labels == {"jira.shluviza.com/epic" = "PLAT-2", "jira.shluviza.com/project" = "PLAT"}, "labels follow the epic, not the customer"
  assert _apps.web.image == "r/web:1", "the catalog entry is the app"
}

test_freeze_pauses_the_customer_project = lambda {
  _out = render(_fxConfig([
    _fxEpic("PLAT-1", "Done", ["customer-acme", "app-web", "FREEZE"])
    _fxEpic("PLAT-2", "Done", ["customer-acme", "app-api"])
  ]))
  _p = _fxProject(_out, "acme")
  assert _p.metadata.annotations["crossplane.io/paused"] == "true"
  assert [a.labels["jira.shluviza.com/freeze"] for a in _p.spec.apps if a.name == "web"] == ["true"]
  assert "jira.shluviza.com/freeze" not in [a for a in _p.spec.apps if a.name == "api"][0].labels
}

# ── Bad data fails the render, naming the epic ───────────────────────────────
test_bad_labels_fail_with_the_epic_key = lambda {
  assert "no customer-<id>" in _fxErr([_fxEpic("PLAT-1", "Done", ["app-web"])])
  assert "2 customer labels" in _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a", "customer-b", "app-web"])])
  assert "app-nope not in the catalog" in _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a", "app-nope"])])
  assert "plan-gold is not a plan" in _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a", "plan-gold", "app-web"])])
  assert "alert-page is not a level" in _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a", "alert-page", "app-web"])])
  assert "lowercase DNS label" in _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a_b", "app-web"])])
  _dup = _fxErr([_fxEpic("PLAT-1", "Done", ["customer-a", "app-web"]), _fxEpic("PLAT-2", "Done", ["customer-a", "app-web"])])
  assert "app web is in PLAT-1, PLAT-2" in _dup, _dup
  # Planning epics and waiting epics are never validated: their labels are not deployments.
  assert render(_fxConfig([_fxEpic("PLAT-1", "To Do", ["app-nope"])])) == []
}

# ── Second reduce: the report ────────────────────────────────────────────────
test_report = lambda {
  _r = report(_fxConfig([
    _fxEpic("PLAT-1", "Done", ["customer-acme", "plan-team", "app-web", "app-api"])
    _fxEpic("PLAT-2", "Done", ["customer-globex", "app-web", "freeze"])
    _fxEpic("PLAT-3", "To Do", ["customer-initech", "app-web"])
    _fxEpic("PLAT-4", "Done", ["planning"])
  ]))
  assert _r.summary == {epics = 4, deploymentEpics = 3, deployed = 2, customers = 2, dedicated = 1, shared = 1, frozen = 1, apps = 3, byKind = {api = 1, ui = 2}, byPlan = {free = 1, team = 1}}
  assert _r.dedicatedNodes == [{customer = "acme", plan = "team", label = "platform.example.org/dedicated=acme", taint = "platform.example.org/dedicated=acme:NoSchedule"}]
  assert _r.waiting == [{key = "PLAT-3", status = "To Do", category = "To Do"}]
}

# ── Example files ────────────────────────────────────────────────────────────
test_examples_render = lambda {
  _fxValues = yaml.decode(file.read("examples/values.yaml"))
  _c = Config {**(_fxValues | {epics = yaml.decode(file.read("examples/epics.json")).epics})}
  _out = render(_c)
  assert sorted([o.metadata.name for o in _out if o.kind == "Project"]) == ["acme", "globex"]
  assert report(_c).waiting[0].key == "PLAT-30"
}
