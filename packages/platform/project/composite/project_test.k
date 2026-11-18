# Tests for the project composition: backend selection per cloud, the
# children's specs, the six app kinds, wiring and gating from observed status,
# Dapr components, validation and status.
# Run: kcl test
import file
import runtime
import yaml
import .project

_fxAnno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# NOTE: KCL normalizes the leading underscore, so a test helper shadows any
# lambda parameter or private helper of the same normalized name in project.k
# (`_app` would shadow its app renderer, `_ctx` a `ctx` parameter). Every
# helper here is prefixed `_fx` for that reason.
_fxBuild = lambda _fxSpec {
  {apiVersion = "platform.example.org/v1alpha1", kind = "Project", metadata = {name = "shop", namespace = "acme"}, spec = _fxSpec}
}

_fxAws = {client = "acme", cloud = {provider = "aws", region = "eu-west-1", oidcIssuer = "arn:aws:iam::1:oidc-provider/x"}}
_fxAzure = {client = "acme", cloud = {provider = "azure", region = "westeurope", resourceGroup = "acme-rg", oidcIssuer = "https://issuer/"}}

_fxPick = lambda _fxItems, _fxKey: str {
  [i for i in _fxItems if i.metadata.annotations[_fxAnno] == _fxKey][0]
}

_fxHas = lambda _fxItems, _fxKey: str {
  len([i for i in _fxItems if i.metadata.annotations[_fxAnno] == _fxKey]) > 0
}

_fxKinds = lambda _fxItems, _fxApp: str {
  [i.kind for i in _fxItems if i.metadata.annotations[_fxAnno].startswith("app.${_fxApp}.")]
}

_fxReady = lambda _fxSt {
  {
    Resource = {status = {ready = True} | _fxSt}
  }
}

_fxEnv = lambda _fxTemplate {
  {e.name: e for e in _fxTemplate.spec.containers[0].env or []}
}

_fxErr = lambda _fxSpec {
  runtime.catch(lambda {
    project.render(_fxBuild(_fxSpec))
  })
}

# ── Backends ─────────────────────────────────────────────────────────────────
test_backends_follow_the_cloud = lambda {
  _resources = {databases = [{name = "db"}], caches = [{name = "cache"}], buckets = [{name = "files"}], registries = [{name = "images"}]}
  _onAws = project.render(_fxBuild(_fxAws | _resources))
  _onAzure = project.render(_fxBuild(_fxAzure | _resources))
  _sel = lambda _fxItems, _fxKey: str {
    _fxPick(_fxItems, _fxKey).spec.crossplane.compositionSelector.matchLabels.provider
  }
  assert [_sel(_onAws, k) for k in ["database.db", "cache.cache", "bucket.files", "registry.images"]] == ["aws", "aws", "aws", "aws"]
  # Azure has no cache backend: valkey runs it in-cluster.
  assert [_sel(_onAzure, k) for k in ["database.db", "cache.cache", "bucket.files", "registry.images"]] == ["azure", "valkey", "azure", "azure"]
  # An explicit in-cluster backend is allowed on either cloud.
  _cnpg = project.render(_fxBuild(_fxAws | {databases = [{name = "db", backend = "cnpg"}]}))
  assert _sel(_cnpg, "database.db") == "cnpg"
}

test_a_backend_never_crosses_clouds = lambda {
  _foreign = _fxErr(_fxAws | {databases = [{name = "db", backend = "azure"}]})
  assert "db: azure" in _foreign, "an aws project must not compose an azure database, got: ${_foreign}"
  _queue = _fxErr(_fxAzure | {queues = [{name = "jobs"}]})
  assert "no Queue backend runs on azure" in _queue, "a queue on azure has nowhere to go, got: ${_queue}"
}

test_resource_group_only_where_azure_needs_it = lambda {
  _out = project.render(_fxBuild(_fxAzure | {databases = [{name = "db"}], caches = [{name = "cache"}], buckets = [{name = "files"}], registries = [{name = "images"}]}))
  assert _fxPick(_out, "database.db").spec.resourceGroup == "acme-rg"
  assert _fxPick(_out, "registry.images").spec.resourceGroup == "acme-rg"
  assert "resourceGroup" not in _fxPick(_out, "bucket.files").spec, "the Bucket XRD has no resourceGroup"
  assert "resourceGroup" not in _fxPick(_out, "cache.cache").spec, "valkey is in-cluster"
  _missing = _fxErr({client = "acme", cloud = {provider = "azure", region = "westeurope"}, databases = [{name = "db"}]})
  assert "resourceGroup is required" in _missing, _missing
}

