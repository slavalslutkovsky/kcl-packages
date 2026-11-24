"""
Application Kubernetes manifests — typed schemas + renderers (single source of truth).

Two archetypes, one package:
  • Workload → long-running apps (backend APIs, frontend/static apps, queue
    workers): Deployment (+ Service, + optional autoscaler: a KEDA ScaledObject,
    which owns the HPA behind it and also does scale-to-zero and event-driven
    triggers).
    Backend and frontend are the SAME archetype with different field values
    (e.g. prometheus on/off, nginx volumes, uid/gid).
  • Task → run-to-completion CLI apps: a batch/v1 Job, a CronJob when `schedule`
    is set, or a KEDA ScaledJob when `scaler` is (Jobs per pending work item).
    Reuses the same container atoms (env/envFrom/security) as Workload.

Around either: an optional `serviceAccount` (ServiceAccount, cloud workload
identity annotation, namespaced Role + RoleBinding); for a Workload also a
PodDisruptionBudget and `monitoring` (ServiceMonitor / PodMonitor,
PrometheusRule, Grafana dashboard ConfigMaps for kube-prometheus-stack).

Core resources use the typed `k8s` package, ExternalSecret the typed
`external-secrets` package, KEDA and Prometheus Operator objects the `keda` /
`prometheus` packages, and chaos experiments the `chaos-mesh` / `litmus`
schema packages (packages/providers/), so rendered output is checked against
the real Kubernetes / CRD APIs. The usual path is a Helm-style values.yaml that
is a `Release` (a `workload:` or `task:` + optional `config:`/`externalSecret:`),
rendered by the package's own main.k with no local main.k needed. In code:
`import app` and call `app.renderRelease(app.Release {**yaml.decode(...)})`, or
the lower-level `app.render(w)` / `app.renderTask(t)`. See examples/.

Chaos engineering: a Workload's `chaos:` is a list of `Fault`s, each rendered
for its `provider` and pinned to that workload's own pods: a Chaos Mesh
experiment (PodChaos / NetworkChaos / StressChaos / HTTPChaos / IOChaos /
DNSChaos / TimeChaos, or a Schedule around one) by default, or with
`provider: litmus` a Litmus ChaosEngine + ChaosExperiment + runner RBAC in the
`litmus` namespace. Chaos Mesh is the default because its experiments are
self-contained CRs; Litmus covers fewer fault types (docs/chaos.md) and runs
once, but is the comparison point.

Backstage: a `catalog:` block turns the same values file into catalog entities
(`-D catalog=true` renders a Component, plus an API per `catalog.apis`), and
every object rendered here carries the `backstage.io/kubernetes-id` label, so
the portal's Kubernetes plugin shows this release's Deployment, Service,
autoscaler AND its chaos experiments on one component page.
"""

import regex
import json
import crypto
import k8s.api.apps.v1 as appsv1
import k8s.api.core.v1 as corev1
import k8s.api.batch.v1 as batchv1
import k8s.api.policy.v1 as policyv1
import k8s.api.rbac.v1 as rbacv1
import external_secrets.v1 as esv1
import gateway_api.models.v1.gateway_networking_k8s_io_v1_http_route as gwapi
import keda.v1alpha1 as keda
import prometheus_operator.models.unknown as promop
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_chaos as cmpod
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_network_chaos as cmnet
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_stress_chaos as cmstress
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_http_chaos as cmhttp
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_i_o_chaos as cmio
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_dns_chaos as cmdns
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_time_chaos as cmtime
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_schedule as cmschedule
import litmus.models.unknown as litmus
import .litmus_hub as hub

schema Omg1:
  resource: Workload

#dsa: str
#manifests: [any] = render(dsa)
schema Dam(Omg1):
  #resources: [Workload | Task]
  #resource: Workload
  _name: str
  _namespace: str
  _release: Release
  _version: str = ""
  _baseLabels: {str:str} = ({
    "app" = _name
    "app.kubernetes.io/name" = _name
    # backstage.io/kubernetes-id: matched by the Backstage k8s plugin;
    # deliberately NOT in selector.matchLabels (selector is immutable).
    "backstage.io/kubernetes-id" = _name
  } | ({"app.kubernetes.io/version" = _version} if _version else {}))
  #_deps: [] # can be flux resources or random kcl - test more
  manifests: [any] = [
    # es
    # deployment
    # service
    # sa
    # configmap
    # secret
    # keda
    # chaos
    # security
    # kyverno
    # krycloak
    {
      id = "dam-${_name}"
      enabled = True
      replicas = 3
      ratio = 0.75
      tags = ["alpha", "beta", _namespace or "default"]
      owner = {name = "zerg", contact = {email = "team@example.com", slack = "#zerg"}}
      limits = [{cpu = "250m", memory = "128Mi"}, {cpu = "1", memory = "512Mi"}]
      labels = _baseLabels
      notes = None
    }
    #_deployment(resource)
    # renderRelease(_release)
  ]
  _labelss = lambda name: str, version: str -> {str:str} {
    {
      "app" = name
      "app.kubernetes.io/name" = name
      #"app.kubernetes.io/component" = w.component
      #"app.kubernetes.io/part-of" = w.partOf
      # What the Backstage Kubernetes plugin matches on: an entity annotated
      # backstage.io/kubernetes-id=<id> is shown every object labelled with
      # the same id. Deliberately not part of the Deployment's
      # selector.matchLabels (which stays `app` alone) — a selector is
      # immutable, and this label has to stay free to change.
      "backstage.io/kubernetes-id" = name
    } | ({"app.kubernetes.io/version" = version} if version else {})
  }
  _dsa = lambda name: str -> [any] {
    [
      _deployment(Dam.resource)
    ]
  }
  _render = lambda name: str -> [any] {
    [
      _deployment(Dam.resource)
      #renderRelease(Dam._release)
    ]
  }

#_deployment()
#_deployment: _deployment()
#_probe: [Probe {
#   path = ""
#   port = "8080"
#}]
#_job: [
#batchv1.Job {
#   metadata = {name = t.name, labels = _taskLabels(t)} | ({namespace = t.namespace} if t.namespace else {})
#   spec = _jobSpec(t)
#}
#]

#_es: esv1.ExternalSecret
#_keda: keda.ScaledObject
#_res: [appsv1.Deployment | corev1.Service]

# ── Component schemas ────────────────────────────────────────────────────────
schema Probe:
  """Health probe. `type='http'` → httpGet(path, port); `type='grpc'` → grpc(port)."""
  $type?: "http" | "grpc" = "http"
  path?: str
  port: int | str
  periodSeconds?: int = 10
  failureThreshold?: int = 3
  timeoutSeconds?: int = 3
  initialDelaySeconds?: int

schema EnvVar:
  """A single container env var: literal, secretKeyRef, or configMapKeyRef."""
  name: str
  value?: str
  secretName?: str
  secretKey?: str
  configMapName?: str
  configMapKey?: str
  optional: bool = True

schema EnvFrom:
  """envFrom source. ConfigMaps are required; Secrets default to optional."""
  kind: "configMap" | "secret"
  name: str
  optional: bool = True

schema Trigger:
  """
    One KEDA trigger (nats-jetstream, prometheus, gcp-pubsub, kafka, cron, …),
    passed to the ScaledObject / ScaledJob as written. `auth` names an entry of
    the same scaler's `authentications`, so a trigger never spells out the
    rendered TriggerAuthentication name; `authenticationRef` points at one that
    exists outside this release instead (kind: ClusterTriggerAuthentication for
    a shared one).
    """
  $type: str
  metadata: {str:str} = {}
  name?: str
  metricType?: "AverageValue" | "Value" | "Utilization"
  useCachedMetrics?: bool
  auth?: str
  authenticationRef?: {str:str}

  check:
    not (auth and authenticationRef), "trigger ${$type}: `auth` (an entry of `authentications`) and `authenticationRef` (an existing object) are two ways to say the same thing — pick one"

schema SecretParam:
  """A trigger parameter read from a key of a Secret in the workload's namespace."""
  parameter: str
  name: str
  key: str

schema EnvParam:
  """A trigger parameter read from an env var of the scaled container."""
  parameter: str
  name: str
  containerName?: str

schema TriggerAuth:
  """
    A KEDA TriggerAuthentication, rendered as "<workload>-<name>": where a
    trigger's credentials come from, so none is ever written into the trigger
    metadata. `podIdentity` makes the KEDA operator authenticate as its own
    cloud identity (no secret at all) — `azure-workload`, `aws` or `gcp`.
    """
  name: str
  #secrets: [SecretParam] = [{parameter: "das",name: "Aris", key: "my-key" }]
  secrets: [SecretParam] = []
  env: [EnvParam] = []
  podIdentity?: "azure-workload" | "aws" | "gcp" = "gcp"
  # podIdentity: the client id / role ARN to assume instead of the operator's own
  identityId?: str

  check:
    secrets or env or podIdentity, "authentication ${name}: needs `secrets`, `env` or `podIdentity` — an empty TriggerAuthentication authenticates nothing"
    podIdentity or not identityId, "authentication ${name}: identityId only applies with podIdentity"

schema Triggers:
  """What a KEDA ScaledObject and ScaledJob share: triggers, and the TriggerAuthentications they use."""
  triggers: [Trigger] = []
  authentications: [TriggerAuth] = []

  check:
    len(authentications) == len({a.name: 1 for a in authentications}), "authentication names must be unique"
    all t in triggers {not t.auth or t.auth in [a.name for a in authentications]}, "every trigger `auth` must name an entry of `authentications`: ${[t.auth for t in triggers if t.auth]} vs ${[a.name for a in authentications]}"

schema Fallback:
  """KEDA fallback: the replica count to hold after `failureThreshold` consecutive failed metric reads."""
  failureThreshold: int = 3
  replicas: int

schema Scaler(Triggers):
  """
    KEDA ScaledObject, the workload's only autoscaler: KEDA creates and owns the
    autoscaling/v2 HPA behind it, and adds scale-to-zero and event triggers.

    Convenience: `cpu`/`memory` become KEDA cpu/memory utilization triggers.
    `triggers` is any KEDA scaler: each item = {type, metadata:{..}, metricType?,
    name?, auth?}. Set `minReplicas = 0` for scale-to-zero. At least one of
    cpu/memory/triggers must be present.
    """
  minReplicas: int = 1
  maxReplicas: int = 10
  # → KEDA cpu trigger, Utilization %
  cpu?: int
  # → KEDA memory trigger, Utilization %
  memory?: int
  pollingInterval?: int
  cooldownPeriod?: int
  # → idleReplicaCount: replicas while every trigger is inactive; KEDA only
  # supports 0 here and it must be below minReplicas
  idleReplicas?: int
  # → advanced.horizontalPodAutoscalerConfig.behavior
  behavior?: {str:}
  fallback?: Fallback
  # → autoscaling.keda.sh/paused: KEDA stops scaling and leaves the current
  # replica count alone until the annotation is gone
  paused: bool = False

  check:
    cpu or memory or triggers, "Scaler needs at least one of cpu, memory, or triggers"
    idleReplicas == Undefined or idleReplicas < minReplicas, "idleReplicas (${idleReplicas}) must be below minReplicas (${minReplicas}); KEDA supports only 0"
    not fallback or not (cpu or memory), "KEDA rejects `fallback` next to cpu/memory triggers: the fallback replaces an external metric, and those are resource metrics"
    not fallback or all t in triggers {t.metricType == Undefined or t.metricType == "AverageValue"}, "KEDA applies `fallback` only to AverageValue triggers"

schema JobScaler(Triggers):
  """
    KEDA ScaledJob: instead of one Job, KEDA starts Jobs from the Task's
    template as the triggers report pending work (a queue backlog, a
    subscription), up to `maxReplicas` at once, and none while idle.
    """
  minReplicas: int = 0
  maxReplicas: int = 100
  pollingInterval?: int
  # → scalingStrategy.strategy: how pending work maps to new Jobs
  strategy: "default" | "custom" | "accurate" | "eager" = "default"

  check:
    triggers, "a ScaledJob needs at least one trigger: it has nothing else to count work with"

