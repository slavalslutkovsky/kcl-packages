# project — Crossplane Composition logic (function-kcl module).
#
# One client project in one namespace: the cloud resources it needs and the
# apps that use them. A composite of composites on the cloud side and a
# wrapper on the workload side, so this module owns neither a cloud mapping
# nor a second workload renderer:
#
#   cloud resources  → child XRs in cloud.example.org/v1alpha1
#                      (PostgresInstance, RedisInstance, Queue, Bucket,
#                      Registry, WorkloadIdentity). Each capability keeps its
#                      own aws / azure Composition; this module only picks the
#                      backend through crossplane.compositionSelector.
#   apps             → the objects packages/app renders (app.lib), one Release
#                      per app, plus an HTTPRoute and Dapr Components.
#
# MULTI-CLOUD IS ONE FIELD. spec.cloud.provider (aws | azure) selects the
# backend of every child. A capability with no native backend on that cloud
# falls back to its in-cluster one (azure: cache → valkey), and any resource
# may pick its in-cluster backend explicitly (cnpg, valkey, rustfs, zot).
# Queues have only an aws backend: a queue on azure fails the render rather
# than resolving to a Composition that does not exist. Mixing clouds inside one
# project is rejected: a project's credentials, identities and network
# placement belong to one cloud.
#
# WIRING FROM OBSERVED STATUS. An app lists the resources it `uses`; their
# coordinates (host, port, url, names) become env vars and their password
# Secret a secretKeyRef, read from the children's observed status — the same
# mechanism as packages/platform/appstack. An app is not composed until every
# resource it uses (and its own WorkloadIdentity) reports ready, so a pod never
# starts with half its configuration. Once composed it stays composed: dropping
# it from the desired state would make Crossplane delete a running workload
# because a dependency flapped.
#
# NAMESPACED ON PURPOSE. A namespaced XR composes only into its own namespace,
# which is the tenant boundary for a client: no ClusterRole, no CRD, no
# Namespace comes out of here. An `operator` app therefore watches its own
# namespace (WATCH_NAMESPACE) through a namespaced Role; its CRDs are installed
# by the platform.
#
# function-kcl v0.12.2 runs an older KCL than the local CLI: keep lambda
# parameter lists on one line (`kcl fmt` wraps long ones, and the wrapped form
# does not parse there).
import app.lib as app
import gateway_api.models.v1.gateway_networking_k8s_io_v1_http_route as gwapi

_child_api = "cloud.example.org/v1alpha1"

# Dapr's Component (dapr.io), not the platform's Component XR. Held in a
# constant so tools/catalog, which reads `kind = "<Kind>"` literals as child
# XRs, does not list the platform Component as a child of Project.
_daprComponentKind = "Component"

# ── Capabilities ─────────────────────────────────────────────────────────────
# One row per kind of cloud resource a project can hold.
#   field      the spec list it is declared in
#   kind       the child XR kind (packages/cloud/<capability>/xrd)
#   native     clouds with a backend of their own for it
#   inCluster  the backend that runs anywhere, the fallback where native lacks
#              ("" — none exists)
#   rg         the child XRD takes spec.resourceGroup (azure backends need it)
#   env        observed status field → env var suffix, for apps that use it
#   password   the child publishes authSecret / authSecretKey
capabilities = {
  database = {field = "databases", kind = "PostgresInstance", native = ["aws", "azure"], inCluster = "cnpg", rg = True, password = True, env = [["host", "HOST"], ["port", "PORT"], ["database", "NAME"], ["username", "USER"], ["url", "URL"]]}
  cache = {field = "caches", kind = "RedisInstance", native = ["aws"], inCluster = "valkey", rg = False, password = True, env = [["host", "HOST"], ["port", "PORT"], ["url", "URL"]]}
  queue = {field = "queues", kind = "Queue", native = ["aws"], inCluster = "", rg = False, password = False, env = [["queueName", "NAME"], ["url", "URL"], ["topic", "TOPIC"], ["deadLetterUrl", "DLQ_URL"]]}
  bucket = {field = "buckets", kind = "Bucket", native = ["aws", "azure"], inCluster = "rustfs", rg = False, password = False, env = [["bucketName", "NAME"], ["url", "URL"], ["endpoint", "ENDPOINT"], ["region", "REGION"]]}
  registry = {field = "registries", kind = "Registry", native = ["aws", "azure"], inCluster = "zot", rg = True, password = False, env = [["registryName", "NAME"], ["endpoint", "ENDPOINT"], ["url", "URL"]]}
}

