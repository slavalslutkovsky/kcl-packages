"""
Application Kubernetes manifests — typed schemas + renderers (single source of truth).

Two archetypes, one package:
  • Workload → long-running apps (backend APIs, frontend/static apps, queue
    workers): Deployment (+ Service, + optional autoscaler: native HPA or a KEDA
    ScaledObject, which also does scale-to-zero and event-driven triggers).
    Backend and frontend are the SAME archetype with different field values
    (e.g. prometheus on/off, nginx volumes, uid/gid).
  • Task → run-to-completion CLI apps: a batch/v1 Job, or a CronJob when `schedule`
    is set. Reuses the same container atoms (env/envFrom/security) as Workload.

Core resources use the typed `k8s` package, ExternalSecret the typed
`external-secrets` package, and chaos experiments the `chaos-mesh` schema
package (packages/providers/chaos-mesh), so rendered output is checked against
the real Kubernetes / CRD APIs. The usual path is a Helm-style values.yaml that
is a `Release` (a `workload:` or `task:` + optional `config:`/`externalSecret:`),
rendered by the package's own main.k with no local main.k needed. In code:
`import app` and call `app.renderRelease(app.Release {**yaml.decode(...)})`, or
the lower-level `app.render(w)` / `app.renderTask(t)`. See examples/.

Chaos engineering: a Workload's `chaos:` is a list of `Fault`s, each rendered
as a Chaos Mesh experiment (PodChaos / NetworkChaos / StressChaos, or a
Schedule around one) pinned to that workload's own pods. Chaos Mesh over
Litmus because its experiments are self-contained CRs: no per-experiment
ChaosExperiment install from a hub, no chaos ServiceAccount per namespace.

Backstage: a `catalog:` block turns the same values file into catalog entities
(`-D catalog=true` renders a Component, plus an API per `catalog.apis`), and
every object rendered here carries the `backstage.io/kubernetes-id` label, so
the portal's Kubernetes plugin shows this release's Deployment, Service,
autoscaler AND its chaos experiments on one component page.
"""

import regex
import k8s.api.apps.v1 as appsv1
import k8s.api.core.v1 as corev1
import k8s.api.autoscaling.v2 as autoscalingv2
import k8s.api.batch.v1 as batchv1
import external_secrets.v1 as esv1
import keda.v1alpha1 as keda
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_chaos as cmpod
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_network_chaos as cmnet
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_stress_chaos as cmstress
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_schedule as cmschedule

# ── Component schemas ────────────────────────────────────────────────────────
schema Probe:
    """Health probe. `type='http'` → httpGet(path, port); `type='grpc'` → grpc(port)."""
    $type: "http" | "grpc" = "http"
    path?: str
    port: int | str
    periodSeconds: int = 10
    failureThreshold: int = 3
    timeoutSeconds: int = 3
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

schema Hpa:
    """HorizontalPodAutoscaler on cpu/memory utilization with sane scale behavior."""
    minReplicas: int = 1
    maxReplicas: int = 10
    cpu: int = 70
    memory: int = 80

schema Scaler:
    """
    KEDA ScaledObject (preferred over native HPA — a superset that also does
    scale-to-zero and event-driven triggers).

    Convenience: `cpu`/`memory` become KEDA cpu/memory utilization triggers.
    `triggers` is passthrough for any KEDA scaler (nats-jetstream, prometheus,
    cron, kafka, …): each item = {type, metadata:{..}, metricType?, name?}.
    Set `minReplicas = 0` for scale-to-zero. At least one of cpu/memory/triggers
    must be present.
    """
    minReplicas: int = 1
    maxReplicas: int = 10
    # → KEDA cpu trigger, Utilization %
    cpu?: int
    # → KEDA memory trigger, Utilization %
    memory?: int
    # passthrough KEDA triggers
    triggers: [{str:}] = []
    pollingInterval?: int
    cooldownPeriod?: int
    # → idleReplicaCount: replicas while every trigger is inactive; KEDA only
    # supports 0 here and it must be below minReplicas
    idleReplicas?: int
    # → advanced.horizontalPodAutoscalerConfig.behavior
    behavior?: {str:}

    check:
        cpu or memory or triggers, "Scaler needs at least one of cpu, memory, or triggers"
        idleReplicas == Undefined or idleReplicas < minReplicas, "idleReplicas (${idleReplicas}) must be below minReplicas (${minReplicas}); KEDA supports only 0"