schema Fault:
  """
    One fault injected into this workload's own pods. The selector is always
    `app=<name>` in the workload's namespace — a Fault never carries one, so
    its blast radius is exactly this workload. `type` picks the experiment:
                                                                   Chaos Mesh      Litmus (chaos-charts)
      pod-kill | pod-failure | container-kill                      → PodChaos        pod-delete | — | container-kill
      delay | loss | corrupt | duplicate                           → NetworkChaos    pod-network-latency | -loss | -corruption | -duplication
      bandwidth | partition                                        → NetworkChaos    pod-network-rate-limit | pod-network-partition
      cpu | memory                                                 → StressChaos     pod-cpu-hog | pod-memory-hog
      http-delay | http-abort                                      → HTTPChaos       pod-http-latency | pod-http-reset-peer
      io-latency | io-fault                                        → IOChaos         —
      dns-error | dns-random                                       → DNSChaos        pod-dns-error | —
      time-skew                                                    → TimeChaos       —
    `provider` picks the operator. Chaos Mesh (default): without `schedule`
    a one-shot experiment that runs for `duration` as soon as it is applied
    (pod-kill is instantaneous); with `schedule` (cron) a Chaos Mesh Schedule
    that recurs. Litmus: a ChaosEngine (+ its ChaosExperiment definition and
    runner RBAC) in the `litmus` namespace, run once. Every shape Litmus
    cannot express (the `—` rows, cron, pod counts, path/method matching, …)
    is rejected below rather than approximated.
    """
  # → "<workload>-<name>" (Chaos Mesh) / "<namespace>-<workload>-<name>" (Litmus)
  name: str
  $type: "pod-kill" | "pod-failure" | "container-kill" | "delay" | "loss" | "partition" | "bandwidth" | "corrupt" | "duplicate" | "cpu" | "memory" | "http-abort" | "http-delay" | "io-latency" | "io-fault" | "dns-error" | "dns-random" | "time-skew"
  # the operator that injects it
  provider: "chaos-mesh" | "litmus" = "chaos-mesh"
  # how many of the workload's pods are hit
  mode: "one" | "all" | "fixed" | "fixed-percent" | "random-max-percent" = "one"
  # fixed: pod count; fixed-percent / random-max-percent: 0-100
  value?: str
  duration: str = "30s"
  # delay / http-delay / io-latency
  latency: str = "100ms"
  jitter?: str
  correlation?: str
  # loss / corrupt / duplicate: percent of packets, 0-100
  loss: str = "10"
  corrupt: str = "10"
  duplicate: str = "10"
  # bandwidth: tc tbf rate, bucket size in bytes, queue limit in bytes
  rate: str = "1mbps"
  buffer: int = 10000
  limit: int = 20971520

  # network types: which traffic. Without a target Chaos Mesh only
  # shapes outbound (`to`) traffic; a partition may also cut `from` / `both`.
  direction: "to" | "from" | "both" = "to"
  # network types: only traffic to these IPs or hostnames (default: all)
  externalTargets?: [str]
  # cpu / memory: stress-ng workers
  workers: int = 1
  # cpu: load per worker, percent of one core
  load: int = 100
  # memory: per-worker allocation, e.g. "256MB" or "50%"
  size?: str
  # http-*: requests into the pod, or its responses; on which port (inside
  # `app`: the workload's own), for which path / method (default: all)
  httpTarget: "Request" | "Response" = "Request"
  port?: int
  # http-*: URL path; io-*: file glob inside the volume
  path?: str
  method?: str
  # io-*: mount point of the volume to inject into (one volume per fault)
  volumePath?: str
  # io-fault: errno returned (5 = EIO)
  errno: int = 5
  # io-*: percent of matching calls that are hit
  percent: int = 100
  # io-*: syscalls to hit (read, write, open, …; default: all)
  methods?: [str]
  # dns-*: domain patterns (wildcards allowed; default: every lookup)
  patterns?: [str]
  # time-skew: offset added to the clock, e.g. "-10m" or "2h"
  timeOffset: str = "-10m"
  # time-skew: CLOCK_* ids (default CLOCK_REALTIME)
  clockIds?: [str]
  # container-kill / stress / io / dns / time: default the workload's own container
  containerNames?: [str]
  # cron → a Chaos Mesh Schedule instead of a one-shot experiment
  schedule?: str
  # Schedule only: skip a tick while the previous run is still active
  concurrencyPolicy: "Forbid" | "Allow" = "Forbid"
  # Schedule only: finished experiments kept for inspection
  historyLimit: int = 1

  check:
    mode in ["one", "all"] or value, "mode ${mode} needs `value` (a pod count or a percent)"
    direction == "to" or $type == "partition", "${$type} without a target can only shape outbound (`to`) traffic; use `partition` for from/both"
    $type != "partition" or direction == "to" or externalTargets, "a partition with direction ${direction} needs `externalTargets`"
    $type not in ["io-latency", "io-fault"] or volumePath, "${$type} needs `volumePath`: the mount point of the volume Chaos Mesh hooks the syscalls of"
    0 <= percent <= 100, "percent is a share of calls, 0-100: ${percent}"
    # Litmus: only what its generic experiments can do, in the units they take.
    provider != "litmus" or $type != "pod-failure", "fault ${name}: pod-failure has no Litmus experiment (Litmus cannot swap a pod's containers for a pause image); use provider chaos-mesh"
    provider != "litmus" or $type not in ["io-latency", "io-fault"], "fault ${name}: ${$type} has no Litmus experiment (Litmus has no syscall-level IO injection; pod-io-stress only loads the disk); use provider chaos-mesh"
    provider != "litmus" or $type != "dns-random", "fault ${name}: dns-random has no Litmus experiment (pod-dns-spoof answers named hosts with chosen ones; it cannot return random IPs); use provider chaos-mesh"
    provider != "litmus" or $type != "time-skew", "fault ${name}: time-skew has no Litmus experiment (Litmus has no clock fault); use provider chaos-mesh"
    provider != "litmus" or not schedule, "fault ${name}: a Litmus ChaosEngine runs once and has no cron (recurring runs are ChaosCenter workflows); use provider chaos-mesh for `schedule`"
    provider != "litmus" or mode in ["one", "all", "fixed-percent"], "fault ${name}: Litmus picks pods by percentage only (PODS_AFFECTED_PERC); mode ${mode} has no equivalent — use one, all or fixed-percent"
    provider != "litmus" or regex.match(duration, r"^([0-9]+h)?([0-9]+m)?([0-9]+s)?$") and duration, "fault ${name}: Litmus takes TOTAL_CHAOS_DURATION in whole seconds; write duration as h/m/s, e.g. 90s or 1m30s (got ${duration})"
    provider != "litmus" or $type not in ["delay", "http-delay"] or regex.match(latency, r"^[0-9]+(ms|s)$"), "fault ${name}: Litmus takes latency in whole milliseconds; write it as <n>ms or <n>s (got ${latency})"
    provider != "litmus" or not jitter or regex.match(jitter, r"^[0-9]+(ms|s)$"), "fault ${name}: Litmus takes jitter in whole milliseconds; write it as <n>ms or <n>s (got ${jitter})"
    provider != "litmus" or not correlation or regex.match(correlation, r"^[0-9]+$"), "fault ${name}: Litmus takes correlation as a whole percent (got ${correlation})"
    provider != "litmus" or $type != "memory" or size and regex.match(size, r"^[0-9]+(MB|GB)$"), "fault ${name}: Litmus pod-memory-hog needs `size` in MB or GB (MEMORY_CONSUMPTION); a percent of the limit has no equivalent"
    provider != "litmus" or $type not in ["http-delay", "http-abort"] or not (path or method), "fault ${name}: Litmus HTTP faults proxy every connection to the port (toxiproxy) and cannot match a path or method"
    provider != "litmus" or $type != "dns-error" or not patterns or all_true([regex.match(p, r"^\*?[^*]+\*?$") for p in patterns]), "fault ${name}: Litmus matches DNS names exactly or by substring; a wildcard may only lead or trail a pattern"
    provider != "litmus" or $type != "partition" or mode == "all", "fault ${name}: Litmus partitions with a NetworkPolicy over every pod carrying the label; set mode: all"

schema PolicyRule:
  """One namespaced RBAC rule granted to the ServiceAccount: verbs on resources of API groups ("" = core)."""
  apiGroups: [str] = [""]
  resources: [str]
  verbs: [str]
  resourceNames?: [str]

schema ServiceAccount:
  """
    The pod's identity. `create` (default) renders a ServiceAccount named after
    the workload (or `name`); `create: false` only points the pod at one that
    already exists. The API token is NOT mounted unless `automountToken` — an
    app that never calls the API server should not carry a credential for it.

    `cloud` + `identity` is the workload-identity shorthand, rendered as the
    annotation each cloud's federation reads:
      gcp   → iam.gke.io/gcp-service-account = <GSA email>
      aws   → eks.amazonaws.com/role-arn = <IAM role ARN>
      azure → azure.workload.identity/client-id = <managed identity client id>,
              plus the azure.workload.identity/use pod label the webhook needs
    `rules` → a Role + RoleBinding for this ServiceAccount alone, in the
    workload's namespace; there is deliberately no cluster-scope variant.
    """
  create: bool = True
  name?: str
  automountToken: bool = False
  annotations: {str:str} = {}
  labels: {str:str} = {}
  cloud?: "gcp" | "aws" | "azure"
  identity?: str
  imagePullSecrets: [str] = []
  rules: [PolicyRule] = []

  check:
    (cloud == Undefined) == (identity == Undefined), "`cloud` and `identity` go together: the cloud says which annotation, the identity is its value"
    create or not (annotations or labels or cloud or imagePullSecrets), "annotations / labels / cloud / imagePullSecrets describe a ServiceAccount this package creates; with `create: false` it is only referenced"

schema DisruptionBudget:
  """PodDisruptionBudget over the workload's pods: how many must survive a voluntary eviction (drain, upgrade). Exactly one of the two."""
  minAvailable?: int | str
  maxUnavailable?: int | str

  check:
    (minAvailable == Undefined) != (maxUnavailable == Undefined), "a disruption budget needs exactly one of minAvailable / maxUnavailable"

schema GatewayRef:
  """
    The Gateway an HTTPRoute attaches to (its parentRef). Referenced, never
    created: a Gateway is a load balancer, and the platform owns it.
    """
  name: str
  # default: the route's own namespace
  namespace?: str
  # the listener; unset attaches to every listener that admits the route
  sectionName?: str
  port?: int

schema HeaderFilter:
  """
    A RequestHeaderModifier: headers the Gateway sets (replacing any value),
    adds (appending to any value) and removes before the request reaches the
    workload.
    """
  set: {str:str} = {}
  add: {str:str} = {}
  remove: [str] = []

  check:
    set or add or remove, "requestHeaders with nothing to do: give `set`, `add` or `remove`"
    all h in remove {h not in set and h not in add}, "headers both removed and set/added: ${[h for h in remove if h in set or h in add]}"

schema RouteRule:
  """One path match of an HTTPRoute, sent to the workload's Service. Unset `port`, `timeout` and `requestHeaders` take the route's."""
  path: str = "/"
  pathType: "PathPrefix" | "Exact" | "RegularExpression" = "PathPrefix"
  port?: int
  # Gateway API duration: "30s", "1m30s", "500ms"
  timeout?: str
  requestHeaders?: HeaderFilter

schema HttpsRedirect:
  """
    A second HTTPRoute, "<name>-https-redirect", on the Gateway's plain-HTTP
    listener: every request for the route's hostnames is answered with a
    redirect to https. The listener has to admit routes from the workload's
    namespace; a Gateway whose HTTP listener is `from: Same` (main-gateway)
    already redirects for every host and rejects this one.
    """
  sectionName: str = "http"
  statusCode: 301 | 302 = 301