# Render order of the capabilities, so the output never depends on dict order.
capability_order = ["database", "cache", "queue", "bucket", "registry"]

# Kinds of app a client ships, and what each one defaults to. Everything here
# is a default: `overrides` on the app replaces any of it.
#   workload  False → a Job / CronJob (app.Task) instead of a Deployment
#   service   a Service in front of the pods
#   routable  may carry a north-south HTTPRoute
#   dapr      gets a Dapr sidecar; "server" also exposes its app port to it
app_kinds = {
  cli = {component = "cli", workload = False, service = False, routable = False, dapr = "", replicas = 0, prometheus = False}
  ui = {component = "frontend", workload = True, service = True, routable = True, dapr = "", replicas = 2, prometheus = False}
  api = {component = "api", workload = True, service = True, routable = True, dapr = "", replicas = 2, prometheus = True}
  operator = {component = "operator", workload = True, service = False, routable = False, dapr = "", replicas = 1, prometheus = False}
  "dapr-server" = {component = "dapr-server", workload = True, service = True, routable = True, dapr = "server", replicas = 2, prometheus = True}
  "dapr-client" = {component = "dapr-client", workload = True, service = False, routable = False, dapr = "client", replicas = 1, prometheus = False}
}

# What controller-runtime / operator-sdk need for leader election, added to
# every operator's Role so an operator with replicas > 1 does not split-brain.
_leader_election_rules = [
  {apiGroups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]}
  {apiGroups = [""], resources = ["events"], verbs = ["create", "patch"]}
]

# ClusterSecretStore an app's `secrets` are read from when the project does not
# name one: one per cloud, created by the platform, never by a tenant.
default_secret_store = {
  aws = "aws-secrets-manager"
  azure = "azure-key-vault"
}

# ── Helpers ──────────────────────────────────────────────────────────────────
# Explicit "was this field set?": false and 0 are values, not absence.
_set = lambda value -> bool {
  not (value == Undefined or value == None)
}

_get = lambda src, key: str, fallback: any -> any {
  src[key] if src and key in src and _set(src[key]) else fallback
}

# A composed child's observed status, as function-kcl hands it over.
_observed = lambda ocds, key: str -> any {
  (ocds[key]?.Resource?.status) if (key in ocds) else Undefined
}

_isReady = lambda ocds, key: str -> bool {
  (_observed(ocds, key)?.ready or False) == True
}

# Env var prefix of a resource: orders-db → ORDERS_DB.
_envPrefix = lambda name: str -> str {
  name.upper().replace("-", "_").replace(".", "_")
}

resource_key = lambda capability: str, name: str -> str {
  "${capability}.${name}"
}

identity_key = lambda name: str -> str {
  "identity.${name}"
}

dapr_key = lambda name: str -> str {
  "dapr.${name}"
}

# Composed-resource names of an app's objects all start with this, so "was
# this app ever composed?" is one prefix test over ocds.
_appPrefix = lambda name: str -> str {
  "app.${name}."
}

_wasComposed = lambda ocds, prefix: str -> bool {
  len([_k for _k in ocds if _k.startswith(prefix)]) > 0
}

# ── Project context ──────────────────────────────────────────────────────────
# Everything the renderers need from the XR, resolved once.
context = lambda oxr -> {str:} {
  _spec = oxr.spec
  _cloud = _spec.cloud
  _provider = _cloud.provider
  _name = oxr.metadata.name
  # Identity labels on everything composed. spec.labels add to them (e.g.
  # jira.shluviza.com/*, platform.example.org/customer) but cannot rename the
  # project, so they go first.
  _labels = app.mergeValues(_get(_spec, "labels", {}), {
    "app.kubernetes.io/part-of" = _name
    "app.kubernetes.io/managed-by" = "crossplane"
    "platform.example.org/project" = _name
    "platform.example.org/client" = _spec.client
    if _spec?.environment:
      "platform.example.org/environment" = _spec.environment
  })

  # Cloud tags. The project's identity tags are applied last everywhere, so
  # a resource can always be traced back to its client in the bill: spec
  # tags may add, never rename the project or the client.
  _identityTags = {
    project = _name
    client = _spec.client
    if _spec?.environment:
      environment = _spec.environment
  }
  {
    name = _name
    namespace = oxr.metadata?.namespace or "default"
    client = _spec.client
    provider = _provider
    region = _cloud.region
    resourceGroup = _cloud?.resourceGroup or ""
    oidcIssuer = _cloud?.oidcIssuer or ""
    deletionPolicy = _cloud?.deletionPolicy or "Delete"
    secretStore = _cloud?.secretStore or default_secret_store[_provider]
    labels = _labels
    identityTags = _identityTags
    tags = app.mergeValues(_cloud?.tags or {}, _identityTags)
    # nodeSelector / tolerations for every app's pods (dedicated or shared pool).
    placement = _get(_spec, "placement", {})
  }
}