test_resource_spec_overrides_defaults_but_keeps_identity_tags = lambda {
  _out = project.render(_fxBuild(_fxAws | {
    environment = "prod"
    cloud = _fxAws.cloud | {
      tags = {team = "web"}
    }
    databases = [{name = "db", spec = {deletionPolicy = "Orphan", memoryGb = 8, tags = {tier = "gold", client = "someone-else"}, crossplane = {
      compositionSelector = {
        matchLabels = {provider = "gcp"}
      }
    }}}]
  }))
  _db = _fxPick(_out, "database.db").spec
  assert _db.deletionPolicy == "Orphan", "a resource may override the project's deletion policy"
  assert _db.memoryGb == 8 and _db.region == "eu-west-1"
  assert _db.tags == {team = "web", tier = "gold", client = "acme", project = "shop", environment = "prod"}, "spec tags add; project, client and environment always win"
  assert _db.crossplane.compositionSelector.matchLabels.provider == "aws", "the backend is `backend`, never the spec's selector"
}

# ── Identities ───────────────────────────────────────────────────────────────
test_identity_per_cloud = lambda {
  _app = {name = "api", kind = "api", image = "r/api:1.0", identity = {accessPolicies = [{role = "AmazonS3ReadOnlyAccess"}]}}
  _aws = project.render(_fxBuild(_fxAws | {apps = [_app]}), {"identity.api" = _fxReady({})})
  _wi = _fxPick(_aws, "identity.api").spec
  assert _wi.serviceAccount == {name = "api", create = True}
  assert _wi.cluster.oidcIssuer == "arn:aws:iam::1:oidc-provider/x"
  assert "region" not in _wi and "resourceGroup" not in _wi, "the aws backend fails on azure-only fields"
  # The app references the identity's ServiceAccount instead of creating one.
  assert "ServiceAccount" not in _fxKinds(_aws, "api")
  assert _fxPick(_aws, "app.api.deployment.api").spec.template.spec.serviceAccountName == "api"
  assert "azure.workload.identity/use" not in _fxPick(_aws, "app.api.deployment.api").spec.template.metadata.labels

  _azure = project.render(_fxBuild(_fxAzure | {apps = [_app]}), {"identity.api" = _fxReady({})})
  _azWi = _fxPick(_azure, "identity.api").spec
  assert _azWi.region == "westeurope" and _azWi.resourceGroup == "acme-rg"
  assert _fxPick(_azure, "app.api.deployment.api").spec.template.metadata.labels["azure.workload.identity/use"] == "true", "the AKS webhook only injects labelled pods"

  _noIssuer = _fxErr({client = "acme", cloud = {provider = "aws", region = "eu-west-1"}, apps = [_app]})
  assert "oidcIssuer is required" in _noIssuer, _noIssuer
}

# ── App kinds ────────────────────────────────────────────────────────────────
test_app_kinds = lambda {
  _out = project.render(_fxBuild(_fxAws | {apps = [
    {name = "once", kind = "cli", image = "r/cli:1", command = ["/run"]}
    {name = "nightly", kind = "cli", image = "r/cli:1", schedule = "0 2 * * *"}
    {name = "web", kind = "ui", image = "r/web:2"}
    {name = "api", kind = "api", image = "r/api:3"}
    {name = "op", kind = "operator", image = "r/op:4", rules = [{apiGroups = ["x.io"], resources = ["things"], verbs = ["get"]}]}
    {name = "srv", kind = "dapr-server", image = "r/srv:5", port = 50051, dapr = {protocol = "grpc"}}
    {name = "cli", kind = "dapr-client", image = "r/cl:6", dapr = {appId = "client"}}
  ]}))
  assert _fxKinds(_out, "once") == ["Job"]
  assert _fxKinds(_out, "nightly") == ["CronJob"]
  assert _fxKinds(_out, "web") == ["Deployment", "Service"]
  assert _fxKinds(_out, "api") == ["Deployment", "Service"]
  assert _fxKinds(_out, "op") == ["ServiceAccount", "Role", "RoleBinding", "Deployment"], "an operator has no Service, and RBAC in its namespace only"
  assert _fxKinds(_out, "srv") == ["Deployment", "Service"]
  assert _fxKinds(_out, "cli") == ["Deployment"], "nothing calls a dapr client, so no Service"

  _web = _fxPick(_out, "app.web.deployment.web").spec
  assert _web.replicas == 2 and not _web.template.metadata.annotations, "a ui is not scraped"
  _api = _fxPick(_out, "app.api.deployment.api").spec
  assert _api.template.metadata.annotations["prometheus.io/scrape"] == "true"
  assert _api.template.metadata.labels["app.kubernetes.io/version"] == "3", "version follows the image tag"

  _op = _fxPick(_out, "app.op.deployment.op").spec
  assert _op.replicas == 1
  assert _fxEnv(_op.template)["WATCH_NAMESPACE"].value == "acme"
  _rules = _fxPick(_out, "app.op.role.op").rules
  assert _rules[0].apiGroups == ["x.io"] and "leases" in _rules[1].resources, "leader election comes with every operator"

  _srv = _fxPick(_out, "app.srv.deployment.srv").spec.template.metadata.annotations
  assert _srv["dapr.io/enabled"] == "true" and _srv["dapr.io/app-id"] == "srv"
  assert _srv["dapr.io/app-port"] == "50051" and _srv["dapr.io/app-protocol"] == "grpc"
  _cl = _fxPick(_out, "app.cli.deployment.cli").spec.template.metadata.annotations
  assert _cl["dapr.io/app-id"] == "client" and "dapr.io/app-port" not in _cl, "the sidecar never calls a client"
}