schema HttpRoute:
  """
    A Gateway API HTTPRoute (gateway.networking.k8s.io/v1) to the workload's
    Service.

    `enabled` is the switch: env overlays deep-merge over the base, so an
    environment turns the route off with `route.enabled: false` rather than by
    deleting the block. Disabled, nothing renders and nothing else is required.

    One rule from `path` / `pathType`, or several from `rules`. `port`,
    `timeout` and `requestHeaders` here are every rule's defaults.
    """
  enabled: bool = True
  hostnames: [str] = []
  gateway?: GatewayRef
  path?: str
  pathType?: "PathPrefix" | "Exact" | "RegularExpression"
  rules: [RouteRule] = []
  # Service port; default the workload's `port`, which the Service exposes
  port?: int
  # Gateway API duration: "30s", "1m30s", "500ms"
  timeout?: str
  requestHeaders?: HeaderFilter
  httpsRedirect?: HttpsRedirect
  labels: {str:str} = {}
  annotations: {str:str} = {}

  check:
    not enabled or hostnames, "route needs `hostnames` (or `enabled: false`)"
    not enabled or gateway, "route needs a `gateway` to attach to (or `enabled: false`)"
    not (rules and (path or pathType)), "with `rules`, give `path` / `pathType` on each rule, not on the route"
    len(rules) <= 16, "an HTTPRoute holds at most 16 rules (${len(rules)})"
    not httpsRedirect or (gateway and gateway.sectionName and gateway.sectionName != httpsRedirect.sectionName), "httpsRedirect needs `gateway.sectionName` (the HTTPS listener), different from httpsRedirect.sectionName: otherwise the route also serves plain HTTP next to the redirect"

schema AlertRule:
  """One Prometheus alerting rule → an entry of the workload's PrometheusRule."""
  alert: str
  expr: str
  $for: str = "5m"
  severity: "critical" | "warning" | "info" = "warning"
  summary?: str
  description?: str
  runbookUrl?: str
  labels: {str:str} = {}

schema Panel:
  """A Grafana panel over one PromQL query; the datasource is the dashboard's `datasource` variable."""
  title: str
  expr: str
  # legendFormat, e.g. "{{pod}}"
  legend?: str
  $type: "timeseries" | "stat" | "gauge" = "timeseries"
  # Grafana unit id: short, percent, bytes, s, reqps, …
  unit: str = "short"

schema Dashboard:
  """
    A Grafana dashboard, shipped as a ConfigMap the Grafana sidecar
    (kube-prometheus-stack) loads. Either `json` (a dashboard exported from
    Grafana, used verbatim) or generated: the standard workload panels (replicas,
    CPU, memory, restarts, scrape targets) followed by `panels`.
    """
  name: str
  # default "<workload> / <name>"
  title?: str
  # → the sidecar's folder annotation
  folder?: str
  json?: str
  standard: bool = True
  panels: [Panel] = []

  check:
    not (json and panels), "dashboard ${name}: `json` is used verbatim, so `panels` would be ignored — pick one"
    json or standard or panels, "dashboard ${name}: nothing to show — set `json`, `panels`, or keep `standard`"

schema Monitoring:
  """
    Prometheus Operator objects for the workload (kube-prometheus-stack):
      scrape       → a ServiceMonitor (through the Service) or a PodMonitor
                     (the pods directly, no Service needed) on `portName` +
                     `metricsPath`
      defaultRules → alerts for scrape targets down, restarts and unavailable
                     replicas (kube-state-metrics)
      rules        → more alerts, in the same PrometheusRule
      dashboards   → Grafana dashboards, one ConfigMap each
    All queries are pinned to the workload's namespace, which is why
    monitoring needs one — the same rule as `chaos:`.
    """
  kind: "ServiceMonitor" | "PodMonitor" = "ServiceMonitor"
  scrape: bool = True
  interval: str = "30s"
  scrapeTimeout?: str
  # What the Prometheus selectors match: kube-prometheus-stack selects
  # monitors and rules by release=<helm release> unless its
  # *SelectorNilUsesHelmValues are false.
  labels: {str:str} = {release = "kube-prometheus-stack"}
  defaultRules: bool = False
  rules: [AlertRule] = []
  dashboards: [Dashboard] = []
  # Grafana sidecar discovery: the label it watches and its folderAnnotation
  dashboardLabels: {str:str} = {grafana_dashboard = "1"}
  folderAnnotation: str = "grafana_folder"
  # default: the workload's namespace (the sidecar needs searchNamespace: ALL)
  dashboardNamespace?: str

  check:
    scrape or defaultRules or rules or dashboards, "monitoring with nothing to render: enable `scrape`, `defaultRules`, or add `rules` / `dashboards`"
    len(dashboards) == len({d.name: 1 for d in dashboards}), "dashboard names must be unique"

schema Dapr:
  """
    Dapr sidecar (daprd) injected into the workload's pods, rendered as the
    pod-template annotations the Dapr sidecar injector reads. The app reaches
    its broker only through daprd: it publishes to and subscribes on the
    namespace's `pubsub` Component by topic, so one image runs unchanged on
    Kafka (kind), GCP Pub/Sub (GKE) or SNS+SQS (AWS). Subscriptions are
    declared by the app itself (daprd asks it on GET /dapr/subscribe), which is
    why nothing here names a topic. daprd injects DAPR_HTTP_PORT /
    DAPR_GRPC_PORT into the app container and calls the app on the
    workload's `port` (dapr.io/app-port), so that port is always the one the
    container declares.
    """
  # dapr.io/app-id: the name other apps invoke this one by; default the
  # workload's name
  appId?: str
  # dapr.io/app-protocol: how daprd calls the app on its `port`
  protocol: "http" | "grpc" = "http"

  # dapr.io/app-max-concurrency: events daprd hands the app at once (unset:
  # unlimited), the backpressure knob for a slow consumer
  maxConcurrency?: int
  # dapr.io/config: a Dapr Configuration in the workload's namespace
  # (tracing, metrics, access control)
  config?: str
  # dapr.io/enable-app-health-check: daprd stops delivering events while the
  # app is unhealthy. Probes the path of the workload's readinessProbe (else
  # livenessProbe), and only when that is an http probe on `port` with an
  # http app protocol: daprd polls the app port over the app protocol, so
  # any other probe would describe something daprd cannot reach.
  appHealthCheck: bool = True

  # daprd container resources, Workload.resources-shaped →
  # dapr.io/sidecar-{cpu,memory}-{request,limit}. No cpu limit by default,
  # the same as the app container's.
  sidecarResources: {str:{str:str}} = {requests = {cpu = "100m", memory = "64Mi"}, limits = {memory = "256Mi"}}

  check:
    maxConcurrency == Undefined or maxConcurrency > 0, "dapr.maxConcurrency must be positive (${maxConcurrency}); leave it unset for unlimited"
    all k in sidecarResources {k in ["requests", "limits"]}, "dapr.sidecarResources takes `requests` / `limits`: ${[k for k in sidecarResources]}"
    all _, v in sidecarResources {all r in v {r in ["cpu", "memory"]}}, "dapr.sidecarResources: the injector has annotations for cpu and memory only"

schema Workload:
  """A deployable long-running application: Deployment (+ Service, HTTPRoute, ServiceAccount/RBAC, PodDisruptionBudget, KEDA ScaledObject, Prometheus monitors/rules/dashboards, Chaos Mesh / Litmus faults)."""
  name: str = "app"
  namespace?: str
  component: str = "server"
  partOf: str = "zerg"
  version?: str = "0.1.0"
  image: str
  imagePullPolicy: str = "IfNotPresent"
  replicas: int = 0
  port: int = 8080
  portName: str = "http"
  runAsUser: int = 65534
  runAsGroup?: int
  readOnlyRootFilesystem: bool = True
  prometheus: bool = True
  metricsPath: str = "/metrics"
  startupProbe?: Probe
  livenessProbe?: Probe
  readinessProbe?: Probe
  resources: {str:} = {requests = {memory = "128Mi", cpu = "250m"}, limits = {memory = "512Mi"}}
  env: [EnvVar] = []
  envFrom: [EnvFrom] = []
  volumeMounts: [{str:}] = [{name = "tmp", mountPath = "/tmp"}]
  volumes: [{str:}] = [{name = "tmp", emptyDir = {}}]
  terminationGracePeriodSeconds: int = 30
  service: bool = True
  serviceType: str = "ClusterIP"
  # pod identity (+ namespaced RBAC); absent → the namespace's `default` SA
  serviceAccount?: ServiceAccount
  # PodDisruptionBudget over the pods
  disruptionBudget?: DisruptionBudget
  # Gateway API HTTPRoute to the Service (`enabled: false` turns it off per env)
  route?: HttpRoute
  # ServiceMonitor / PodMonitor, PrometheusRule, Grafana dashboards (needs `namespace`)
  monitoring?: Monitoring
  # KEDA ScaledObject: the autoscaler (KEDA owns the HPA behind it)
  scaler?: Scaler
  # Dapr sidecar: pub/sub (and state, invocation) through the namespace's
  # Dapr Components instead of a broker SDK
  dapr?: Dapr
  # Chaos Mesh / Litmus experiments against this workload's pods (needs `namespace`)
  chaos: [Fault] = []
  podAnnotations: {str:str} = {}

  # Extra pod template labels, e.g. azure.workload.identity/use when the
  # ServiceAccount is created elsewhere (`create: false`) and `cloud` is unset.
  podLabels: {str:str} = {}
  # Scheduling: pod nodeSelector and tolerations, e.g. a dedicated node pool.
  nodeSelector: {str:str} = {}
  tolerations: [{str:}] = []
  extraManifests: [{str:}] = []

  check:
    not chaos or namespace, "chaos faults need an explicit `namespace`: the experiment selector is pinned to it"
    len(chaos) == len({f.name: 1 for f in chaos}), "chaos fault names must be unique"
    not monitoring or namespace, "monitoring needs an explicit `namespace`: every query and selector is pinned to it"
    not (monitoring and monitoring.scrape and monitoring.kind == "ServiceMonitor" and not service), "a ServiceMonitor scrapes through the Service, and `service` is false — use monitoring.kind: PodMonitor"
    not (route and route.enabled and not service), "an HTTPRoute sends traffic to the workload's Service, and `service` is false"
    not (serviceAccount and serviceAccount.rules) or namespace, "serviceAccount.rules need an explicit `namespace`: a RoleBinding subject names the ServiceAccount's namespace"
    # The Dapr app-id also names the "<app-id>-dapr" Service the injector
    # creates, so it has to be a DNS label with room for that suffix.
    not dapr or regex.match(dapr.appId or name, r"^[a-z0-9]([-a-z0-9]{0,56}[a-z0-9])?$"), "dapr app-id '${dapr?.appId or name}' must be a DNS label of at most 58 characters ([a-z0-9-]): the injector adds a '<app-id>-dapr' Service"

# Not checkable here, but required: the target namespace must be
# labelled `shluviza.com/dapr: enabled`. That label is what gives it the
# `pubsub` Component and the `Resiliency/platform-defaults` policy
# (vendor/gitops/platform/dapr); without it daprd starts, but every
# publish and subscription on `pubsub` fails.
schema Task:
  """A run-to-completion CLI workload: Job, a CronJob when `schedule` is set, or a KEDA ScaledJob when `scaler` is."""
  name: str = "app"
  namespace?: str
  component: str = "job"
  partOf: str = "zerg"
  version?: str = "0.1.0"
  image: str
  imagePullPolicy: str = "IfNotPresent"
  command?: [str]
  args?: [str]
  runAsUser: int = 65534
  runAsGroup?: int
  readOnlyRootFilesystem: bool = True
  resources: {str:} = {requests = {memory = "128Mi", cpu = "250m"}, limits = {memory = "512Mi"}}
  env: [EnvVar] = []
  envFrom: [EnvFrom] = []
  volumeMounts: [{str:}] = [{name = "tmp", mountPath = "/tmp"}]
  volumes: [{str:}] = [{name = "tmp", emptyDir = {}}]
  # pod identity (+ namespaced RBAC); absent → the namespace's `default` SA
  serviceAccount?: ServiceAccount
  # KEDA ScaledJob instead of a single Job: Jobs started per pending work item
  scaler?: JobScaler
  # Job controls
  restartPolicy: "Never" | "OnFailure" = "Never"
  backoffLimit: int = 3
  completions?: int
  parallelism?: int
  activeDeadlineSeconds?: int
  ttlSecondsAfterFinished?: int = 3600
  # CronJob controls (used only when `schedule` is set)
  schedule?: str
  concurrencyPolicy: "Allow" | "Forbid" | "Replace" = "Forbid"
  suspend?: bool
  startingDeadlineSeconds?: int
  # CronJob / ScaledJob: finished Jobs kept
  successfulJobsHistoryLimit: int = 3
  failedJobsHistoryLimit: int = 1
  # Extra pod template labels (see Workload.podLabels).
  podLabels: {str:str} = {}
  # Scheduling (see Workload.nodeSelector / tolerations).
  nodeSelector: {str:str} = {}
  tolerations: [{str:}] = []
  extraManifests: [{str:}] = []

  check:
    not (schedule and scaler), "a Task runs on a `schedule` (CronJob) or on pending work (`scaler`, a KEDA ScaledJob), not both"
    not (serviceAccount and serviceAccount.rules) or namespace, "serviceAccount.rules need an explicit `namespace`: a RoleBinding subject names the ServiceAccount's namespace"