# A backend is the project's cloud, where the capability has a backend there,
# or the capability's in-cluster one — never another cloud.
allowed_backends = lambda provider: str, capability: str -> [str] {
  ([provider] if provider in capabilities[capability].native else []) + ([capabilities[capability].inCluster] if capabilities[capability].inCluster else [])
}

# Every declared cloud resource, flattened, with its backend resolved.
resources = lambda oxr -> [{str:}] {
  _spec = oxr.spec
  _provider = _spec.cloud.provider
  [{
    capability = _c
    name = _r.name
    backend = _get(_r, "backend", (allowed_backends(_provider, _c) + [""])[0])
    spec = _get(_r, "spec", {})
  } for _c in capability_order for _r in _get(_spec, capabilities[_c].field, [])]
}

# ── Validation the XRD cannot express ────────────────────────────────────────
validate = lambda oxr -> bool {
  _spec = oxr.spec
  _ctx = context(oxr)
  _res = resources(oxr)
  _apps = _get(_spec, "apps", [])
  _resNames = [_r.name for _r in _res]
  _appNames = [_a.name for _a in _apps]
  _daprApps = [_a.name for _a in _apps if app_kinds[_a.kind].dapr]
  _components = _get(_get(_spec, "dapr", {}), "components", [])

  assert len(_resNames) == len({_n: 1 for _n in _resNames}), "resource names must be unique across databases, caches, queues, buckets and registries: an app's `uses` resolves by name, got ${_resNames}"
  assert len(_appNames) == len({_n: 1 for _n in _appNames}), "app names must be unique, got ${_appNames}"
  _badBackend = ["${_r.name}: ${_r.backend or 'no default'} (allowed: ${', '.join(allowed_backends(_ctx.provider, _r.capability)) or 'none — no ' + capabilities[_r.capability].kind + ' backend runs on ' + _ctx.provider})" for _r in _res if _r.backend not in allowed_backends(_ctx.provider, _r.capability)]
  assert not _badBackend, "project ${_ctx.name} runs on ${_ctx.provider}; a resource's backend is that cloud's own or the in-cluster one: " + "; ".join(_badBackend)
  _needsRg = [_r.name for _r in _res if _r.backend == "azure" and capabilities[_r.capability].rg] + [_a.name for _a in _apps if _a?.identity and _ctx.provider == "azure"]
  assert not _needsRg or _ctx.resourceGroup, "spec.cloud.resourceGroup is required on azure: ${_needsRg} live in an existing resource group"
  _withIdentity = [_a.name for _a in _apps if _a?.identity]
  assert not _withIdentity or _ctx.oidcIssuer, "spec.cloud.oidcIssuer is required: ${_withIdentity} federate a cloud identity with the cluster's OIDC issuer (EKS: the IAM OIDC provider ARN; AKS: oidcIssuerProfile.issuerUrl)"
  _badUses = ["${_a.name} → ${_u}" for _a in _apps for _u in _get(_a, "uses", []) if _u not in _resNames]
  assert not _badUses, "`uses` must name a resource of this project (${_resNames}): " + ", ".join(_badUses)
  _badRoute = ["${_a.name} (${_a.kind})" for _a in _apps if _a?.route and not app_kinds[_a.kind].routable]
  assert not _badRoute, "only ui, api and dapr-server apps have a Service to route to: " + ", ".join(_badRoute)
  _badTask = [_a.name for _a in _apps if _a.kind != "cli" and (_a?.schedule or _a?.command or _a?.args)]
  assert not _badTask, "schedule / command / args are cli fields (use `overrides` to change a workload's container): " + ", ".join(_badTask)
  _badRules = [_a.name for _a in _apps if _a.kind != "operator" and _a?.rules]
  assert not _badRules, "`rules` belong to an operator app: " + ", ".join(_badRules)
  _badDapr = [_a.name for _a in _apps if not app_kinds[_a.kind].dapr and _a?.dapr]
  assert not _badDapr, "`dapr` settings belong to a dapr-server or dapr-client app: " + ", ".join(_badDapr)
  _badScopes = ["${_c.name} → ${_s}" for _c in _components for _s in _get(_c, "scopes", []) if _s not in _daprApps]
  assert not _badScopes, "a Dapr component's `scopes` must name dapr-server / dapr-client apps of this project (${_daprApps}): " + ", ".join(_badScopes)
  _badFrom = ["${_c.name}.${_m.name} → ${_m.fromResource.name}" for _c in _components for _m in _get(_c, "metadata", []) if _m?.fromResource and _m.fromResource.name not in _resNames]
  assert not _badFrom, "a Dapr component's `fromResource.name` must name a resource of this project (${_resNames}): " + ", ".join(_badFrom)
  True
}