test_app_fields_only_where_they_mean_something = lambda {
  assert "only ui, api and dapr-server" in _fxErr(_fxAws | {apps = [{name = "op", kind = "operator", image = "r/op:1", route = {hosts = ["x"], gateway = {name = "gw"}}}]})
  assert "`rules` belong to an operator" in _fxErr(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1", rules = [{resources = ["pods"], verbs = ["get"]}]}]})
  assert "cli fields" in _fxErr(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1", schedule = "* * * * *"}]})
  assert "`dapr` settings" in _fxErr(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1", dapr = {appId = "x"}}]})
  assert "api → nope" in _fxErr(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1", uses = ["nope"]}]})
}

test_overrides_merge_into_the_app_package_values = lambda {
  _out = project.render(_fxBuild(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1", overrides = {replicas = 5, resources = {
    limits = {memory = "1Gi"}
  }}}]}))
  _d = _fxPick(_out, "app.api.deployment.api").spec
  assert _d.replicas == 5
  _res = _d.template.spec.containers[0].resources
  assert _res.limits.memory == "1Gi" and _res.requests.cpu == "250m", "maps merge: a limit override keeps the default requests"
}

test_placement_and_labels_reach_workloads_and_pods = lambda {
  _toleration = {key = "platform.example.org/dedicated", operator = "Equal", value = "acme", effect = "NoSchedule"}
  _out = project.render(_fxBuild(_fxAws | {
    labels = {"platform.example.org/customer" = "acme", "platform.example.org/project" = "spoofed"}
    placement = {nodeSelector = {"platform.example.org/dedicated" = "acme"}, tolerations = [_toleration]}
    databases = [{name = "db"}]
    apps = [
      {name = "api", kind = "api", image = "r/a:1", labels = {"jira.shluviza.com/epic" = "PLAT-12"}}
      {name = "job", kind = "cli", image = "r/a:1"}
    ]
  }))
  _d = _fxPick(_out, "app.api.deployment.api")
  assert _d.metadata.labels["jira.shluviza.com/epic"] == "PLAT-12", "the controller watches workload labels"
  assert _d.metadata.labels["platform.example.org/project"] == "shop", "spec.labels cannot rename the project"
  _pod = _d.spec.template
  assert _pod.metadata.labels["platform.example.org/customer"] == "acme", "cost tools allocate by pod label"
  assert _pod.spec.nodeSelector == {"platform.example.org/dedicated" = "acme"}
  assert _pod.spec.tolerations[0].value == "acme"
  _job = _fxPick(_out, "app.job.job.job").spec.template.spec
  assert _job.nodeSelector == {"platform.example.org/dedicated" = "acme"}, "a cli Job lands on the same pool"
  assert "jira.shluviza.com/epic" not in _fxPick(_out, "app.job.job.job").metadata.labels, "app labels stay on their app"
  assert _fxPick(_out, "database.db").metadata.labels["platform.example.org/customer"] == "acme"
}

