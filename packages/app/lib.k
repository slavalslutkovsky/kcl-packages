"""
Application Kubernetes manifests — typed schemas + renderers (single source of truth).

Two archetypes, one package:
  • Workload → long-running apps (backend APIs, frontend/static apps): Deployment
    (+ Service, + optional HPA). Backend and frontend are the SAME archetype with
    different field values (e.g. prometheus on/off, nginx volumes, uid/gid).
  • Task → run-to-completion CLI apps: a batch/v1 Job, or a CronJob when `schedule`
    is set. Reuses the same container atoms (env/envFrom/security) as Workload.

Core resources use the typed `k8s` package and ExternalSecret uses the typed
`external-secrets` package, so rendered output is checked against the real
Kubernetes / CRD APIs. Consumers `import app`, build a `Workload`/`Task` (often
from a Helm-style values.yaml via `app.Workload {**yaml.decode(...)}`), and emit
with `manifests.yaml_stream(app.render(w))` / `app.renderTask(t)`. See examples/.
"""

import k8s.api.apps.v1 as appsv1
import k8s.api.core.v1 as corev1
import k8s.api.autoscaling.v2 as autoscalingv2
import k8s.api.batch.v1 as batchv1
import external_secrets.v1 as esv1
import keda.v1alpha1 as keda

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
    cpu?: int                        # → KEDA cpu trigger, Utilization %
    memory?: int                     # → KEDA memory trigger, Utilization %
    triggers: [{str:}] = []          # passthrough KEDA triggers
    pollingInterval?: int
    cooldownPeriod?: int
    idleReplicas?: int               # → idleReplicaCount (only valid with minReplicas 0)
    behavior?: {str:}                # → advanced.horizontalPodAutoscalerConfig.behavior
    check:
        cpu or memory or triggers, "Scaler needs at least one of cpu, memory, or triggers"

schema Workload:
    """A deployable long-running application: Deployment (+ Service, + optional HPA)."""
    name: str
    namespace?: str
    component: str = "server"
    partOf: str = "zerg"
    version?: str = "0.1.0"
    image: str
    imagePullPolicy: str = "IfNotPresent"
    replicas: int = 1
    port: int
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
    hpa?: Hpa                        # native HPA (legacy; prefer `scaler`)
    scaler?: Scaler                  # KEDA ScaledObject (preferred)
    podAnnotations: {str:str} = {}
    extraManifests: [{str:}] = []
    check:
        not (hpa and scaler), "use either `hpa` (native) or `scaler` (KEDA), not both"

schema Task:
    """A run-to-completion CLI workload: Job, or CronJob when `schedule` is set."""
    name: str
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
    name?: str                       # defaults to "<release name>-secrets"
    store: str = "gcp-secret-manager"
    refreshInterval: str = "1h"
    items: [{str:str}]

schema Release:
    """
    A whole app release in one values.yaml (Helm-style).

    Exactly one of `workload` (long-running: backend/frontend) or `task`
    (batch/CLI: Job/CronJob). Optional `config` → a ConfigMap named
    "<name>-config"; optional `externalSecret` → an ExternalSecret. This is what
    `app`'s own main.k renders when a values.yaml is present, so a consumer needs
    only a values.yaml — no local main.k / kcl.mod.
    """
    workload?: Workload
    task?: Task
    config?: {str:str}
    externalSecret?: ExternalSecretSpec
    check:
        workload or task, "Release needs a `workload:` or a `task:`"
        not (workload and task), "Release can't have both `workload:` and `task:`"

# ── Shared container atoms (env / envFrom / probe) ───────────────────────────

_envVar = lambda e: EnvVar -> {str:} {
    {name = e.name} | ({value = e.value} if e.value \
        else {valueFrom = {secretKeyRef = {name = e.secretName, key = e.secretKey, optional = e.optional}}} if e.secretName \
        else {valueFrom = {configMapKeyRef = {name = e.configMapName, key = e.configMapKey}}} if e.configMapName \
        else {})
}

_envFrom = lambda f: EnvFrom -> {str:} {
    {configMapRef = {name = f.name}} if f.kind == "configMap" else {secretRef = {name = f.name, optional = f.optional}}
}