# ── Cloud children ───────────────────────────────────────────────────────────
# One child XR. Project-wide settings first, the resource's own `spec` over
# them (a database may be Orphan while the rest is Delete), then what a
# resource must not change: the backend selector — that is `backend` — and the
# project's tags, which `spec.tags` can only extend.
_child = lambda ctx: {str:}, r: {str:} -> {str:} {
  _cap = capabilities[r.capability]
  _base = {
    region = ctx.region
    deletionPolicy = ctx.deletionPolicy
    if r.backend == "azure" and _cap.rg:
      resourceGroup = ctx.resourceGroup
  }
  {
    apiVersion = _child_api
    kind = _cap.kind
    metadata = {
      name = r.name
      labels = ctx.labels | {"platform.example.org/capability" = r.capability}
      annotations = {"krm.kcl.dev/composition-resource-name" = resource_key(r.capability, r.name)}
    }
    # app.mergeValues (deep, right wins), not `|` or `**`: both fail on a key
    # the two sides set to different values, and overriding a project
    # default is exactly what a resource spec is for.
    spec = app.mergeValues(app.mergeValues(_base, r.spec), {
      tags = app.mergeValues(app.mergeValues(ctx.tags, _get(r.spec, "tags", {})), ctx.identityTags)
      crossplane = {
        compositionSelector = {
          matchLabels = {provider = r.backend}
        }
      }
    })
  }
}

# One WorkloadIdentity per app with `identity`: the cloud identity, its trust
# for system:serviceaccount:<ns>:<app>, and the ServiceAccount itself, which
# the identity XR composes because only it knows the role ARN / client ID the
# annotation carries. Region and resource group are azure-only; the aws
# backend fails the render when either is set.
_identity = lambda ctx: {str:}, a: {str:} -> {str:} {
  {
    apiVersion = _child_api
    kind = "WorkloadIdentity"
    metadata = {
      name = a.name
      labels = ctx.labels | {"platform.example.org/capability" = "identity"}
      annotations = {"krm.kcl.dev/composition-resource-name" = identity_key(a.name)}
    }
    spec = {
      displayName = "${ctx.name}/${a.name}"
      serviceAccount = {name = a.name, create = True}
      identity.name = "${ctx.name}-${a.name}"
      cluster.oidcIssuer = ctx.oidcIssuer
      accessPolicies = _get(a.identity, "accessPolicies", [])
      deletionPolicy = ctx.deletionPolicy
      tags = ctx.tags
      if ctx.provider == "azure":
        region = ctx.region
        resourceGroup = ctx.resourceGroup
      crossplane = {compositionSelector.matchLabels.provider = ctx.provider}
    }
  }
}