schema Fault:
    """
    One Chaos Mesh fault injected into this workload's own pods. The selector is
    always `app=<name>` in the workload's namespace — a Fault never carries one,
    so its blast radius is exactly this workload. `type` picks the experiment:
      pod-kill | pod-failure | container-kill  → PodChaos
      delay | loss | partition                 → NetworkChaos
      cpu | memory                             → StressChaos
    Without `schedule` it is a one-shot experiment that runs for `duration` as
    soon as it is applied (pod-kill is instantaneous). With `schedule` (cron)
    it is wrapped in a Chaos Mesh Schedule and recurs.
    """
    # → "<workload>-<name>"
    name: str
    $type: "pod-kill" | "pod-failure" | "container-kill" | "delay" | "loss" | "partition" | "cpu" | "memory"
    # how many of the workload's pods are hit
    mode: "one" | "all" | "fixed" | "fixed-percent" | "random-max-percent" = "one"
    # fixed: pod count; fixed-percent / random-max-percent: 0-100
    value?: str
    duration: str = "30s"
    # delay
    latency: str = "100ms"
    jitter?: str
    correlation?: str
    # loss: percent of packets, 0-100
    loss: str = "10"

    # delay / loss / partition: which traffic. Without a target Chaos Mesh only
    # shapes outbound (`to`) traffic; a partition may also cut `from` / `both`.
    direction: "to" | "from" | "both" = "to"
    # delay / loss / partition: only traffic to these IPs or hostnames (default: all)
    externalTargets?: [str]
    # cpu / memory: stress-ng workers
    workers: int = 1
    # cpu: load per worker, percent of one core
    load: int = 100
    # memory: per-worker allocation, e.g. "256MB" or "50%"
    size?: str
    # container-kill / cpu / memory: default the workload's own container
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

schema Workload:
    """A deployable long-running application: Deployment (+ Service, + optional HPA or KEDA ScaledObject, + Chaos Mesh faults)."""
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
    # native HPA (legacy; prefer `scaler`)
    hpa?: Hpa
    # KEDA ScaledObject (preferred)
    scaler?: Scaler
    # Chaos Mesh experiments against this workload's pods (needs `namespace`)
    chaos: [Fault] = []
    podAnnotations: {str:str} = {}
    extraManifests: [{str:}] = []

    check:
        not (hpa and scaler), "use either `hpa` (native) or `scaler` (KEDA), not both"
        not chaos or namespace, "chaos faults need an explicit `namespace`: the experiment selector is pinned to it"
        len(chaos) == len({f.name: 1 for f in chaos}), "chaos fault names must be unique"

schema Task:
    """A run-to-completion CLI workload: Job, or CronJob when `schedule` is set."""
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
    serviceAccountName?: str
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
    successfulJobsHistoryLimit: int = 3
    failedJobsHistoryLimit: int = 1
    extraManifests: [{str:}] = []

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
    config?: {str:str}
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

_podAnnotations = lambda w: Workload -> {str:str} {
    (({
        "prometheus.io/scrape" = "true"
        "prometheus.io/port" = "${w.port}"
        "prometheus.io/path" = w.metricsPath
    }) if w.prometheus else {}) | w.podAnnotations
}

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