# ── Wiring and gating ────────────────────────────────────────────────────────
test_app_waits_for_its_resources_then_is_wired = lambda {
  _xr = _fxBuild(_fxAws | {
    databases = [{name = "orders-db"}]
    apps = [{name = "api", kind = "api", image = "r/a:1", uses = ["orders-db"], env = {ORDERS_DB_HOST = "stale", LOG = "info"}}]
  })
  assert not _fxHas(project.render(_xr), "app.api.deployment.api"), "no pod before its database exists"
  _st = {host = "db.internal", port = 5432, database = "app", username = "app", authSecret = "orders-db-postgres-auth", authSecretKey = "password"}
  assert not _fxHas(project.render(_xr, {
    "database.orders-db" = {
      Resource = {status = _st | {ready = False}}
    }
  }), "app.api.deployment.api"), "published but not ready is still waiting"
  _env = _fxEnv(_fxPick(project.render(_xr, {"database.orders-db" = _fxReady(_st)}), "app.api.deployment.api").spec.template)
  assert _env["ORDERS_DB_HOST"].value == "db.internal", "the live coordinate beats a stale user value"
  assert _env["ORDERS_DB_PORT"].value == "5432"
  _ref = _env["ORDERS_DB_PASSWORD"].valueFrom.secretKeyRef
  assert _ref.name == "orders-db-postgres-auth" and _ref.key == "password" and _ref.optional == False, "the password stays in its Secret"
  assert _env["LOG"].value == "info"
}

test_a_composed_app_survives_a_dependency_flap = lambda {
  _xr = _fxBuild(_fxAws | {databases = [{name = "db"}], apps = [{name = "api", kind = "api", image = "r/a:1", uses = ["db"]}]})
  _ocds = {
    "database.db" = {
      Resource = {
        status = {ready = False}
      }
    }
    "app.api.deployment.api" = {
      Resource = {
        status = {availableReplicas = 2}
      }
    }
  }
  assert _fxHas(project.render(_xr, _ocds), "app.api.deployment.api"), "dropping it would make Crossplane delete a running workload"
}

# ── Dapr ─────────────────────────────────────────────────────────────────────
test_dapr_component_resolves_from_resources = lambda {
  _xr = _fxBuild(_fxAzure | {
    caches = [{name = "cache"}]
    apps = [{name = "worker", kind = "dapr-client", image = "r/w:1"}]
    dapr.components = [{name = "events", $type = "pubsub.redis", scopes = ["worker"], metadata = [
      {name = "redisHost", fromResource = {name = "cache", field = "endpoint"}}
      {name = "redisPassword", fromResource = {name = "cache", field = "password"}}
      {name = "consumerID", value = "worker"}
    ]}]
  })
  assert not _fxHas(project.render(_xr), "dapr.events"), "a component with unresolved values is not composed"
  _c = _fxPick(project.render(_xr, {"cache.cache" = _fxReady({endpoint = "cache-primary:6379", authSecret = "cache", authSecretKey = "valkey-password"})}), "dapr.events")
  assert _c.scopes == ["worker"]
  assert _c.spec["type"] == "pubsub.redis"
  assert _c.spec.metadata == [{name = "redisHost", value = "cache-primary:6379"}, {name = "redisPassword", secretKeyRef = {name = "cache", key = "valkey-password"}}, {name = "consumerID", value = "worker"}]
  _scope = _fxErr(_fxAws | {apps = [{name = "api", kind = "api", image = "r/a:1"}], dapr.components = [{name = "s", $type = "state.redis", scopes = ["api"]}]})
  assert "scopes" in _scope, "only dapr apps load components: ${_scope}"
}

# ── Status ───────────────────────────────────────────────────────────────────
test_status = lambda {
  _xr = _fxBuild(_fxAws | {databases = [{name = "db"}], apps = [
    {name = "api", kind = "api", image = "r/a:1", uses = ["db"]}
    {name = "job", kind = "cli", image = "r/a:1"}
  ]})
  _waiting = project.status(_xr, {}).status
  assert not _waiting.ready
  assert _waiting.apps.api.phase == "Waiting" and _waiting.apps.api.waitingFor == ["database.db"]
  assert _waiting.resources.db == {kind = "PostgresInstance", backend = "aws", ready = False}

  _ocds = {
    "database.db" = _fxReady({})
    "app.api.deployment.api" = {
      Resource = {
        status = {availableReplicas = 1}
      }
    }
    "app.job.job.job" = {
      Resource = {
        status = {}
      }
    }
  }
  _ready = project.status(_xr, _ocds).status
  assert _ready.ready, _ready.message
  assert _ready.apps.api == {kind = "api", ready = True, phase = "Ready", availableReplicas = 1}
  assert _ready.message == ""
}

# ── Examples ─────────────────────────────────────────────────────────────────
test_examples_render = lambda {
  _files = ["../xrd/examples/project-aws.yaml", "../xrd/examples/project-azure.yaml"]
  _outs = [project.render(yaml.decode(file.read(f))) for f in _files]
  # Composed-resource names are Crossplane's identity for each object.
  assert all_true([len([i.metadata.annotations[_fxAnno] for i in o]) == len({i.metadata.annotations[_fxAnno]: 1 for i in o}) for o in _outs]), "composition-resource-names must be unique"
  assert all_true([len(o) > 0 for o in _outs])
}