# ── Apps ─────────────────────────────────────────────────────────────────────
# Env vars for one used resource, from what its child has published so far.
_wiringEnv = lambda r: {str:}, st -> [{str:}] {
  _cap = capabilities[r.capability]
  _pre = _envPrefix(r.name)
  _plain = [{name = "${_pre}_${_f[1]}", value = str(st[_f[0]])} for _f in _cap.env if st and _f[0] in st and _set(st[_f[0]]) and str(st[_f[0]]) != ""]
  _secret = [{name = "${_pre}_PASSWORD", secretName = st.authSecret, secretKey = st?.authSecretKey or "password", optional = False}] if _cap.password and st and st?.authSecret else []
  _plain + _secret
}

_daprAnnotations = lambda a: {str:}, port: int -> {str:str} {
  _mode = app_kinds[a.kind].dapr
  _d = _get(a, "dapr", {})
  {
    "dapr.io/enabled" = "true"
    "dapr.io/app-id" = _get(_d, "appId", a.name)
    if _mode == "server":
      "dapr.io/app-port" = str(port)
      "dapr.io/app-protocol" = _get(_d, "protocol", "http")
    if _d?.config:
      "dapr.io/config" = _d.config
    if _d?.logLevel:
      "dapr.io/log-level" = _d.logLevel
  } if _mode else {}
}

# With an identity the ServiceAccount is the WorkloadIdentity's (it carries the
# role ARN / client ID annotation), so the app only references it.
_serviceAccount = lambda a: {str:} -> any {
  _rules = (_get(a, "rules", []) + _leader_election_rules) if a.kind == "operator" else []
  _identity = bool(a?.identity)
  {
    create = not _identity
    name = a.name
    rules = _rules
  } if _identity or _rules else Undefined
}

# The app package's values for one app, before `overrides`.
_values = lambda ctx: {str:}, a: {str:}, env: [{str:}] -> {str:} {
  _k = app_kinds[a.kind]
  _port = _get(a, "port", 8080)
  _envFrom = ([{kind = "configMap", name = "${a.name}-config"}] if a?.config else []) + ([{kind = "secret", name = "${a.name}-secrets", optional = False}] if a?.secrets else [])
  _env = env + ([{name = "WATCH_NAMESPACE", value = ctx.namespace}] if a.kind == "operator" else [])
  _sa = _serviceAccount(a)

  # app.kubernetes.io/version: the explicit `version`, else the image tag
  # (not the app package's placeholder default).
  _ref = a.image.split("@")[0].split("/")[-1]
  _version = _get(a, "version", _ref.split(":")[-1] if ":" in _ref else "")
  _common = {
    name = a.name
    namespace = ctx.namespace
    component = _k.component
    partOf = ctx.name
    image = a.image
    # "" drops the label rather than claiming the app package's 0.1.0.
    version = _version
    env = _env
    envFrom = _envFrom
    if _sa:
      serviceAccount = _sa
    # Project and app labels on the pods too: cost tools (OpenCost) allocate
    # by pod label. The AKS workload-identity webhook only projects the
    # federated token into pods carrying azure.workload.identity/use.
    podLabels = app.mergeValues(app.mergeValues(_get(a, "labels", {}), ctx.labels), {"azure.workload.identity/use" = "true"} if a?.identity and ctx.provider == "azure" else {})
    if ctx.placement?.nodeSelector:
      nodeSelector = ctx.placement.nodeSelector
    if ctx.placement?.tolerations:
      tolerations = ctx.placement.tolerations
  }
  _task = {
    if a?.command:
      command = a.command
    if a?.args:
      args = a.args
    if a?.schedule:
      schedule = a.schedule
  }
  _workload = {
    port = _port
    replicas = _get(a, "replicas", _k.replicas)
    service = _k.service
    prometheus = _k.prometheus
    podAnnotations = _daprAnnotations(a, _port)
  }
  _common | (_workload if _k.workload else _task)
}

_release = lambda ctx: {str:}, a: {str:}, env: [{str:}] -> app.Release {
  _merged = app.mergeValues(_values(ctx, a, env), _get(a, "overrides", {}))
  app.Release {
    if app_kinds[a.kind].workload:
      workload = app.Workload {**_merged}
    else:
      task = app.Task {**_merged}
    if a?.config:
      config = a.config
    if a?.secrets:
      externalSecret = app.ExternalSecretSpec {
        store = _get(a.secrets, "store", ctx.secretStore)
        refreshInterval = _get(a.secrets, "refreshInterval", "1h")
        items = a.secrets.items
      }
  }
}