_probe = lambda p: Probe -> {str:} {
    ({httpGet = {path = p.path, port = p.port}} if p.$type == "http" else {grpc = {port = p.port}}) | {
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
    } | ({envFrom = [_envFrom(f) for f in w.envFrom]} if w.envFrom else {}) \
      | ({env = [_envVar(e) for e in w.env]} if w.env else {}) \
      | ({startupProbe = _probe(w.startupProbe)} if w.startupProbe else {}) \
      | ({livenessProbe = _probe(w.livenessProbe)} if w.livenessProbe else {}) \
      | ({readinessProbe = _probe(w.readinessProbe)} if w.readinessProbe else {}) \
      | {
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
            selector = {matchLabels = {app = w.name}}
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
        metadata = {name = w.name} | ({namespace = w.namespace} if w.namespace else {})
        spec = {
            selector = {app = w.name}
            ports = [{$protocol = "TCP", name = w.portName, port = w.port, targetPort = w.port}]
            $type = w.serviceType
        }
    }
}

_hpa = lambda w: Workload -> autoscalingv2.HorizontalPodAutoscaler {
    autoscalingv2.HorizontalPodAutoscaler {
        metadata = {name = w.name, labels = {app = w.name}} | ({namespace = w.namespace} if w.namespace else {})
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
        metadata = {name = w.name, labels = {app = w.name}} | ({namespace = w.namespace} if w.namespace else {})
        spec = {
            scaleTargetRef = {name = w.name}
            minReplicaCount = _s.minReplicas
            maxReplicaCount = _s.maxReplicas
            triggers = _triggers
        } | ({pollingInterval = _s.pollingInterval} if _s.pollingInterval else {}) \
          | ({cooldownPeriod = _s.cooldownPeriod} if _s.cooldownPeriod else {}) \
          | ({idleReplicaCount = _s.idleReplicas} if _s.idleReplicas != Undefined else {}) \
          | ({advanced = {horizontalPodAutoscalerConfig = {behavior = _s.behavior}}} if _s.behavior else {})
    }
}

# ── Task (Job / CronJob) renderers ───────────────────────────────────────────

_taskLabels = lambda t: Task -> {str:str} {
    {
        "app" = t.name
        "app.kubernetes.io/name" = t.name
        "app.kubernetes.io/component" = t.component
        "app.kubernetes.io/part-of" = t.partOf
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
    } | ({command = t.command} if t.command else {}) \
      | ({args = t.args} if t.args else {}) \
      | ({envFrom = [_envFrom(f) for f in t.envFrom]} if t.envFrom else {}) \
      | ({env = [_envVar(e) for e in t.env]} if t.env else {}) \
      | {
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
    } | ({completions = t.completions} if t.completions else {}) \
      | ({parallelism = t.parallelism} if t.parallelism else {}) \
      | ({activeDeadlineSeconds = t.activeDeadlineSeconds} if t.activeDeadlineSeconds else {}) \
      | ({ttlSecondsAfterFinished = t.ttlSecondsAfterFinished} if t.ttlSecondsAfterFinished != Undefined else {})
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
        } | ({suspend = t.suspend} if t.suspend != Undefined else {}) \
          | ({startingDeadlineSeconds = t.startingDeadlineSeconds} if t.startingDeadlineSeconds else {})
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
    """All manifests for a long-running workload: Deployment, optional Service, optional HPA, extras."""
    [_deployment(w)] \
        + ([_service(w)] if w.service else []) \
        + ([_hpa(w)] if w.hpa else []) \
        + ([_scaler(w)] if w.scaler else []) \
        + w.extraManifests
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
    _es: [any] = [externalSecret(
        r.externalSecret.name or "${_name}-secrets",
        r.externalSecret.store,
        r.externalSecret.items,
        _ns,
        r.externalSecret.refreshInterval,
    )] if r.externalSecret else []
    _core + _cm + _es
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

externalSecret = lambda name: str, store: str, items: [{str:str}], namespace: str = "", refreshInterval: str = "1h" -> esv1.ExternalSecret {
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