_deployment = lambda w: Workload -> appsv1.Deployment {
    _ann = _podAnnotations(w)
    appsv1.Deployment {
        metadata = {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
        # Omit spec.replicas when an autoscaler (HPA or KEDA) owns it — otherwise
        # GitOps (Flux/ArgoCD) server-side apply and Flagger fight the autoscaler
        # over the replica count. The autoscaler's min is the floor.
        spec = ({replicas = w.replicas} if not (w.hpa or w.scaler) else {}) | {
            selector = {
                matchLabels = {app = w.name}
            }
            template = {
                metadata = {labels = _labels(w)} | ({annotations = _ann} if _ann else {})
                spec = {
                    securityContext = _podSecurity(w)
                    containers = [_container(w)]
                    volumes = w.volumes
                    terminationGracePeriodSeconds = w.terminationGracePeriodSeconds
                    restartPolicy = "Always"
                }
            }
        }
    }
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

_hpa = lambda w: Workload -> autoscalingv2.HorizontalPodAutoscaler {
    autoscalingv2.HorizontalPodAutoscaler {
        metadata = {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
        spec = {
            scaleTargetRef = {apiVersion = "apps/v1", kind = "Deployment", name = w.name}
            minReplicas = w.hpa.minReplicas
            maxReplicas = w.hpa.maxReplicas
            metrics = [
                {$type = "Resource", resource = {name = "cpu", target = {$type = "Utilization", averageUtilization = w.hpa.cpu}}}
                {$type = "Resource", resource = {name = "memory", target = {$type = "Utilization", averageUtilization = w.hpa.memory}}}
            ]
            behavior = {
                scaleDown = {stabilizationWindowSeconds = 300, policies = [{$type = "Percent", value = 10, periodSeconds = 60}]}
                scaleUp = {
                    stabilizationWindowSeconds = 0
                    policies = [
                        {$type = "Percent", value = 100, periodSeconds = 15}
                        {$type = "Pods", value = 4, periodSeconds = 15}
                    ]
                    selectPolicy = "Max"
                }
            }
        }
    }
}

_scaler = lambda w: Workload -> keda.ScaledObject {
    _s = w.scaler
    # cpu/memory convenience → KEDA built-in scaler triggers
    _cpu: [{str:}] = [{$type = "cpu", metricType = "Utilization", metadata = {value = "${_s.cpu}"}}] if _s.cpu else []
    _mem: [{str:}] = [{$type = "memory", metricType = "Utilization", metadata = {value = "${_s.memory}"}}] if _s.memory else []
    _triggers = _cpu + _mem + _s.triggers
    keda.ScaledObject {
        metadata = {name = w.name, labels = _labels(w)} | ({namespace = w.namespace} if w.namespace else {})
        spec = {
            scaleTargetRef = {name = w.name}
            minReplicaCount = _s.minReplicas
            maxReplicaCount = _s.maxReplicas
            triggers = _triggers
        } | ({pollingInterval = _s.pollingInterval} if _s.pollingInterval else {}) | ({cooldownPeriod = _s.cooldownPeriod} if _s.cooldownPeriod else {}) | ({idleReplicaCount = _s.idleReplicas} if _s.idleReplicas != Undefined else {}) | ({
            advanced = {
                horizontalPodAutoscalerConfig = {behavior = _s.behavior}
            }
        } if _s.behavior else {})
    }
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
    } if f.$type == "loss" else {})
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

faultKind = lambda f: Fault -> str {
    """Chaos Mesh kind a fault renders to: PodChaos, NetworkChaos or StressChaos."""
    "PodChaos" if f.$type in ["pod-kill", "pod-failure", "container-kill"] else "NetworkChaos" if f.$type in ["delay", "loss", "partition"] else "StressChaos"
}

faultSpec = lambda f: Fault, selector: {str:} -> {str:} {
    """The <kind>Spec for a fault against `selector` (a Chaos Mesh pod selector: namespaces, labelSelectors, …)."""
    _kind = faultKind(f)
    _podChaosSpec(f, selector) if _kind == "PodChaos" else _networkChaosSpec(f, selector) if _kind == "NetworkChaos" else _stressChaosSpec(f, selector)
}

experiment = lambda f: Fault, selector: {str:}, metadata: {str:} -> any {
    """
    A typed Chaos Mesh object for a fault: the one-shot PodChaos / NetworkChaos /
    StressChaos, or a Schedule embedding it when `f.schedule` is set.
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
        } | ({podChaos = _spec} if _kind == "PodChaos" else {networkChaos = _spec} if _kind == "NetworkChaos" else {stressChaos = _spec})
    } if f.schedule else cmpod.PodChaos {
        metadata = metadata
        spec = _spec
    } if _kind == "PodChaos" else cmnet.NetworkChaos {
        metadata = metadata
        spec = _spec
    } if _kind == "NetworkChaos" else cmstress.StressChaos {
        metadata = metadata
        spec = _spec
    }
}

_fault = lambda w: Workload, f: Fault -> any {
    experiment(f, _faultSelector(w), _faultMeta(w, f))
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
    } | ({serviceAccountName = t.serviceAccountName} if t.serviceAccountName else {})
}

# Shared JobSpec, used directly for a Job and nested under a CronJob's jobTemplate.
_jobSpec = lambda t: Task -> {str:} {
    {
        template = {
            metadata = {labels = _taskLabels(t)}
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
    """All manifests for a long-running workload: Deployment, optional Service, optional HPA/ScaledObject, Chaos Mesh faults, extras."""
    [_deployment(w)] + ([_service(w)] if w.service else []) + ([_hpa(w)] if w.hpa else []) + ([_scaler(w)] if w.scaler else []) + [_fault(w, f) for f in w.chaos] + w.extraManifests
}

renderTask = lambda t: Task -> [any] {
    """Manifests for a batch workload: a CronJob when `schedule` is set, else a Job, plus extras."""
    _base: [any] = [_cronjob(t)] if t.schedule else [_job(t)]
    _base + t.extraManifests
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