# North-south route to the app's Service through a shared, platform-owned
# Gateway — referenced, never created (one Gateway per app is one load
# balancer per app).
_route = lambda ctx: {str:}, a: {str:} -> [any] {
  _r = _get(a, "route", {})
  _gw = _r.gateway if _r else {}
  [gwapi.HTTPRoute {
    metadata = {name = a.name, namespace = ctx.namespace}
    spec = {
      hostnames = _r.hosts
      parentRefs = [{name = _gw["name"]} | ({namespace = _gw.namespace} if _gw?.namespace else {}) | ({sectionName = _gw.sectionName} if _gw?.sectionName else {})]
      rules = [{
        matches = [{
          path = {$type = _get(_r, "pathType", "PathPrefix"), value = _get(_r, "path", "/")}
        }]
        backendRefs = [{name = a.name, port = _get(a, "port", 8080)}]
      }]
    }
  }] if _r else []
}

# Stamp project labels and a unique composed-resource name on every object of
# one app: app.<app>.<kind>.<object name>.
# Union replaces a nested dict wholesale, so the object's own labels and
# annotations are merged in explicitly.
_stamp = lambda ctx: {str:}, a: {str:}, items: [any] -> [any] {
  [_it | {
    metadata = _it.metadata | {
      labels = app.mergeValues(app.mergeValues(_it.metadata?.labels or {}, _get(a, "labels", {})), ctx.labels)
      annotations = (_it.metadata?.annotations or {}) | {"krm.kcl.dev/composition-resource-name" = "${_appPrefix(a.name)}${_it.kind.lower()}.${_it.metadata.name}"}
    }
  } for _it in items]
}

# What an app waits for: every resource it uses, and its own identity.
dependencies = lambda oxr, a: {str:} -> [str] {
  _byName = {_r.name: _r for _r in resources(oxr)}
  [resource_key(_byName[_u].capability, _u) for _u in _get(a, "uses", []) if _u in _byName] + ([identity_key(a.name)] if a?.identity else [])
}

# Composed once every dependency is ready, and kept from then on.
appComposed = lambda oxr, ocds, a: {str:} -> bool {
  _wasComposed(ocds, _appPrefix(a.name)) or len([_d for _d in dependencies(oxr, a) if not _isReady(ocds, _d)]) == 0
}

_app = lambda oxr, ocds, a: {str:} -> [any] {
  _ctx = context(oxr)
  _byName = {_r.name: _r for _r in resources(oxr)}
  _wired = [_e for _u in _get(a, "uses", []) for _e in _wiringEnv(_byName[_u], _observed(ocds, resource_key(_byName[_u].capability, _u)))]
  _wiredNames = [_e.name for _e in _wired]

  # Wired coordinates win over the user's env: they are the live truth about
  # the composed resource, and a stale ORDERS_DB_HOST must not shadow it.
  _userEnv = _get(a, "env", {})
  _env = [{name = _k, value = str(_userEnv[_k])} for _k in sorted(_userEnv) if _k not in _wiredNames] + _wired
  _stamp(_ctx, a, app.renderRelease(_release(_ctx, a, _env)) + _route(_ctx, a))
}

# ── Dapr components ──────────────────────────────────────────────────────────
# A metadata item is a literal `value`, a `secretKeyRef` into a Secret of this
# namespace, or `fromResource`: a field of a resource's observed status
# (`field: password` → its authSecret / authSecretKey as a secretKeyRef).
_daprItem = lambda oxr, ocds, m: {str:} -> any {
  _byName = {_r.name: _r for _r in resources(oxr)}
  _src = m?.fromResource
  _st = _observed(ocds, resource_key(_byName[_src.name].capability, _src.name)) if _src else Undefined
  _field = _src.field if _src else ""
  _value = (_st[_field] if _st and _field in _st and _set(_st[_field]) else Undefined) if _src and _field != "password" else Undefined
  _ref = ({name = _st.authSecret, key = _st?.authSecretKey or "password"} if _st and _st?.authSecret else Undefined) if _src and _field == "password" else Undefined
  ({name = m.name, value = str(m.value)} if _set(m?.value) else {name = m.name, secretKeyRef = m.secretKeyRef} if m?.secretKeyRef else {name = m.name, value = str(_value)} if _set(_value) else {name = m.name, secretKeyRef = _ref} if _ref else Undefined)
}