schema ExternalSecretSpec:
  """A GCP/cloud ExternalSecret: `items` = [{secretKey, key, property}]."""
  # defaults to "<release name>-secrets"
  name?: str
  store: str = "gcp-secret-manager"
  refreshInterval: str = "1h"
  items: [{str:str}]

schema Link:
  """One `metadata.links` entry of a Backstage entity: where it points, and how it is labelled."""
  url: str
  title?: str
  # Backstage icon key, e.g. dashboard | docs | alert | chat
  icon?: str
  $type?: str

schema Api:
  """
    An API entity this component provides. Emitted next to the Component and
    added to its `providesApis`, so the link between the two is never written
    twice.

    Backstage refuses an API entity with no definition, so give it one: inline
    in `definition`, or as `definitionUrl` for something the catalog fetches at
    import time (`$text`).
    """
  name: str
  $type: "openapi" | "asyncapi" | "graphql" | "grpc" = "openapi"
  description?: str
  # both default to the Component's
  lifecycle?: "experimental" | "production" | "deprecated"
  owner?: str
  definition?: str
  definitionUrl?: str

  check:
    definition or definitionUrl, "api ${name}: needs `definition` (the spec inline) or `definitionUrl` (fetched by the catalog); Backstage rejects an API entity without one"
    not (definition and definitionUrl), "api ${name}: `definition` and `definitionUrl` are two ways to say the same thing — pick one"