_dapr = lambda oxr, ocds, c: {str:} -> [any] {
  _ctx = context(oxr)
  _items = [_daprItem(oxr, ocds, _m) for _m in _get(c, "metadata", [])]
  _resolved = len([_i for _i in _items if not _set(_i)]) == 0
  [{
    apiVersion = "dapr.io/v1alpha1"
    kind = _daprComponentKind
    metadata = {
      name = c.name
      namespace = _ctx.namespace
      labels = _ctx.labels
      annotations = {"krm.kcl.dev/composition-resource-name" = dapr_key(c.name)}
    }
    spec = {
      $type = c["type"]
      version = _get(c, "version", "v1")
      metadata = [_i for _i in _items if _set(_i)]
      if c?.ignoreErrors:
        ignoreErrors = True
      if c?.initTimeout:
        initTimeout = c.initTimeout
    }
    if c?.scopes:
      scopes = c.scopes
  }] if _resolved or dapr_key(c.name) in ocds else []
}

# ── render ───────────────────────────────────────────────────────────────────
# render(oxr, ocds) — the children first (they take longest), then every app
# whose dependencies are ready, then the Dapr components whose values are.
# ocds defaults to {} so a bare `kcl run main.k` renders the first reconcile.
render = lambda oxr, ocds = {} -> [any] {
  assert validate(oxr)
  _ctx = context(oxr)
  _apps = _get(oxr.spec, "apps", [])
  _children = [_child(_ctx, _r) for _r in resources(oxr)]
  _identities = [_identity(_ctx, _a) for _a in _apps if _a?.identity]
  _workloads = [_o for _a in _apps if appComposed(oxr, ocds, _a) for _o in _app(oxr, ocds, _a)]
  _components = [_o for _c in _get(_get(oxr.spec, "dapr", {}), "components", []) for _o in _dapr(oxr, ocds, _c)]
  _children + _identities + _workloads + _components
}

# ── status ───────────────────────────────────────────────────────────────────
_appStatus = lambda oxr, ocds, a: {str:} -> {str:} {
  _composed = appComposed(oxr, ocds, a)
  _isWorkload = app_kinds[a.kind].workload
  _dep = _observed(ocds, "${_appPrefix(a.name)}deployment.${a.name}")
  _available = (_dep?.availableReplicas or 0) if _isWorkload else 0
  _waiting = [_d for _d in dependencies(oxr, a) if not _isReady(ocds, _d)]
  {
    kind = a.kind
    # A cli app is a Job or CronJob: composed is as ready as it gets.
    ready = _composed and (_available > 0 if _isWorkload else _wasComposed(ocds, _appPrefix(a.name)))
    phase = "Waiting" if not _composed else ("Ready" if (_available > 0 if _isWorkload else _wasComposed(ocds, _appPrefix(a.name))) else "Composed")
    if _isWorkload:
      availableReplicas = _available
    if not _composed:
      waitingFor = _waiting
  }
}

status = lambda oxr, ocds -> any {
  _ctx = context(oxr)
  _res = resources(oxr)
  _apps = _get(oxr.spec, "apps", [])
  _resStatus = {_r.name: {
    kind = capabilities[_r.capability].kind
    backend = _r.backend
    ready = _isReady(ocds, resource_key(_r.capability, _r.name))
  } for _r in _res}
  _identityStatus = {_a.name: _isReady(ocds, identity_key(_a.name)) for _a in _apps if _a?.identity}
  _appsStatus = {_a.name: _appStatus(oxr, ocds, _a) for _a in _apps}
  _notReady = [_n for _n in _resStatus if not _resStatus[_n].ready] + ["identity/${_n}" for _n in _identityStatus if not _identityStatus[_n]] + ["app/${_n}" for _n in _appsStatus if not _appsStatus[_n].ready]
  {
    apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
    kind = oxr?.kind or "Project"
    metadata.name = _ctx.name
    status = {
      provider = _ctx.provider
      ready = len(_notReady) == 0
      resources = _resStatus
      apps = _appsStatus
      if _identityStatus:
        identities = _identityStatus
      message = "" if not _notReady else "not ready: " + ", ".join(_notReady)
    }
  }
}