schema Catalog:
  """
    Backstage catalog metadata for this release: what the portal shows, and how
    it finds the objects that are actually running.

    The entities are NOT Kubernetes objects and never join the manifest stream
    (see `catalogEntities`). What ties them to the cluster is one id: the
    Component is annotated `backstage.io/kubernetes-id`, every rendered object
    is labelled with it, and so the Kubernetes plugin resolves the Deployment,
    the Service, the autoscaler and the Chaos Mesh experiments of this release
    from the entity alone. The declared faults are also summarised in the
    `platform.example.org/chaos-faults` annotation, so the portal can say what
    chaos is aimed at a component without reaching the cluster at all.

    Only `owner` is required — everything else is either derived from the
    workload (name, namespace, system, archetype) or genuinely optional.
    """
  # spec.owner. Required: Backstage will not accept an ownerless entity.
  owner: str
  # entity name; default: the workload's / task's own name
  name?: str
  title?: str
  description?: str
  # spec.type; default: "service" for a workload, "cronjob" / "job" for a task
  $type?: str
  lifecycle: "experimental" | "production" | "deprecated" = "production"
  # spec.system; default: the workload's `partOf`
  system?: str
  tags: [str] = []
  labels: {str:str} = {}

  # merged OVER the generated annotations, so a values file can override the
  # kubernetes-id when the objects are labelled by something else
  annotations: {str:str} = {}
  links: [Link] = []
  # entity refs, e.g. "component:other-api", "resource:orders-db"
  dependsOn: [str] = []
  consumesApis: [str] = []
  # refs to APIs declared elsewhere; the `apis:` below are added automatically
  providesApis: [str] = []
  apis: [Api] = []
  subcomponentOf?: str
  # → backstage.io/techdocs-ref, e.g. "dir:." for docs/ next to the entity
  techdocs?: str
  # → backstage.io/source-location, e.g. "url:https://github.com/org/repo/tree/main/"
  source?: str

  check:
    name == Undefined or regex.match(name, r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$"), "catalog name '${name}' is not a valid Backstage entity name: [A-Za-z0-9._-], starting and ending alphanumeric, at most 63 characters"
    all t in tags {regex.match(t, r"^[a-z0-9][a-z0-9+#-]*$")}, "catalog tags must be lowercase [a-z0-9+#-] and start alphanumeric — Backstage rejects the rest: ${tags}"

schema Release:
  """
    A whole app release in one values.yaml (Helm-style).

    Exactly one of `workload` (long-running: backend/frontend) or `task`
    (batch/CLI: Job/CronJob). Optional `config` → a ConfigMap named
    "<name>-config"; optional `externalSecret` → an ExternalSecret; optional
    `catalog` → the Backstage entities, rendered on their own (see
    `catalogEntities`) because they are not Kubernetes objects. This is what
    `app`'s own main.k renders when a values.yaml is present, so a consumer needs
    only a values.yaml — no local main.k / kcl.mod.
    """
  workload?: Workload
  task?: Task
  config?: configMap
  # config?: _deployment = lambda w: Workload -> appsv1.Deployment
  config?: appsv1.Deployment
  externalSecret?: ExternalSecretSpec
  catalog?: Catalog

  check:
    workload or task, "Release needs a `workload:` or a `task:`"
    not (workload and task), "Release can't have both `workload:` and `task:`"

# ── Shared container atoms (env / envFrom / probe) ───────────────────────────
_envVar = lambda e: EnvVar -> {str:} {
  {name = e.name} | ({value = e.value} if e.value else {
    valueFrom = {
      secretKeyRef = {name = e.secretName, key = e.secretKey, optional = e.optional}
    }
  } if e.secretName else {
    valueFrom = {
      configMapKeyRef = {name = e.configMapName, key = e.configMapKey}
    }
  } if e.configMapName else {})
}

_envFrom = lambda f: EnvFrom -> {str:} {
  {
    configMapRef = {name = f.name}
  } if f.kind == "configMap" else {
    secretRef = {name = f.name, optional = f.optional}
  }
}

_probe = lambda p: Probe -> {str:} {
  ({
    httpGet = {path = p.path, port = p.port}
  } if p.$type == "http" else {
    grpc = {port = p.port}
  }) | {
    periodSeconds = p.periodSeconds
    failureThreshold = p.failureThreshold
    timeoutSeconds = p.timeoutSeconds
  } | ({initialDelaySeconds = p.initialDelaySeconds} if p.initialDelaySeconds else {})
}

# ── Workload renderers ───────────────────────────────────────────────────────
_labels = lambda w: Workload -> {str:str} {
  {
    "app" = w.name
    "app.kubernetes.io/name" = w.name
    "app.kubernetes.io/component" = w.component
    "app.kubernetes.io/part-of" = w.partOf
    # What the Backstage Kubernetes plugin matches on: an entity annotated
    # backstage.io/kubernetes-id=<id> is shown every object labelled with
    # the same id. Deliberately not part of the Deployment's
    # selector.matchLabels (which stays `app` alone) — a selector is
    # immutable, and this label has to stay free to change.
    "backstage.io/kubernetes-id" = w.name
  } | ({"app.kubernetes.io/version" = w.version} if w.version else {})
}

# Dapr's injector reads the pod template's annotations only. The health check
# reuses a probe only when daprd can actually reach it (see Dapr.appHealthCheck).
_daprHealthPath = lambda w: Workload -> str {
  _probes = [p for p in [w.readinessProbe, w.livenessProbe] if p and p.$type == "http" and p.path and p.port in [w.port, w.portName]]
  _probes[0].path if _probes and w.dapr.appHealthCheck and w.dapr.protocol == "http" else ""
}

_daprAnnotations = lambda w: Workload -> {str:str} {
  _d = w.dapr
  _health = _daprHealthPath(w)
  {
    "dapr.io/enabled" = "true"
    "dapr.io/app-id" = _d.appId or w.name
    "dapr.io/app-port" = "${w.port}"
    "dapr.io/app-protocol" = _d.protocol
    "dapr.io/log-as-json" = "true"
  } | ({"dapr.io/app-max-concurrency" = "${_d.maxConcurrency}"} if _d.maxConcurrency else {}) | ({"dapr.io/config" = _d.config} if _d.config else {}) | {"dapr.io/sidecar-${r}-${'request' if kind == 'requests' else 'limit'}" = q for kind, rs in _d.sidecarResources for r, q in rs} | ({
    "dapr.io/enable-app-health-check" = "true"
    "dapr.io/app-health-check-path" = _health
  } if _health else {})
}

_podAnnotations = lambda w: Workload -> {str:str} {
  (({
    "prometheus.io/scrape" = "true"
    "prometheus.io/port" = "${w.port}"
    "prometheus.io/path" = w.metricsPath
  }) if w.prometheus else {}) | (_daprAnnotations(w) if w.dapr else {}) | w.podAnnotations
}

# Pod-level seccompProfile is unconditional: Pod Security `restricted` also
# checks containers injected by others (the Dapr sidecar carries no seccomp
# profile of its own by default), and the pod-level one is what covers them.
_podSecurity = lambda w: Workload -> {str:} {
  {
    runAsNonRoot = True
    runAsUser = w.runAsUser
    seccompProfile = {$type = "RuntimeDefault"}
  } | ({runAsGroup = w.runAsGroup, fsGroup = w.runAsGroup} if w.runAsGroup else {fsGroup = w.runAsUser})
}

_container = lambda w: Workload -> {str:} {
  {
    name = w.name
    image = w.image
    imagePullPolicy = w.imagePullPolicy
    ports = [{containerPort = w.port, name = w.portName, $protocol = "TCP"}]
  } | ({envFrom = [_envFrom(f) for f in w.envFrom]} if w.envFrom else {}) | ({env = [_envVar(e) for e in w.env]} if w.env else {}) | ({startupProbe = _probe(w.startupProbe)} if w.startupProbe else {}) | ({livenessProbe = _probe(w.livenessProbe)} if w.livenessProbe else {}) | ({readinessProbe = _probe(w.readinessProbe)} if w.readinessProbe else {}) | {
    resources = w.resources
    securityContext = {
      allowPrivilegeEscalation = False
      readOnlyRootFilesystem = w.readOnlyRootFilesystem
      runAsNonRoot = True
      runAsUser = w.runAsUser
      capabilities = {drop = ["ALL"]}
    }
    volumeMounts = w.volumeMounts
  }
}

# ── Identity (ServiceAccount + RBAC) — shared by Workload and Task ───────────
_saName = lambda owner: str, sa: ServiceAccount -> str {
  sa.name or owner
}

# The annotation each cloud's workload-identity federation reads off the
# ServiceAccount; the cloud side (GSA binding, IAM trust policy, federated
# credential) is packages/cloud/workload-identity's job, not this package's.
_identityAnnotation = {
  gcp = "iam.gke.io/gcp-service-account"
  aws = "eks.amazonaws.com/role-arn"
  azure = "azure.workload.identity/client-id"
}

_saCloudAnnotations = lambda sa: ServiceAccount -> {str:str} {
  {"${_identityAnnotation[sa.cloud]}" = sa.identity} if sa.cloud else {}
}

# Azure's mutating webhook only projects the federated token into pods that
# carry this label; GKE and EKS need nothing on the pod.
_saPodLabels = lambda sa: ServiceAccount -> {str:str} {
  {"azure.workload.identity/use" = "true"} if sa.cloud == "azure" else {}
}

_saPodSpec = lambda owner: str, sa: ServiceAccount -> {str:} {
  {serviceAccountName = _saName(owner, sa), automountServiceAccountToken = sa.automountToken}
}

_saObjects = lambda {
  owner: str,
  namespace: str,
  labels: {str:str},
  sa: ServiceAccount,
} -> [any] {
  _name = _saName(owner, sa)
  _meta = {name = _name, labels = labels} | ({namespace = namespace} if namespace else {})
  _ann = _saCloudAnnotations(sa) | sa.annotations
  _account: [any] = [corev1.ServiceAccount {
    metadata = _meta | {labels = labels | sa.labels} | ({annotations = _ann} if _ann else {})
    automountServiceAccountToken = sa.automountToken
    if sa.imagePullSecrets:
      imagePullSecrets = [{name = s} for s in sa.imagePullSecrets]
  }] if sa.create else []
  _rbac: [any] = [
    rbacv1.Role {
      metadata = _meta
      rules = [{apiGroups = r.apiGroups, resources = r.resources, verbs = r.verbs} | ({resourceNames = r.resourceNames} if r.resourceNames else {}) for r in sa.rules]
    }
    rbacv1.RoleBinding {
      metadata = _meta
      roleRef = {apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = _name}
      subjects = [{kind = "ServiceAccount", name = _name, namespace = namespace}]
    }
  ] if sa.rules else []
  _account + _rbac
}

_deployment = lambda w: Workload -> appsv1.Deployment {
  _ann = _podAnnotations(w)
  appsv1.Deployment {
    metadata = {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
    # Omit spec.replicas when an autoscaler (KEDA's HPA) owns it — otherwise
    # GitOps (Flux/ArgoCD) server-side apply and Flagger fight the autoscaler
    # over the replica count. The autoscaler's min is the floor.
    spec = ({replicas = w.replicas} if not w.scaler else {}) | {
      selector = {
        matchLabels = {app = w.name}
      }
      template = {
        metadata = {labels = _labels(w) | (_saPodLabels(w.serviceAccount) if w.serviceAccount else {}) | w.podLabels} | ({annotations = _ann} if _ann else {})
        spec = {
          securityContext = _podSecurity(w)
          containers = [_container(w)]
          volumes = w.volumes
          terminationGracePeriodSeconds = w.terminationGracePeriodSeconds
          restartPolicy = "Always"
        } | (_saPodSpec(w.name, w.serviceAccount) if w.serviceAccount else {}) | ({nodeSelector = w.nodeSelector} if w.nodeSelector else {}) | ({tolerations = w.tolerations} if w.tolerations else {})
      }
    }
  }
}

_app_resources = lambda w: Workload -> [any] {
  _ann = _podAnnotations(w)
  _data = _canary(w) + [
    {}
  ]
  _data
}

schema Resource:
  workloads: [Workload]
  config: Workload

_canary = lambda w: Workload -> [any] {
  _ann = _podAnnotations(w)
  []
}

_service = lambda w: Workload -> corev1.Service {
  corev1.Service {
    metadata = {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
    spec = {
      selector = {app = w.name}
      ports = [{$protocol = "TCP", name = w.portName, port = w.port, targetPort = w.port}]
      $type = w.serviceType
    }
  }
}

_meta = lambda w: Workload -> {str:} {
  {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
}

_pdb = lambda w: Workload -> policyv1.PodDisruptionBudget {
  _b = w.disruptionBudget
  policyv1.PodDisruptionBudget {
    metadata = _meta(w)
    spec = {
      selector = {
        matchLabels = {app = w.name}
      }
    } | ({minAvailable = _b.minAvailable} if _b.minAvailable != Undefined else {maxUnavailable = _b.maxUnavailable})
  }
}

# ── Route (Gateway API) ──────────────────────────────────────────────────────
_headerModifier = lambda h: HeaderFilter -> {str:} {
  {
    $type = "RequestHeaderModifier"
    requestHeaderModifier = ({set = [{name = k, value = v} for k, v in h.set]} if h.set else {}) | ({add = [{name = k, value = v} for k, v in h.add]} if h.add else {}) | ({remove = h.remove} if h.remove else {})
  }
}

_routeRule = lambda w: Workload, m: RouteRule -> {str:} {
  _r = w.route
  _headers = m.requestHeaders or _r.requestHeaders
  _timeout = m.timeout or _r.timeout
  {
    matches = [{
      path = {$type = m.pathType, value = m.path}
    }]
    backendRefs = [{name = w.name, port = m.port or _r.port or w.port}]
  } | ({filters = [_headerModifier(_headers)]} if _headers else {}) | ({
    timeouts = {request = _timeout}
  } if _timeout else {})
}

_routeMeta = lambda w: Workload, name: str -> {str:} {
  {name = name, labels = _labels(w) | w.route.labels} | ({namespace = w.namespace} if w.namespace else {}) | ({annotations = w.route.annotations} if w.route.annotations else {})
}

_httpRoute = lambda w: Workload -> gwapi.HTTPRoute {
  _r = w.route
  _g = _r.gateway
  _rules: [RouteRule] = _r.rules or [RouteRule {path = _r.path or "/", pathType = _r.pathType or "PathPrefix"}]
  gwapi.HTTPRoute {
    metadata = _routeMeta(w, w.name)
    spec = {
      parentRefs = [{name = _g.name} | ({namespace = _g.namespace} if _g.namespace else {}) | ({sectionName = _g.sectionName} if _g.sectionName else {}) | ({port = _g.port} if _g.port else {})]
      hostnames = _r.hostnames
      rules = [_routeRule(w, m) for m in _rules]
    }
  }
}

_redirectRoute = lambda w: Workload -> gwapi.HTTPRoute {
  _r = w.route
  _g = _r.gateway
  gwapi.HTTPRoute {
    metadata = _routeMeta(w, "${w.name}-https-redirect")
    spec = {
      parentRefs = [{name = _g.name, sectionName = _r.httpsRedirect.sectionName} | ({namespace = _g.namespace} if _g.namespace else {})]
      hostnames = _r.hostnames
      rules = [{filters = [{$type = "RequestRedirect", requestRedirect = {scheme = "https", statusCode = _r.httpsRedirect.statusCode}}]}]
    }
  }
}

_routes = lambda w: Workload -> [any] {
  ([_httpRoute(w)] + ([_redirectRoute(w)] if w.route.httpsRedirect else [])) if w.route and w.route.enabled else []
}

# ── KEDA renderers (ScaledObject / ScaledJob / TriggerAuthentication) ────────
_trigger = lambda owner: str, t: Trigger -> {str:} {
  {$type = t.$type, metadata = t.metadata} | ({name = t.name} if t.name else {}) | ({metricType = t.metricType} if t.metricType else {}) | ({useCachedMetrics = t.useCachedMetrics} if t.useCachedMetrics != Undefined else {}) | ({
    authenticationRef = {name = "${owner}-${t.auth}"}
  } if t.auth else {authenticationRef = t.authenticationRef} if t.authenticationRef else {})
}

_triggerAuth = lambda {
  owner: str,
  namespace: str,
  labels: {str:str},
  a: TriggerAuth,
} -> keda.TriggerAuthentication {
  keda.TriggerAuthentication {
    metadata = {name = "${owner}-${a.name}", labels = labels} | ({namespace = namespace} if namespace else {})
    spec = {} | ({
      secretTargetRef = [{parameter = s.parameter, name = s.name, key = s.key} for s in a.secrets]
    } if a.secrets else {}) | ({
      env = [{parameter = e.parameter, name = e.name} | ({containerName = e.containerName} if e.containerName else {}) for e in a.env]
    } if a.env else {}) | ({
      podIdentity = {provider = a.podIdentity} | ({identityId = a.identityId} if a.identityId else {})
    } if a.podIdentity else {})
  }
}

_scaler = lambda w: Workload -> keda.ScaledObject {
  _s = w.scaler
  # cpu/memory convenience → KEDA built-in scaler triggers
  _cpu: [{str:}] = [{$type = "cpu", metricType = "Utilization", metadata = {value = "${_s.cpu}"}}] if _s.cpu else []
  _mem: [{str:}] = [{$type = "memory", metricType = "Utilization", metadata = {value = "${_s.memory}"}}] if _s.memory else []
  _triggers = _cpu + _mem + [_trigger(w.name, t) for t in _s.triggers]
  keda.ScaledObject {
    metadata = _meta(w) | ({
      annotations = {"autoscaling.keda.sh/paused" = "true"}
    } if _s.paused else {})
    spec = {
      scaleTargetRef = {name = w.name}
      minReplicaCount = _s.minReplicas
      maxReplicaCount = _s.maxReplicas
      triggers = _triggers
    } | ({pollingInterval = _s.pollingInterval} if _s.pollingInterval else {}) | ({cooldownPeriod = _s.cooldownPeriod} if _s.cooldownPeriod else {}) | ({idleReplicaCount = _s.idleReplicas} if _s.idleReplicas != Undefined else {}) | ({
      fallback = {failureThreshold = _s.fallback.failureThreshold, replicas = _s.fallback.replicas}
    } if _s.fallback else {}) | ({
      advanced = {
        horizontalPodAutoscalerConfig = {behavior = _s.behavior}
      }
    } if _s.behavior else {})
  }
}

# ── Monitoring renderers (Prometheus Operator + Grafana sidecar) ─────────────
# The `job` label Prometheus gives the targets: a ServiceMonitor's default is
# the Service name, a PodMonitor's "<namespace>/<podmonitor name>".
_scrapeJob = lambda w: Workload -> str {
  w.name if w.monitoring.kind == "ServiceMonitor" else "${w.namespace}/${w.name}"
}

_monitor = lambda w: Workload -> any {
  _m = w.monitoring
  _metadata = {name = w.name, namespace = w.namespace, labels = _labels(w) | _m.labels}
  _endpoint = {port = w.portName, path = w.metricsPath, interval = _m.interval} | ({scrapeTimeout = _m.scrapeTimeout} if _m.scrapeTimeout else {})
  _spec = {
    selector = {
      matchLabels = {app = w.name}
    }
    namespaceSelector = {matchNames = [w.namespace]}
  }
  promop.ServiceMonitor {
    metadata = _metadata
    spec = _spec | {endpoints = [_endpoint]}
  } if _m.kind == "ServiceMonitor" else promop.PodMonitor {
    metadata = _metadata
    spec = _spec | {podMetricsEndpoints = [_endpoint]}
  }
}

# Alerts every workload wants, over kube-state-metrics (shipped by
# kube-prometheus-stack) and the scrape itself. A workload KEDA scaled to zero
# has no `up` series at all, so AppTargetDown stays silent then.
_defaultRules = lambda w: Workload -> [AlertRule] {
  _ns = w.namespace
  ([AlertRule {
    alert = "AppTargetDown"
    expr = 'sum(up{namespace="${_ns}", job="${_scrapeJob(w)}"}) == 0'
    severity = "critical"
    summary = "${w.name}: no scrape target is up"
    description = "Prometheus has not scraped a healthy ${w.name} pod in ${_ns} for 5 minutes."
  }] if w.monitoring.scrape else []) + [
    AlertRule {
      alert = "AppRestarting"
      expr = 'increase(kube_pod_container_status_restarts_total{namespace="${_ns}", container="${w.name}"}[15m]) > 3'
      $for = "1m"
      summary = "${w.name}: {{ $labels.pod }} is restarting"
      description = "{{ $labels.pod }} restarted more than 3 times in 15 minutes."
    }
    AlertRule {
      alert = "AppReplicasUnavailable"
      expr = 'kube_deployment_status_replicas_unavailable{namespace="${_ns}", deployment="${w.name}"} > 0'
      $for = "10m"
      summary = "${w.name}: replicas unavailable"
      description = "{{ $value }} replica(s) of ${w.name} in ${_ns} have been unavailable for 10 minutes."
    }
  ]
}

_rule = lambda w: Workload, r: AlertRule -> {str:} {
  _ann = ({summary = r.summary} if r.summary else {}) | ({description = r.description} if r.description else {}) | ({runbook_url = r.runbookUrl} if r.runbookUrl else {})
  {
    alert = r.alert
    expr = r.expr
    "for" = r.$for
    labels = {severity = r.severity, app = w.name} | r.labels
  } | ({annotations = _ann} if _ann else {})
}

_prometheusRule = lambda w: Workload -> promop.PrometheusRule {
  _m = w.monitoring
  promop.PrometheusRule {
    metadata = {name = w.name, namespace = w.namespace, labels = _labels(w) | _m.labels}
    spec = {
      groups = [{name = "${w.namespace}.${w.name}", rules = [_rule(w, r) for r in (_defaultRules(w) if _m.defaultRules else []) + _m.rules]}]
    }
  }
}

# The panels every generated dashboard starts with: cAdvisor + kube-state-metrics
# series for this workload's container, and its scrape targets.
_standardPanels = lambda w: Workload -> [Panel] {
  _sel = 'namespace="${w.namespace}", container="${w.name}"'
  [
    Panel {title = "Available replicas", expr = 'kube_deployment_status_replicas_available{namespace="${w.namespace}", deployment="${w.name}"}', legend = "available"}
    Panel {title = "CPU (cores)", expr = 'sum by (pod) (rate(container_cpu_usage_seconds_total{${_sel}}[$__rate_interval]))', legend = "{{pod}}"}
    Panel {title = "Memory (working set)", expr = 'sum by (pod) (container_memory_working_set_bytes{${_sel}})', legend = "{{pod}}", unit = "bytes"}
    Panel {title = "Container restarts", expr = 'sum by (pod) (increase(kube_pod_container_status_restarts_total{${_sel}}[$__rate_interval]))', legend = "{{pod}}"}
  ] + ([Panel {title = "Scrape targets up", expr = 'sum(up{namespace="${w.namespace}", job="${_scrapeJob(w)}"})', $type = "stat"}] if w.monitoring.scrape else [])
}

_panel = lambda i: int, p: Panel -> {str:} {
  _ds = {$type = "prometheus", uid = "\${datasource}"}
  {
    id = i + 1
    title = p.title
    $type = p.$type
    datasource = _ds
    # two panels per row, 8 grid units high
    gridPos = {h = 8, w = 12, x = (i % 2) * 12, y = (i // 2) * 8}
    fieldConfig = {defaults = {unit = p.unit}, overrides = []}
    targets = [{refId = "A", datasource = _ds, expr = p.expr} | ({legendFormat = p.legend} if p.legend else {})]
  }
}

# Grafana dashboard JSON. The uid is derived from namespace/workload/name, so
# a re-render updates the same dashboard instead of adding a copy.
_dashboardJson = lambda w: Workload, d: Dashboard -> str {
  d.json if d.json else json.encode({
    uid = crypto.md5("${w.namespace}/${w.name}/${d.name}")
    title = d.title or "${w.name} / ${d.name}"
    tags = [w.partOf, w.name]
    editable = True
    schemaVersion = 39
    refresh = "30s"
    time = {"from" = "now-6h", to = "now"}
    templating = {list = [{name = "datasource", label = "Data source", $type = "datasource", query = "prometheus"}]}
    panels = [_panel(i, p) for i, p in (_standardPanels(w) if d.standard else []) + d.panels]
  }, indent=2)
}

_dashboard = lambda w: Workload, d: Dashboard -> corev1.ConfigMap {
  _m = w.monitoring
  corev1.ConfigMap {
    metadata = {
      name = "${w.name}-dashboard-${d.name}"
      namespace = _m.dashboardNamespace or w.namespace
      labels = _labels(w) | _m.dashboardLabels
    } | ({
      annotations = {"${_m.folderAnnotation}" = d.folder}
    } if d.folder else {})
    data = {"${w.name}-${d.name}.json" = _dashboardJson(w, d)}
  }
}

_monitoring = lambda w: Workload -> [any] {
  _m = w.monitoring
  ([_monitor(w)] if _m.scrape else []) + ([_prometheusRule(w)] if _m.defaultRules or _m.rules else []) + [_dashboard(w, d) for d in _m.dashboards]
}

# ── Chaos Mesh renderers ─────────────────────────────────────────────────────
# The spec builders take the pod selector explicitly so the `manager` package
# can reuse them for cluster-scope experiments and Workflows. Inside `app` the
# selector is always this workload's pods and nothing else; Chaos Mesh label
# selectors are cluster-wide unless `namespaces` pins them, hence the Workload
# check that `chaos` needs a namespace.
_faultSelector = lambda w: Workload -> {str:} {
  {namespaces = [w.namespace], labelSelectors = {app = w.name}}
}

_faultMeta = lambda w: Workload, f: Fault -> {str:} {
  {name = "${w.name}-${f.name}", namespace = w.namespace, labels = _labels(w)}
}

_podChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    action = f.$type
    mode = f.mode
    selector = selector
    # pod-kill is instantaneous: a duration would only make Chaos Mesh
    # hold the experiment open (and re-kill under a Schedule)
  } | ({duration = f.duration} if f.$type != "pod-kill" else {}) | ({value = f.value} if f.value else {}) | ({containerNames = f.containerNames} if f.containerNames else {})
}

_networkChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    action = f.$type
    mode = f.mode
    selector = selector
    direction = f.direction
    duration = f.duration
  } | ({value = f.value} if f.value else {}) | ({externalTargets = f.externalTargets} if f.externalTargets else {}) | ({
    delay = {latency = f.latency} | ({jitter = f.jitter} if f.jitter else {}) | ({correlation = f.correlation} if f.correlation else {})
  } if f.$type == "delay" else {
    loss = {loss = f.loss} | ({correlation = f.correlation} if f.correlation else {})
  } if f.$type == "loss" else {
    corrupt = {corrupt = f.corrupt} | ({correlation = f.correlation} if f.correlation else {})
  } if f.$type == "corrupt" else {
    duplicate = {duplicate = f.duplicate} | ({correlation = f.correlation} if f.correlation else {})
  } if f.$type == "duplicate" else {
    bandwidth = {rate = f.rate, buffer = f.buffer, limit = f.limit}
  } if f.$type == "bandwidth" else {})
}

_stressChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    mode = f.mode
    selector = selector
    duration = f.duration
    stressors = {
      cpu = {workers = f.workers, load = f.load}
    } if f.$type == "cpu" else {
      memory = {workers = f.workers} | ({size = f.size} if f.size else {})
    }
  } | ({value = f.value} if f.value else {}) | ({containerNames = f.containerNames} if f.containerNames else {})
}

_httpAction = lambda f: Fault -> {str:} {
  {abort = True} if f.$type == "http-abort" else {delay = f.latency}
}

_ioAction = lambda f: Fault -> {str:} {
  {delay = f.latency} if f.$type == "io-latency" else {errno = f.errno}
}

_httpChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    mode = f.mode
    selector = selector
    target = f.httpTarget
    duration = f.duration
  } | _httpAction(f) | ({value = f.value} if f.value else {}) | ({port = f.port} if f.port else {}) | ({path = f.path} if f.path else {}) | ({method = f.method} if f.method else {})
}

_ioChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    action = "latency" if f.$type == "io-latency" else "fault"
    mode = f.mode
    selector = selector
    volumePath = f.volumePath
    percent = f.percent
    duration = f.duration
  } | _ioAction(f) | ({value = f.value} if f.value else {}) | ({path = f.path} if f.path else {}) | ({methods = f.methods} if f.methods else {}) | ({containerNames = f.containerNames} if f.containerNames else {})
}

_dnsChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    action = "error" if f.$type == "dns-error" else "random"
    mode = f.mode
    selector = selector
    duration = f.duration
  } | ({value = f.value} if f.value else {}) | ({patterns = f.patterns} if f.patterns else {}) | ({containerNames = f.containerNames} if f.containerNames else {})
}

_timeChaosSpec = lambda f: Fault, selector: {str:} -> {str:} {
  {
    mode = f.mode
    selector = selector
    timeOffset = f.timeOffset
    duration = f.duration
  } | ({value = f.value} if f.value else {}) | ({clockIds = f.clockIds} if f.clockIds else {}) | ({containerNames = f.containerNames} if f.containerNames else {})
}

_faultKinds = {
  "pod-kill" = "PodChaos"
  "pod-failure" = "PodChaos"
  "container-kill" = "PodChaos"
  "delay" = "NetworkChaos"
  "loss" = "NetworkChaos"
  "partition" = "NetworkChaos"
  "bandwidth" = "NetworkChaos"
  "corrupt" = "NetworkChaos"
  "duplicate" = "NetworkChaos"
  "cpu" = "StressChaos"
  "memory" = "StressChaos"
  "http-abort" = "HTTPChaos"
  "http-delay" = "HTTPChaos"
  "io-latency" = "IOChaos"
  "io-fault" = "IOChaos"
  "dns-error" = "DNSChaos"
  "dns-random" = "DNSChaos"
  "time-skew" = "TimeChaos"
}

# The field a Schedule / Workflow template embeds each kind's spec under.
_embedKeys = {
  PodChaos = "podChaos"
  NetworkChaos = "networkChaos"
  StressChaos = "stressChaos"
  HTTPChaos = "httpChaos"
  IOChaos = "ioChaos"
  DNSChaos = "dnsChaos"
  TimeChaos = "timeChaos"
}

faultKind = lambda f: Fault -> str {
  """Chaos Mesh kind a fault renders to: PodChaos, NetworkChaos, StressChaos, HTTPChaos, IOChaos, DNSChaos or TimeChaos."""
  _faultKinds[f.$type]
}

faultEmbedKey = lambda f: Fault -> str {
  """The field a Chaos Mesh Schedule or Workflow template carries this fault's spec under (podChaos, networkChaos, …)."""
  _embedKeys[faultKind(f)]
}

faultSpec = lambda f: Fault, selector: {str:} -> {str:} {
  """The <kind>Spec for a fault against `selector` (a Chaos Mesh pod selector: namespaces, labelSelectors, …)."""
  _kind = faultKind(f)
  _podChaosSpec(f, selector) if _kind == "PodChaos" else _networkChaosSpec(f, selector) if _kind == "NetworkChaos" else _stressChaosSpec(f, selector) if _kind == "StressChaos" else _httpChaosSpec(f, selector) if _kind == "HTTPChaos" else _ioChaosSpec(f, selector) if _kind == "IOChaos" else _dnsChaosSpec(f, selector) if _kind == "DNSChaos" else _timeChaosSpec(f, selector)
}

experiment = lambda f: Fault, selector: {str:}, metadata: {str:} -> any {
  """
    A typed Chaos Mesh object for a fault: the one-shot experiment of its kind
    (see `faultKind`), or a Schedule embedding it when `f.schedule` is set.
    `metadata` is used as given (name, namespace, labels, annotations).
    """
  _kind = faultKind(f)
  _spec = faultSpec(f, selector)
  cmschedule.Schedule {
    metadata = metadata
    spec = {
      schedule = f.schedule
      $type = _kind
      concurrencyPolicy = f.concurrencyPolicy
      historyLimit = f.historyLimit
    } | {"${faultEmbedKey(f)}" = _spec}
  } if f.schedule else cmpod.PodChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "PodChaos" else cmnet.NetworkChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "NetworkChaos" else cmstress.StressChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "StressChaos" else cmhttp.HTTPChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "HTTPChaos" else cmio.IOChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "IOChaos" else cmdns.DNSChaos {
    metadata = metadata
    spec = _spec
  } if _kind == "DNSChaos" else cmtime.TimeChaos {
    metadata = metadata
    spec = _spec
  }
}

# ── Litmus renderers ─────────────────────────────────────────────────────────
# Where Chaos Mesh needs one CR, a Litmus fault is three things: the experiment
# definition (a namespaced ChaosExperiment — go-runner image, command, default
# env — copied from chaos-charts into litmus_hub.k), the run (a ChaosEngine
# naming that definition, the target and the env overrides) and the identity
# the run executes as. The operator starts a runner pod, the runner an
# experiment Job, and the network / stress / http / dns experiments a
# privileged helper pod (hostPID, the containerd socket) on the target's node,
# all in the ChaosEngine's namespace. That namespace is always `litmus`, the
# one place Pod Security and the Kyverno exception admit those helpers; the
# target namespace only gets a Role + RoleBinding letting the runner's
# ServiceAccount find its pods (and delete them for pod-delete, fence them
# with a NetworkPolicy for pod-network-partition).
#
# Everything in `litmus` is shared by all targets, so callers pass a name that
# is unique there (app: "<namespace>-<workload>-<fault>"). The ChaosExperiment
# is "<experiment>-<hash of that name>": one definition per engine, because
# two owners of one object fight over it under Crossplane, yet ChaosCenter and
# the Job / helper pod names Litmus derives from it still say what it is.
litmusNamespace = "litmus"

_litmusExperiments = {
  "pod-kill" = "pod-delete"
  "container-kill" = "container-kill"
  "delay" = "pod-network-latency"
  "loss" = "pod-network-loss"
  "corrupt" = "pod-network-corruption"
  "duplicate" = "pod-network-duplication"
  "bandwidth" = "pod-network-rate-limit"
  "partition" = "pod-network-partition"
  "cpu" = "pod-cpu-hog"
  "memory" = "pod-memory-hog"
  "http-delay" = "pod-http-latency"
  "http-abort" = "pod-http-reset-peer"
  "dns-error" = "pod-dns-error"
}

schema LitmusTarget:
  """
    The pods a ChaosEngine selects (spec.appinfo): one namespace, one label,
    and the kind of their owner — Litmus keeps only pods whose owner is of
    that kind.
    """
  namespace: str
  # exactly one key: Litmus ORs comma-separated labels, and
  # pod-network-partition's NetworkPolicy selects by a single label
  labels: {str:str}
  kind: "deployment" | "statefulset" | "daemonset" | "rollout" = "deployment"

  check:
    len(labels) == 1, "Litmus selects by exactly one label (it ORs several, and pod-network-partition fences by one): ${labels}"

_litmusSeconds = lambda d: str -> int {
  sum([int(p[:-1]) * {h = 3600, m = 60, s = 1}[p[-1]] for p in regex.findall(d, r"[0-9]+[hms]")])
}

_litmusMillis = lambda d: str -> int {
  int(d[:-2]) if d.endswith("ms") else int(d[:-1]) * 1000
}

_litmusMegabytes = lambda s: str -> int {
  int(s[:-2]) * 1024 if s.endswith("GB") else int(s[:-2])
}

# externalTargets split the way Litmus takes them: IPs / CIDRs as they are,
# names resolved by the experiment pod.
_litmusDestinations = lambda f: Fault -> {str:str} {
  _all = f.externalTargets or []
  _ips = [t for t in _all if regex.match(t, r"^[0-9.]+(/[0-9]+)?$") or ":" in t]
  _hosts = [t for t in _all if t not in _ips]
  ({DESTINATION_IPS = ",".join(_ips)} if _ips else {}) | ({DESTINATION_HOSTS = ",".join(_hosts)} if _hosts else {})
}

_litmusTypeEnv = lambda f: Fault -> {str:str} {
  _t = f.$type
  _corr = {CORRELATION = f.correlation} if f.correlation else {}
  _patterns = f.patterns or []
  # pod-delete / container-kill loop "kill, wait CHAOS_INTERVAL" until
  # TOTAL_CHAOS_DURATION; 1s of each is exactly one kill, as in Chaos Mesh.
  ({TOTAL_CHAOS_DURATION = "1", CHAOS_INTERVAL = "1", FORCE = "true"}) if _t == "pod-kill" else ({TOTAL_CHAOS_DURATION = "1", CHAOS_INTERVAL = "1"}) if _t == "container-kill" else ({
    NETWORK_LATENCY = str(_litmusMillis(f.latency))
    JITTER = str(_litmusMillis(f.jitter)) if f.jitter else "0"
  } | _corr | _litmusDestinations(f)) if _t == "delay" else ({NETWORK_PACKET_LOSS_PERCENTAGE = f.loss} | _corr | _litmusDestinations(f)) if _t == "loss" else ({NETWORK_PACKET_CORRUPTION_PERCENTAGE = f.corrupt} | _corr | _litmusDestinations(f)) if _t == "corrupt" else ({NETWORK_PACKET_DUPLICATION_PERCENTAGE = f.duplicate} | _corr | _litmusDestinations(f)) if _t == "duplicate" else ({
    # the same tc tbf arguments Chaos Mesh passes: rate units, bytes
    NETWORK_BANDWIDTH = f.rate
    BURST = str(f.buffer)
    LIMIT = str(f.limit)
  } | _litmusDestinations(f)) if _t == "bandwidth" else ({
    POLICY_TYPES = {to = "egress", $from = "ingress", both = "all"}[f.direction]
  } | _litmusDestinations(f)) if _t == "partition" else ({CPU_CORES = str(f.workers), CPU_LOAD = str(f.load)}) if _t == "cpu" else ({
    MEMORY_CONSUMPTION = str(_litmusMegabytes(f.size))
    NUMBER_OF_WORKERS = str(f.workers)
  }) if _t == "memory" else ({
    LATENCY = str(_litmusMillis(f.latency))
    TARGET_SERVICE_PORT = str(f.port)
  }) if _t == "http-delay" else ({
    # reset_peer with no timeout: the connection is reset as it opens
    RESET_TIMEOUT = "0"
    TARGET_SERVICE_PORT = str(f.port)
  }) if _t == "http-abort" else ({
    MATCH_SCHEME = "substring" if any p in _patterns {"*" in p} else "exact"
  } | ({TARGET_HOSTNAMES = json.encode([p.strip("*") for p in _patterns])} if _patterns else {}))
}

litmusEnv = lambda f: Fault -> {str:str} {
  """The ChaosEngine env overrides for a fault: duration, pod share, target container, then the experiment's own knobs."""
  # PODS_AFFECTED_PERC unset (0) is "at least one pod" to Litmus = mode one.
  {TOTAL_CHAOS_DURATION = str(_litmusSeconds(f.duration))} | ({PODS_AFFECTED_PERC = "100"} if f.mode == "all" else {PODS_AFFECTED_PERC = f.value} if f.mode == "fixed-percent" else {}) | ({TARGET_CONTAINER = ",".join(f.containerNames)} if f.containerNames else {}) | _litmusTypeEnv(f)
}

litmusExperiment = lambda f: Fault -> str {
  """The chaos-charts experiment a fault runs as under Litmus (pod-delete, pod-network-latency, …)."""
  _litmusExperiments[f.$type]
}

# What the runner, experiment Job and helper pods do in `litmus`: chaos-charts'
# own permission list for these experiments, minus the target-side reads.
_litmusRunnerRules = [
  {apiGroups = [""], resources = ["pods"], verbs = ["create", "delete", "get", "list", "patch", "update", "deletecollection"]}
  {apiGroups = [""], resources = ["events"], verbs = ["create", "get", "list", "patch", "update"]}
  {apiGroups = [""], resources = ["configmaps"], verbs = ["get", "list"]}
  {apiGroups = [""], resources = ["pods/log"], verbs = ["get", "list", "watch"]}
  {apiGroups = [""], resources = ["pods/exec"], verbs = ["get", "list", "create"]}
  {apiGroups = ["batch"], resources = ["jobs"], verbs = ["create", "list", "get", "delete", "deletecollection"]}
  {apiGroups = ["litmuschaos.io"], resources = ["chaosengines", "chaosexperiments", "chaosresults"], verbs = ["create", "list", "get", "patch", "update", "delete"]}
]

# What the experiment does in the target namespace: list the pods behind the
# label, walk their owners up to `kind`, and only for pod-delete / partition
# touch anything.
_litmusTargetRules = lambda f: Fault, t: LitmusTarget -> [{str:}] {
  [
    {apiGroups = [""], resources = ["pods"], verbs = ["get", "list"] + (["delete", "deletecollection"] if f.$type == "pod-kill" else [])}
    {apiGroups = [""], resources = ["replicationcontrollers"], verbs = ["get", "list"]}
    {apiGroups = ["apps"], resources = ["deployments", "statefulsets", "replicasets", "daemonsets"], verbs = ["get", "list"]}
  ] + ([{apiGroups = ["argoproj.io"], resources = ["rollouts"], verbs = ["get", "list"]}] if t.kind == "rollout" else []) + ([{apiGroups = ["networking.k8s.io"], resources = ["networkpolicies"], verbs = ["create", "delete", "get", "list"]}] if f.$type == "partition" else [])
}

# Flat parameter list: function-kcl's embedded compiler cannot parse the
# braced form (see _componentEntity), and platform-api's XChaosExperiment
# calls this inside that function.
litmusObjects = lambda f: Fault, target: LitmusTarget, name: str, labels: {str:str}, active: bool = True -> [any] {
  """
    Everything one Litmus fault needs, in apply order: the runner
    ServiceAccount + Role + RoleBinding in `litmus`, the Role + RoleBinding in
    the target namespace, the ChaosExperiment definition and the ChaosEngine
    — all named `name` (a DNS label unique in `litmus`) except the definition.
    `active: False` renders the engine stopped (engineState: stop); a
    stopped or finished engine runs again only under a new `name`.
    """
  assert f.provider == "litmus", "fault ${f.name}: litmusObjects renders provider litmus faults, this one is ${f.provider}"
  assert regex.match(name, r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$"), "Litmus engine name '${name}' must be a DNS label of at most 63 characters: the operator labels the runner pod app=<name>"
  assert f.$type not in ["http-delay", "http-abort"] or f.port, "fault ${f.name}: an HTTP fault needs the `port` the target pods serve on (TARGET_SERVICE_PORT)"
  _exp = _litmusExperiments[f.$type]
  _hub = hub.experiments[_exp]
  _def = "${_exp}-${crypto.sha256(name)[:8]}"
  _meta = {name = name, namespace = litmusNamespace, labels = labels}
  _sa = {kind = "ServiceAccount", name = name, namespace = litmusNamespace}
  [
    corev1.ServiceAccount {metadata = _meta}
    rbacv1.Role {metadata = _meta, rules = _litmusRunnerRules}
    rbacv1.RoleBinding {
      metadata = _meta
      roleRef = {apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = name}
      subjects = [_sa]
    }
    rbacv1.Role {metadata = _meta | {namespace = target.namespace}, rules = _litmusTargetRules(f, target)}
    rbacv1.RoleBinding {
      metadata = _meta | {namespace = target.namespace}
      roleRef = {apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = name}
      subjects = [_sa]
    }
    litmus.ChaosExperiment {
      metadata = {
        name = _def
        namespace = litmusNamespace
        labels = labels | {name = _exp, "app.kubernetes.io/component" = "chaosexperiment", "app.kubernetes.io/version" = hub.version}
      }
      description = {message = _hub.description}
      spec.definition = _hub.definition
    }
    litmus.ChaosEngine {
      metadata = _meta
      # engineState is left to the operator unless stopping: it flips the
      # field to `stop` when the run completes, and an applier that kept
      # re-asserting `active` (Crossplane, Flux) would restart the run on
      # every reconcile.
      spec = ({engineState = "stop"} if not active else {}) | {
        chaosServiceAccount = name
        # The verdict lives on the ChaosEngine / ChaosResult; retaining the
        # runner and experiment pods would leave a pair behind per run.
        jobCleanUpPolicy = "delete"
        appinfo = {appns = target.namespace, applabel = ",".join(["${k}=${v}" for k, v in target.labels]), appkind = target.kind}
        experiments = [{name = _def, spec.components.env = [{name = k, value = v} for k, v in litmusEnv(f)]}]
      }
    }
  ]
}

_fault = lambda w: Workload, f: Fault -> [any] {
  # An HTTP fault against a workload defaults to the port it serves on.
  _f = f | {port = w.port} if f.$type in ["http-abort", "http-delay"] and not f.port else f
  [experiment(_f, _faultSelector(w), _faultMeta(w, f))] if f.provider == "chaos-mesh" else litmusObjects(_f, LitmusTarget {namespace = w.namespace, labels = {app = w.name}}, "${w.namespace}-${w.name}-${f.name}", _labels(w))
}

# ── Backstage catalog ────────────────────────────────────────────────────────
# Entities are built from the same values file as the manifests, so the portal
# cannot describe a different app than the cluster runs. They are plain dicts,
# not typed k8s objects: `backstage.io/v1alpha1` is not a Kubernetes API, and
# nothing here may ever reach `kubectl apply`.

# The three atoms `manager` reuses for the cluster-scope entities, public for
# the same reason the fault renderers are: a game day in the portal must be
# built the same way a component is.
faultSummary = lambda faults: [Fault] -> str {
  """What the portal can show without reaching the cluster: declared faults as "<name>=<type>" pairs."""
  ",".join(["${f.name}=${f.$type}" for f in faults])
}

entity = lambda kind: str, metadata: {str:}, spec: {str:} -> {str:} {
  """One Backstage catalog entity: Component, API, Resource, System, …"""
  {apiVersion = "backstage.io/v1alpha1", kind = kind, metadata = metadata, spec = spec}
}

link = lambda l: Link -> {str:} {
  """A `metadata.links` entry with its unset optionals dropped — a null there fails the catalog import."""
  {k: v for k, v in l if v != Undefined}
}

_apiEntity = lambda c: Catalog, a: Api -> {str:} {
  entity("API", {
    name = a.name
  } | ({description = a.description} if a.description else {}) | ({tags = c.tags} if c.tags else {}), {
    $type = a.$type
    lifecycle = a.lifecycle or c.lifecycle
    owner = a.owner or c.owner
    # `$text` is the catalog's own placeholder: it fetches the URL at import
    # time. An inline definition is passed through as written.
    definition = a.definition if a.definition else {"$text" = a.definitionUrl}
  } | ({system = c.system} if c.system else {}))
}

# Ownership, lifecycle and relations come from `catalog:`; the id, namespace,
# archetype and fault summary are derived, so they cannot drift from the
# manifests rendered next to them.
# The parameter list is flat rather than the braced form KCL also accepts:
# function-kcl's embedded compiler (v0.12.2, the version every Composition in
# this repo pins) cannot parse braced parameters, and platform/application
# imports this module inside that function.
_componentEntity = lambda {
  c: Catalog,
  name: str,
  namespace: str,
  defaultType: str,
  system: str,
  faults: [Fault],
} -> {str:} {
  _ann = {
    "backstage.io/kubernetes-id" = name
  } | ({"backstage.io/kubernetes-namespace" = namespace} if namespace else {}) | ({"backstage.io/techdocs-ref" = c.techdocs} if c.techdocs else {}) | ({"backstage.io/source-location" = c.source} if c.source else {}) | ({
    "platform.example.org/chaos-faults" = faultSummary(faults)
  } if faults else {}) | c.annotations
  _apis = c.providesApis + [a.name for a in c.apis if a.name not in c.providesApis]
  entity("Component", {
    name = c.name or name
    annotations = _ann
  } | ({title = c.title} if c.title else {}) | ({description = c.description} if c.description else {}) | ({tags = c.tags} if c.tags else {}) | ({labels = c.labels} if c.labels else {}) | ({links = [link(l) for l in c.links]} if c.links else {}), {
    $type = c.$type or defaultType
    lifecycle = c.lifecycle
    owner = c.owner
  } | ({system = system} if system else {}) | ({subcomponentOf = c.subcomponentOf} if c.subcomponentOf else {}) | ({dependsOn = c.dependsOn} if c.dependsOn else {}) | ({providesApis = _apis} if _apis else {}) | ({consumesApis = c.consumesApis} if c.consumesApis else {}))
}

# ── Task (Job / CronJob) renderers ───────────────────────────────────────────
_taskLabels = lambda t: Task -> {str:str} {
  {
    "app" = t.name
    "app.kubernetes.io/name" = t.name
    "app.kubernetes.io/component" = t.component
    "app.kubernetes.io/part-of" = t.partOf
    # Same Backstage id label as a Workload's, so the plugin resolves a
    # Job / CronJob from its Component entity too.
    "backstage.io/kubernetes-id" = t.name
  } | ({"app.kubernetes.io/version" = t.version} if t.version else {})
}

_taskPodSecurity = lambda t: Task -> {str:} {
  {
    runAsNonRoot = True
    runAsUser = t.runAsUser
    seccompProfile = {$type = "RuntimeDefault"}
  } | ({runAsGroup = t.runAsGroup, fsGroup = t.runAsGroup} if t.runAsGroup else {fsGroup = t.runAsUser})
}

_taskContainer = lambda t: Task -> {str:} {
  {
    name = t.name
    image = t.image
    imagePullPolicy = t.imagePullPolicy
  } | ({command = t.command} if t.command else {}) | ({args = t.args} if t.args else {}) | ({envFrom = [_envFrom(f) for f in t.envFrom]} if t.envFrom else {}) | ({env = [_envVar(e) for e in t.env]} if t.env else {}) | {
    resources = t.resources
    securityContext = {
      allowPrivilegeEscalation = False
      readOnlyRootFilesystem = t.readOnlyRootFilesystem
      runAsNonRoot = True
      runAsUser = t.runAsUser
      capabilities = {drop = ["ALL"]}
    }
    volumeMounts = t.volumeMounts
  }
}

_jobPodSpec = lambda t: Task -> {str:} {
  {
    securityContext = _taskPodSecurity(t)
    containers = [_taskContainer(t)]
    volumes = t.volumes
    restartPolicy = t.restartPolicy
  } | (_saPodSpec(t.name, t.serviceAccount) if t.serviceAccount else {}) | ({nodeSelector = t.nodeSelector} if t.nodeSelector else {}) | ({tolerations = t.tolerations} if t.tolerations else {})
}

# Shared JobSpec, used directly for a Job, nested under a CronJob's
# jobTemplate, and as a ScaledJob's jobTargetRef.
_jobSpec = lambda t: Task -> {str:} {
  {
    template = {
      metadata = {labels = _taskLabels(t) | (_saPodLabels(t.serviceAccount) if t.serviceAccount else {}) | t.podLabels}
      spec = _jobPodSpec(t)
    }
    backoffLimit = t.backoffLimit
  } | ({completions = t.completions} if t.completions else {}) | ({parallelism = t.parallelism} if t.parallelism else {}) | ({activeDeadlineSeconds = t.activeDeadlineSeconds} if t.activeDeadlineSeconds else {}) | ({ttlSecondsAfterFinished = t.ttlSecondsAfterFinished} if t.ttlSecondsAfterFinished != Undefined else {})
}

_job = lambda t: Task -> batchv1.Job {
  batchv1.Job {
    metadata = {name = t.name, labels = _taskLabels(t)} | ({namespace = t.namespace} if t.namespace else {})
    spec = _jobSpec(t)
  }
}

_cronjob = lambda t: Task -> batchv1.CronJob {
  batchv1.CronJob {
    metadata = {name = t.name, labels = _taskLabels(t)} | ({namespace = t.namespace} if t.namespace else {})
    spec = {
      schedule = t.schedule
      concurrencyPolicy = t.concurrencyPolicy
      successfulJobsHistoryLimit = t.successfulJobsHistoryLimit
      failedJobsHistoryLimit = t.failedJobsHistoryLimit
      jobTemplate = {spec = _jobSpec(t)}
    } | ({suspend = t.suspend} if t.suspend != Undefined else {}) | ({startingDeadlineSeconds = t.startingDeadlineSeconds} if t.startingDeadlineSeconds else {})
  }
}

_scaledJob = lambda t: Task -> keda.ScaledJob {
  _s = t.scaler
  keda.ScaledJob {
    metadata = {name = t.name, labels = _taskLabels(t)} | ({namespace = t.namespace} if t.namespace else {})
    spec = {
      jobTargetRef = _jobSpec(t)
      minReplicaCount = _s.minReplicas
      maxReplicaCount = _s.maxReplicas
      successfulJobsHistoryLimit = t.successfulJobsHistoryLimit
      failedJobsHistoryLimit = t.failedJobsHistoryLimit
      scalingStrategy = {strategy = _s.strategy}
      triggers = [_trigger(t.name, tr) for tr in _s.triggers]
    } | ({pollingInterval = _s.pollingInterval} if _s.pollingInterval else {})
  }
}

# ── Public API ───────────────────────────────────────────────────────────────
mergeValues = lambda base: {str:}, overlay: {str:} -> {str:} {
  """
    Deep, right-wins merge of two plain values dicts (Helm/kustomize-overlay
    semantics): nested maps merge recursively, overlay scalars/lists replace base,
    overlay-only keys are added. Use to layer `values.<env>.yaml` over `values.yaml`.
    """
  {k: (mergeValues(base[k], overlay[k]) if (k in base and k in overlay and typeof(base[k]) == "dict" and typeof(overlay[k]) == "dict") else (overlay[k] if k in overlay else base[k])) for k in ([_kb for _kb in base] + [_ko for _ko in overlay if _ko not in base])}
}

render = lambda w: Workload -> [any] {
  """
    All manifests for a long-running workload, in apply order: ServiceAccount
    (+ Role/RoleBinding), Deployment, Service, HTTPRoute (+ https redirect),
    PodDisruptionBudget, KEDA
    TriggerAuthentications + ScaledObject, ServiceMonitor/PodMonitor +
    PrometheusRule + dashboard ConfigMaps, Chaos Mesh faults, extras.
    """
  _ns = w.namespace or ""
  _sa: [any] = _saObjects(w.name, _ns, _labels(w), w.serviceAccount) if w.serviceAccount else []
  _auths: [any] = [_triggerAuth(w.name, _ns, _labels(w), a) for a in w.scaler.authentications] if w.scaler else []
  _sa + [_deployment(w)] + ([_service(w)] if w.service else []) + _routes(w) + ([_pdb(w)] if w.disruptionBudget else []) + _auths + ([_scaler(w)] if w.scaler else []) + (_monitoring(w) if w.monitoring else []) + sum([_fault(w, f) for f in w.chaos], []) + w.extraManifests
}
#_sa + []
renderTask = lambda t: Task -> [any] {
  """
    Manifests for a batch workload: ServiceAccount (+ Role/RoleBinding), then a
    KEDA ScaledJob (after its TriggerAuthentications) when `scaler` is set, a
    CronJob when `schedule` is, else a Job; plus extras.
    """
  _ns = t.namespace or ""
  _sa: [any] = _saObjects(t.name, _ns, _taskLabels(t), t.serviceAccount) if t.serviceAccount else []
  _base: [any] = [_triggerAuth(t.name, _ns, _taskLabels(t), a) for a in t.scaler.authentications] + [_scaledJob(t)] if t.scaler else [_cronjob(t)] if t.schedule else [_job(t)]
  _sa + _base + t.extraManifests
}

renderRelease = lambda r: Release -> [any] {
  """
    All manifests for a Release: the workload (or task), plus an optional
    ConfigMap ("<name>-config") and ExternalSecret. The one-call entrypoint for
    a values.yaml-only consumer.
    """
  _core: [any] = render(r.workload) if r.workload else renderTask(r.task)
  _name = r.workload.name if r.workload else r.task.name
  _ns = (r.workload.namespace if r.workload else r.task.namespace) or ""
  _cm: [any] = [configMap("${_name}-config", r.config, _ns)] if r.config else []
  _es: [any] = [externalSecret(r.externalSecret.name or "${_name}-secrets", r.externalSecret.store, r.externalSecret.items, _ns, r.externalSecret.refreshInterval)] if r.externalSecret else []
  _core + _cm + _es
}

catalogEntities = lambda r: Release -> [any] {
  """
    The Backstage entities for a Release: one Component for the workload (or
    task), plus one API per `catalog.apis` entry. Empty when the values file has
    no `catalog:`.

    These are NOT Kubernetes objects, which is why they are a second render
    rather than extra items in `renderRelease`:

      kcl run packages/app -D values=<file> -D catalog=true -q > catalog-info.yaml

    Commit that where Backstage reads it (a catalog-info.yaml registered as a
    Location). `spec.type` defaults to the archetype — service for a workload,
    cronjob or job for a task — and `spec.system` to the workload's `partOf`.
    """
  _c = r.catalog
  _w = r.workload
  _name = (_w.name if _w else r.task.name) if _c else ""
  _ns = ((_w.namespace if _w else r.task.namespace) or "") if _c else ""
  _defaultType = ("service" if _w else ("cronjob" if r.task.schedule else "job")) if _c else ""
  _system = (_c.system or (_w.partOf if _w else r.task.partOf)) if _c else ""
  _faults: [Fault] = ((_w.chaos if _w else []) if _c else [])
  ([_componentEntity(_c, _name, _ns, _defaultType, _system, _faults)] + [_apiEntity(_c, a) for a in _c.apis]) if _c else []
}

configMap = lambda name: str, data: {str:str}, namespace: str = "" -> corev1.ConfigMap {
  """A typed ConfigMap (replaces kustomize configMapGenerator literals)."""
  corev1.ConfigMap {
    metadata = {name = name} | ({namespace = namespace} if namespace else {})
    data = data
  }
}

secret = lambda name: str, data: {str:str}, namespace: str = "" -> corev1.Secret {
  """A typed Opaque Secret from string literals (replaces kustomize secretGenerator)."""
  corev1.Secret {
    metadata = {name = name} | ({namespace = namespace} if namespace else {})
    $type = "Opaque"
    stringData = data
  }
}

# Flat parameter list, for the same reason as _componentEntity above.
externalSecret = lambda {
  name: str,
  store: str,
  items: [{str:str}],
  namespace: str = "",
  refreshInterval: str = "1h",
} -> esv1.ExternalSecret {
  """A typed external-secrets.io ExternalSecret. `items` = [{secretKey, key, property}]."""
  esv1.ExternalSecret {
    metadata = {name = name} | ({namespace = namespace} if namespace else {})
    spec = {
      refreshInterval = refreshInterval
      secretStoreRef = {name = store, kind = "ClusterSecretStore"}
      target = {name = name, creationPolicy = "Owner"}
      data = [{secretKey = it.secretKey, remoteRef = {key = it.key, property = it.property}} for it in items]
    }
  }
}
