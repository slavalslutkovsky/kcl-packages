# Tests for the app package: Workload (BE/FE) + Task (CLI Job/CronJob) + helpers.
# Run: kcl test   (asserts logical contracts of the rendered manifests)
import yaml
import file
import json
import crypto
import runtime

# ── Backend Workload (zerg-api template) ─────────────────────────────────────
test_backend = lambda {
    w = Workload {
        name = "zerg-api"
        namespace = "zerg"
        component = "api-server"
        image = "yurikrupnik/zerg-api:latest"
        port = 8080
        startupProbe = {$type = "http", path = "/health", port = 8080, initialDelaySeconds = 2, periodSeconds = 5, failureThreshold = 6, timeoutSeconds = 3}
        livenessProbe = {$type = "http", path = "/health", port = 8080, periodSeconds = 10, failureThreshold = 3, timeoutSeconds = 3}
        readinessProbe = {$type = "http", path = "/ready", port = 8080, periodSeconds = 5, failureThreshold = 3, timeoutSeconds = 2}
        envFrom = [
            {kind = "configMap", name = "zerg-shared-config"}
            {kind = "configMap", name = "zerg-api-config"}
            {kind = "secret", name = "zerg-shared-secrets"}
            {kind = "secret", name = "zerg-api-secrets"}
        ]
        env = [
            {name = "REDIS_USERNAME", secretName = "redis-redis-account-default", secretKey = "username"}
            {name = "REDIS_PASSWORD", secretName = "redis-redis-account-default", secretKey = "password"}
        ]
        scaler = {minReplicas = 1, maxReplicas = 10, cpu = 70, memory = 80}
    }
    out = render(w)
    assert len(out) == 3, "BE renders Deployment + Service + ScaledObject"
    dep = out[0]
    svc = out[1]
    so = out[2]
    assert dep.kind == "Deployment" and dep.apiVersion == "apps/v1"
    assert dep.metadata.name == "zerg-api"
    assert dep.metadata.labels["app.kubernetes.io/component"] == "api-server"
    assert dep.metadata.labels["app.kubernetes.io/part-of"] == "zerg"
    # prometheus scrape annotations on the pod template (prometheus defaults True)
    assert dep.spec.template.metadata.annotations["prometheus.io/scrape"] == "true"
    assert dep.spec.template.metadata.annotations["prometheus.io/port"] == "8080"
    c = dep.spec.template.spec.containers[0]
    assert len(c.envFrom) == 4, "4 envFrom sources"
    assert len(c.env) == 2, "2 secret-backed env vars"
    assert c.env[0].name == "REDIS_USERNAME"
    assert c.env[0].valueFrom.secretKeyRef.name == "redis-redis-account-default"
    assert c.env[0].valueFrom.secretKeyRef.key == "username"
    # pod security: no runAsGroup → fsGroup falls back to runAsUser (65534)
    assert dep.spec.template.spec.securityContext.runAsUser == 65534
    assert dep.spec.template.spec.securityContext.fsGroup == 65534
    assert dep.spec.template.spec.restartPolicy == "Always"
    assert svc.kind == "Service" and svc.spec.$type == "ClusterIP"
    assert svc.spec.ports[0].port == 8080
    assert so.kind == "ScaledObject" and so.spec.scaleTargetRef.name == "zerg-api"
    assert so.spec.minReplicaCount == 1 and so.spec.maxReplicaCount == 10
    assert [t.$type for t in so.spec.triggers] == ["cpu", "memory"], "cpu / memory utilization triggers"
}

# ── Frontend Workload (zerg-web template) ────────────────────────────────────
test_frontend = lambda {
    w = Workload {
        name = "zerg-web"
        namespace = "zerg"
        component = "frontend"
        image = "yurikrupnik/zerg-web"
        port = 8080
        runAsUser = 101
        runAsGroup = 101
        prometheus = False
        env = [
            {name = "UPSTREAM_HOST", configMapName = "proxy-envs", configMapKey = "upstream_host"}
            {name = "UPSTREAM_PORT", configMapName = "proxy-envs", configMapKey = "upstream_port"}
            {name = "UPSTREAM_NAME", configMapName = "proxy-envs", configMapKey = "upstream_name"}
        ]
        volumeMounts = [
            {name = "nginx-conf-d", mountPath = "/etc/nginx/conf.d"}
            {name = "nginx-cache", mountPath = "/var/cache/nginx"}
            {name = "tmp", mountPath = "/tmp"}
        ]
        volumes = [
            {name = "nginx-conf-d", emptyDir = {}}
            {name = "nginx-cache", emptyDir = {}}
            {name = "tmp", emptyDir = {}}
        ]
        terminationGracePeriodSeconds = 10
    }
    out = render(w)
    assert len(out) == 2, "FE renders Deployment + Service (no autoscaler)"
    dep = out[0]
    assert dep.metadata.labels["app.kubernetes.io/component"] == "frontend"
    # prometheus False → no scrape annotations on the pod template
    assert dep.spec.template.metadata?.annotations == Undefined, "no prometheus annotations when prometheus=False"
    # explicit runAsGroup → runAsGroup + fsGroup both 101
    assert dep.spec.template.spec.securityContext.runAsGroup == 101
    assert dep.spec.template.spec.securityContext.fsGroup == 101
    c = dep.spec.template.spec.containers[0]
    assert len(c.env) == 3
    assert c.env[0].valueFrom.configMapKeyRef.name == "proxy-envs"
    assert c.env[0].valueFrom.configMapKeyRef.key == "upstream_host"
    assert len(c.volumeMounts) == 3
    assert dep.spec.template.spec.terminationGracePeriodSeconds == 10
}

# ── CLI Task as a one-shot Job ───────────────────────────────────────────────
test_task_job = lambda {
    t = Task {
        name = "db-migrate"
        namespace = "zerg"
        component = "migration"
        image = "yurikrupnik/zerg-api:latest"
        command = ["/app/migrate"]
        args = ["up"]
        envFrom = [{kind = "secret", name = "zerg-api-secrets"}]
        env = [{name = "LOG", value = "info"}]
    }
    out = renderTask(t)
    assert len(out) == 1, "no schedule → single Job"
    job = out[0]
    assert job.kind == "Job" and job.apiVersion == "batch/v1"
    assert job.metadata.name == "db-migrate"
    assert job.metadata.labels["app.kubernetes.io/component"] == "migration"
    assert job.spec.backoffLimit == 3
    assert job.spec.ttlSecondsAfterFinished == 3600
    ps = job.spec.template.spec
    assert ps.restartPolicy == "Never"
    c = ps.containers[0]
    assert c.command == ["/app/migrate"]
    assert c.args == ["up"]
    assert len(c.envFrom) == 1
    assert c.env[0].name == "LOG" and c.env[0].value == "info"
    assert ps.securityContext.fsGroup == 65534
}

# ── CLI Task as a scheduled CronJob ──────────────────────────────────────────
test_task_cronjob = lambda {
    t = Task {
        name = "nightly-cleanup"
        namespace = "zerg"
        component = "cron"
        image = "yurikrupnik/zerg-tasks:latest"
        command = ["/app/cleanup"]
        schedule = "0 2 * * *"
        restartPolicy = "OnFailure"
    }
    out = renderTask(t)
    assert len(out) == 1, "schedule → single CronJob"
    cj = out[0]
    assert cj.kind == "CronJob" and cj.apiVersion == "batch/v1"
    assert cj.spec.schedule == "0 2 * * *"
    assert cj.spec.concurrencyPolicy == "Forbid"
    assert cj.spec.successfulJobsHistoryLimit == 3
    jps = cj.spec.jobTemplate.spec.template.spec
    assert jps.restartPolicy == "OnFailure"
    assert jps.containers[0].command == ["/app/cleanup"]
}

# ── Config helpers ───────────────────────────────────────────────────────────
test_helpers = lambda {
    cm = configMap("proxy-envs", {upstream_host = "zerg-api"}, "zerg")
    assert cm.kind == "ConfigMap"
    assert cm.metadata.namespace == "zerg"
    assert cm.data.upstream_host == "zerg-api"

    s = secret("smtp", {SMTP_USERNAME = "", SMTP_PASSWORD = ""}, "zerg")
    assert s.kind == "Secret" and s.$type == "Opaque"
    assert "SMTP_USERNAME" in s.stringData

    es = externalSecret("zerg-api-secrets", "gcp-secret-manager", [
        {secretKey = "JWT_SECRET", key = "app-secrets", property = "zerg.jwt_secret"}
    ], "zerg")
    assert es.kind == "ExternalSecret"
    assert es.spec.secretStoreRef.name == "gcp-secret-manager"
    assert es.spec.data[0].secretKey == "JWT_SECRET"
    assert es.spec.data[0].remoteRef.property == "zerg.jwt_secret"
}

# ── Helm-style values: decode YAML → typed schema (validated) → manifests ─────
test_values_from_yaml = lambda {
    # This is exactly what a consumer's main.k does: yaml.decode(file.read("values.yaml"))
    # then spread into the typed schema. The schema validates the decoded dict.
    _beValues = yaml.decode("""\
name: zerg-api
namespace: zerg
component: api-server
image: yurikrupnik/zerg-api:latest
port: 8080
envFrom:
  - kind: configMap
    name: zerg-api-config
  - kind: secret
    name: zerg-api-secrets
scaler:
  minReplicas: 2
  maxReplicas: 8
  cpu: 70
""")
    w = Workload {**_beValues}
    out = render(w)
    assert len(out) == 3, "values.yaml-driven BE → Deployment + Service + ScaledObject"
    assert out[0].metadata.name == "zerg-api"
    assert out[0].spec.template.spec.containers[0].envFrom[1].secretRef.name == "zerg-api-secrets"
    assert out[2].spec.minReplicaCount == 2 and out[2].spec.maxReplicaCount == 8

    _cliValues = yaml.decode("""\
name: db-migrate
namespace: zerg
image: yurikrupnik/zerg-api:latest
command: ["/app/migrate", "up"]
schedule: "0 3 * * *"
""")
    t = Task {**_cliValues}
    cout = renderTask(t)
    assert cout[0].kind == "CronJob", "values.yaml with schedule → CronJob"
    assert cout[0].spec.schedule == "0 3 * * *"
}

# ── The shipped examples/*.yaml actually validate against the schemas ─────────
test_examples_valid = lambda {
    be = Release {**yaml.decode(file.read("examples/values-backend.yaml"))}
    beOut = renderRelease(be)
    assert [m.kind for m in beOut] == ["ServiceAccount", "Deployment", "Service", "PodDisruptionBudget", "ScaledObject", "ServiceMonitor", "PrometheusRule", "ConfigMap", "ConfigMap", "ExternalSecret"], "backend example: ${[m.kind for m in beOut]}"
    assert be.workload.name == "zerg-api" and be.workload.prometheus == True
    assert beOut[7].metadata.name == "zerg-api-dashboard-overview", "dashboards before the Release-level ConfigMap"
    assert beOut[8].metadata.name == "zerg-api-config", "config → <name>-config ConfigMap"
    assert beOut[9].metadata.name == "zerg-api-secrets", "externalSecret → <name>-secrets"

    fe = Release {**yaml.decode(file.read("examples/values-frontend.yaml"))}
    assert [m.kind for m in renderRelease(fe)] == ["Deployment", "Service"], "frontend example → Deployment + Service"
    assert fe.workload.prometheus == False and fe.workload.runAsGroup == 101

    cli = Release {**yaml.decode(file.read("examples/values-cli.yaml"))}
    assert renderRelease(cli)[0].kind == "Job", "cli example (no schedule) → Job"
    assert cli.task.command == ["/app/migrate"]

    ch = Release {**yaml.decode(file.read("examples/values-chaos.yaml"))}
    _litmus = ["ServiceAccount", "Role", "RoleBinding", "Role", "RoleBinding", "ChaosExperiment", "ChaosEngine"]
    assert [m.kind for m in renderRelease(ch)] == ["Deployment", "Service", "ScaledObject", "Schedule", "NetworkChaos", "NetworkChaos", "NetworkChaos", "Schedule", "StressChaos", "HTTPChaos", "IOChaos", "DNSChaos", "TimeChaos"] + _litmus * 3, "chaos example → core + one Chaos Mesh object per fault, seven per Litmus fault"

    wk = Release {**yaml.decode(file.read("examples/values-worker.yaml"))}
    wkOut = renderRelease(wk)
    assert [m.kind for m in wkOut] == ["Deployment", "ScaledObject", "ConfigMap"], "worker example → Deployment (no Service) + KEDA ScaledObject + ConfigMap"
    assert wkOut[0].spec?.replicas == Undefined, "worker Deployment leaves replicas to KEDA"
    assert wkOut[1].spec.minReplicaCount == 0 and wkOut[1].spec.triggers[0].$type == "nats-jetstream"
    assert wkOut[1].spec.fallback.replicas == 2

    qj = Release {**yaml.decode(file.read("examples/values-queue-job.yaml"))}
    assert [m.kind for m in renderRelease(qj)] == ["ServiceAccount", "TriggerAuthentication", "ScaledJob"], "queue-job example → identity, then KEDA's auth before the ScaledJob that uses it"
}

# ── Release: whole-app values.yaml → workload + config + externalSecret ───────
test_release = lambda {
    r = Release {**yaml.decode("""\
workload:
  name: zerg-api
  namespace: zerg
  component: api-server
  image: yurikrupnik/zerg-api:latest
  port: 8080
  envFrom:
    - kind: configMap
      name: zerg-api-config
  scaler:
    minReplicas: 1
    maxReplicas: 10
    cpu: 70
config:
  PORT: "8080"
  RUST_LOG: info
externalSecret:
  store: gcp-secret-manager
  items:
    - secretKey: JWT_SECRET
      key: app-secrets
      property: zerg-api.jwt_secret
""")}
    out = renderRelease(r)
    kinds = [m.kind for m in out]
    assert kinds == ["Deployment", "Service", "ScaledObject", "ConfigMap", "ExternalSecret"], "release → 5 resources in order: ${kinds}"
    assert out[3].metadata.name == "zerg-api-config", "configMap named <name>-config"
    assert out[3].data.RUST_LOG == "info"
    assert out[4].metadata.name == "zerg-api-secrets", "externalSecret defaults to <name>-secrets"
    assert out[4].spec.data[0].secretKey == "JWT_SECRET"

    # a Task-based release → Job (+ nothing else here)
    rt = Release {**yaml.decode("""\
task:
  name: db-migrate
  namespace: zerg
  image: yurikrupnik/zerg-api:latest
  command: ["/app/migrate", "up"]
""")}
    assert renderRelease(rt)[0].kind == "Job", "task release → Job"
}

# ── Overlay: deepMerge base + env (kustomize-overlay semantics) ──────────────
test_merge_values = lambda {
    _base = yaml.decode("""\
workload:
  name: zerg-api
  image: yurikrupnik/zerg-api:latest
  port: 8080
  scaler:
    minReplicas: 1
    maxReplicas: 5
    cpu: 70
config:
  PORT: "8080"
  OAUTH_AUTO_LINK: "true"
  CORS: localhost
""")
    _prod = yaml.decode("""\
workload:
  scaler:
    maxReplicas: 20
config:
  OAUTH_AUTO_LINK: "false"
  CORS: prod.example.com
  RATE_LIMIT: "200"
""")
    m = mergeValues(_base, _prod)
    # deep, right-wins: base kept where not overridden, overlay wins on conflict, adds new
    assert m.config.PORT == "8080", "base-only key kept"
    assert m.config.OAUTH_AUTO_LINK == "false", "overlay overrides scalar"
    assert m.config.CORS == "prod.example.com", "overlay overrides scalar"
    assert m.config.RATE_LIMIT == "200", "overlay adds key"
    assert m.workload.scaler.minReplicas == 1, "deep-nested base kept"
    assert m.workload.scaler.maxReplicas == 20, "deep-nested overlay wins"
    # merged result still builds a valid, type-checked Release
    r = Release {**m}
    out = renderRelease(r)
    assert out[2].spec.maxReplicaCount == 20, "ScaledObject reflects prod overlay"
    assert out[3].data.RATE_LIMIT == "200", "ConfigMap reflects prod overlay"
}

# ── KEDA Scaler (ScaledObject): cpu/mem, passthrough, scale-to-zero ───────────
test_scaler_cpu_mem = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
port: 8080
scaler:
  minReplicas: 2
  maxReplicas: 8
  cpu: 70
  memory: 80
""")}
    out = render(w)
    kinds = [m.kind for m in out]
    assert kinds == ["Deployment", "Service", "ScaledObject"], "cpu/mem scaler → SO not HPA: ${kinds}"
    so = out[2]
    assert so.apiVersion == "keda.sh/v1alpha1"
    assert so.spec.scaleTargetRef.name == "zerg-api"
    assert so.spec.minReplicaCount == 2 and so.spec.maxReplicaCount == 8
    ts = so.spec.triggers
    assert len(ts) == 2, "cpu + memory triggers"
    assert ts[0].$type == "cpu" and ts[0].metadata.value == "70" and ts[0].metricType == "Utilization"
    assert ts[1].$type == "memory" and ts[1].metadata.value == "80"
}

test_scaler_scale_to_zero = lambda {
    # passthrough NATS trigger + scale-to-zero (the zerg-email-nats worker case)
    w = Workload {**yaml.decode("""\
name: zerg-email-nats
namespace: zerg
image: yurikrupnik/zerg-email-nats:latest
port: 8081
prometheus: false
scaler:
  minReplicas: 0
  maxReplicas: 10
  pollingInterval: 5
  cooldownPeriod: 60
  triggers:
    - type: nats-jetstream
      metadata:
        stream: EMAILS
        consumer: email-worker
        lagThreshold: "10"
""")}
    out = render(w)
    so = [m for m in out if m.kind == "ScaledObject"][0]
    assert so.spec.minReplicaCount == 0, "scale-to-zero"
    assert so.spec.pollingInterval == 5 and so.spec.cooldownPeriod == 60
    assert so.spec.triggers[0].$type == "nats-jetstream", "passthrough trigger type"
    assert so.spec.triggers[0].metadata.stream == "EMAILS"
}

test_scaler_paths = lambda {
    ws = Workload {name = "x", image = "i", port = 8080, scaler = {cpu = 70}}
    assert [m.kind for m in render(ws)][2] == "ScaledObject", "scaler path"
    # idleReplicas → idleReplicaCount (0 is a real value, not "unset")
    wi = Workload {name = "x", image = "i", port = 8080, scaler = {cpu = 70, minReplicas = 1, idleReplicas = 0}}
    assert render(wi)[2].spec.idleReplicaCount == 0, "idleReplicas 0 is emitted"
}

# ── Deployment omits spec.replicas when autoscaled (GitOps/Flagger safe) ──────
test_replicas_ownership = lambda {
    # no autoscaler → replicas present (fixed count, e.g. frontend)
    plain = Workload {name = "web", image = "nginx", port = 8080, replicas = 2}
    dep0 = render(plain)[0]
    assert dep0.spec.replicas == 2, "no autoscaler → spec.replicas set"
    # KEDA scaler → replicas omitted (ScaledObject owns it)
    ws = Workload {name = "api", image = "i", port = 8080, scaler = {cpu = 70}}
    deps = render(ws)[0]
    assert deps.spec?.replicas == Undefined, "scaler → spec.replicas omitted"
}

# ── Chaos Mesh faults: one experiment per fault, pinned to this workload ──────
test_chaos_one_shot = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
chaos:
  - name: kill
    type: pod-kill
  - name: flaky
    type: pod-failure
    duration: 1m
    mode: fixed-percent
    value: "50"
  - name: restart
    type: container-kill
    containerNames: [zerg-api]
  - name: slow
    type: delay
    latency: 200ms
    jitter: 50ms
    correlation: "25"
    externalTargets: [postgres-rw.dbs.svc]
  - name: lossy
    type: loss
    loss: "30"
  - name: cut
    type: partition
    direction: both
    externalTargets: [postgres-rw.dbs.svc]
  - name: cpu
    type: cpu
    workers: 2
    load: 80
  - name: mem
    type: memory
    size: 256MB
""")}
    out = render(w)
    kinds = [m.kind for m in out]
    assert kinds == ["Deployment", "Service", "PodChaos", "PodChaos", "PodChaos", "NetworkChaos", "NetworkChaos", "NetworkChaos", "StressChaos", "StressChaos"], "one object per fault, after the core resources: ${kinds}"
    faults = out[2::]
    # every experiment is namespaced with the workload and selects only its pods
    assert all_true([f.apiVersion == "chaos-mesh.org/v1alpha1" for f in faults])
    assert all_true([f.metadata.namespace == "zerg" for f in faults]), "every fault in the workload namespace"
    assert all_true([f.metadata.labels["app.kubernetes.io/name"] == "zerg-api" for f in faults])
    assert all_true([f.spec.selector.namespaces == ["zerg"] for f in faults]), "every selector pinned to the namespace"
    assert all_true([f.spec.selector.labelSelectors == {app = "zerg-api"} for f in faults]), "every selector pinned to the workload"
    names = [f.metadata.name for f in faults]
    assert names == ["zerg-api-kill", "zerg-api-flaky", "zerg-api-restart", "zerg-api-slow", "zerg-api-lossy", "zerg-api-cut", "zerg-api-cpu", "zerg-api-mem"], "named <workload>-<fault>: ${names}"

    kill = faults[0]
    assert kill.spec.action == "pod-kill" and kill.spec.mode == "one"
    assert kill.spec?.duration == Undefined, "pod-kill is instantaneous: no duration"
    flaky = faults[1]
    assert flaky.spec.action == "pod-failure" and flaky.spec.duration == "1m"
    assert flaky.spec.mode == "fixed-percent" and flaky.spec.value == "50"
    assert faults[2].spec.action == "container-kill" and faults[2].spec.containerNames == ["zerg-api"]

    slow = faults[3]
    assert slow.spec.action == "delay" and slow.spec.direction == "to" and slow.spec.duration == "30s"
    assert slow.spec.delay.latency == "200ms" and slow.spec.delay.jitter == "50ms" and slow.spec.delay.correlation == "25"
    assert slow.spec.externalTargets == ["postgres-rw.dbs.svc"]
    lossy = faults[4]
    assert lossy.spec.action == "loss" and lossy.spec.loss.loss == "30" and lossy.spec.loss?.correlation == Undefined
    assert lossy.spec?.delay == Undefined and lossy.spec?.externalTargets == Undefined
    cut = faults[5]
    assert cut.spec.action == "partition" and cut.spec.direction == "both"
    assert cut.spec?.delay == Undefined and cut.spec?.loss == Undefined

    cpu = faults[6]
    assert cpu.spec.stressors.cpu.workers == 2 and cpu.spec.stressors.cpu.load == 80
    assert cpu.spec.stressors?.memory == Undefined
    mem = faults[7]
    assert mem.spec.stressors.memory.workers == 1 and mem.spec.stressors.memory.size == "256MB"
    assert mem.spec.stressors?.cpu == Undefined
}

test_chaos_schedule = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
chaos:
  - name: kill
    type: pod-kill
    schedule: "*/10 * * * *"
  - name: slow
    type: delay
    schedule: "0 3 * * *"
    concurrencyPolicy: Allow
    historyLimit: 5
  - name: cpu
    type: cpu
    schedule: "0 4 * * *"
""")}
    out = render(w)
    scheds = out[2::]
    assert [m.kind for m in scheds] == ["Schedule", "Schedule", "Schedule"], "schedule → Schedule, whatever the fault type"
    kill = scheds[0]
    assert kill.spec.schedule == "*/10 * * * *" and kill.spec.$type == "PodChaos"
    assert kill.spec.concurrencyPolicy == "Forbid" and kill.spec.historyLimit == 1
    assert kill.spec.podChaos.action == "pod-kill"
    assert kill.spec.podChaos.selector.namespaces == ["zerg"], "embedded spec keeps the pinned selector"
    assert kill.spec?.networkChaos == Undefined and kill.spec?.stressChaos == Undefined
    slow = scheds[1]
    assert slow.spec.$type == "NetworkChaos" and slow.spec.networkChaos.delay.latency == "100ms"
    assert slow.spec.concurrencyPolicy == "Allow" and slow.spec.historyLimit == 5
    assert scheds[2].spec.$type == "StressChaos" and scheds[2].spec.stressChaos.stressors.cpu.load == 100
}

test_chaos_release_order = lambda {
    # faults sit between the autoscaler and the Release-level ConfigMap/ExternalSecret
    r = Release {**yaml.decode("""\
workload:
  name: zerg-api
  namespace: zerg
  image: yurikrupnik/zerg-api:latest
  scaler:
    cpu: 70
  chaos:
    - name: kill
      type: pod-kill
config:
  PORT: "8080"
""")}
    kinds = [m.kind for m in renderRelease(r)]
    assert kinds == ["Deployment", "Service", "ScaledObject", "PodChaos", "ConfigMap"], "release with chaos: ${kinds}"
}

# ── Backstage catalog ────────────────────────────────────────────────────────
# The contract that makes the portal useful: the entity's kubernetes-id
# annotation and the label on every rendered object are the same string, so the
# Kubernetes tab resolves this release — chaos experiments included.
test_catalog_component = lambda {
    r = Release {**yaml.decode(file.read("examples/values-chaos.yaml"))}
    out = catalogEntities(r)
    assert [e.kind for e in out] == ["Component"], "one Component, no APIs declared: ${[e.kind for e in out]}"
    c = out[0]
    assert c.apiVersion == "backstage.io/v1alpha1", "entities are catalog objects, not Kubernetes ones"
    assert c.metadata.name == "zerg-api", "the entity name defaults to the workload's"
    assert c.spec.$type == "service", "a workload is a service unless it says otherwise"
    assert c.spec.system == "zerg", "system defaults to the workload's partOf"
    assert c.spec.lifecycle == "production" and c.spec.owner == "team-zerg"

    _id = c.metadata.annotations["backstage.io/kubernetes-id"]
    assert _id == "zerg-api" and c.metadata.annotations["backstage.io/kubernetes-namespace"] == "zerg"
    assert c.metadata.annotations["platform.example.org/chaos-faults"] == "kill-one=pod-kill,slow-net=delay,lossy=loss,cut-db=partition,hot-cpu=cpu,memory-pressure=memory,slow-responses=http-delay,slow-disk=io-latency,no-db-dns=dns-error,clock-skew=time-skew,litmus-kill=pod-kill,litmus-slow-net=delay,litmus-hot-cpu=cpu", "every declared fault must be readable without the cluster"

    # The other half of the link: nothing the release renders may be invisible
    # to the entity, chaos objects least of all.
    assert all_true([o.metadata.labels["backstage.io/kubernetes-id"] == _id for o in renderRelease(r) if o.metadata?.labels]), "every labelled object must carry the entity's id"
    _chaos = [o for o in renderRelease(r) if o.apiVersion == "chaos-mesh.org/v1alpha1"]
    assert len(_chaos) == 10 and all_true([o.metadata.labels["backstage.io/kubernetes-id"] == _id for o in _chaos]), "the experiments are what the component page shows"
    _engines = [o for o in renderRelease(r) if o.apiVersion == "litmuschaos.io/v1alpha1"]
    assert len(_engines) == 6 and all_true([o.metadata.labels["backstage.io/kubernetes-id"] == _id for o in _engines]), "the Litmus engines and definitions carry the id too, though they live in `litmus`"

    # The Deployment's selector is immutable — the id must never leak into it.
    _dep = renderRelease(r)[0]
    assert _dep.spec.selector.matchLabels == {app = "zerg-api"}, "selector must stay `app` alone: ${_dep.spec.selector.matchLabels}"
    assert _dep.spec.template.metadata.labels["backstage.io/kubernetes-id"] == _id, "pods carry it, so the plugin finds them too"
}

# A task is a different archetype, and Backstage should say so.
test_catalog_task_type = lambda {
    _cron = Release {**yaml.decode("""\
task:
  name: nightly-reindex
  namespace: zerg
  image: yurikrupnik/zerg-cli:latest
  schedule: "0 3 * * *"
catalog:
  owner: team-zerg
""")}
    assert catalogEntities(_cron)[0].spec.$type == "cronjob", "a scheduled task is a cronjob"
    _job = Release {**yaml.decode("""\
task:
  name: migrate
  image: yurikrupnik/zerg-cli:latest
catalog:
  owner: team-zerg
  type: library
""")}
    _e = catalogEntities(_job)[0]
    assert _e.spec.$type == "library", "an explicit type wins over the archetype default"
    assert _e.metadata.annotations?["backstage.io/kubernetes-namespace"] == Undefined, "no namespace, no namespace annotation"
}

# APIs: emitted as their own entities and wired to the Component without the
# ref being written twice.
test_catalog_apis = lambda {
    r = Release {**yaml.decode("""\
workload:
  name: zerg-api
  image: yurikrupnik/zerg-api:latest
catalog:
  owner: team-zerg
  system: zerg
  consumesApis: [api:billing]
  providesApis: [zerg-api-grpc]
  apis:
    - name: zerg-api-openapi
      definitionUrl: https://api.example.com/openapi.yaml
    - name: zerg-api-asyncapi
      type: asyncapi
      lifecycle: experimental
      owner: team-events
      definition: "asyncapi: 3.0.0"
""")}
    out = catalogEntities(r)
    assert [e.kind for e in out] == ["Component", "API", "API"], "one entity per api, component first: ${[e.kind for e in out]}"
    assert out[0].spec.providesApis == ["zerg-api-grpc", "zerg-api-openapi", "zerg-api-asyncapi"], "declared apis join the explicit refs: ${out[0].spec.providesApis}"
    assert out[0].spec.consumesApis == ["api:billing"]

    _open = out[1]
    assert _open.spec.$type == "openapi" and _open.spec.owner == "team-zerg" and _open.spec.lifecycle == "production", "api owner/lifecycle default to the component's"
    assert _open.spec.definition == {"$text" = "https://api.example.com/openapi.yaml"}, "a URL becomes the catalog's \\$text placeholder: ${_open.spec.definition}"
    assert _open.spec.system == "zerg", "apis belong to the component's system"
    _async = out[2]
    assert _async.spec.definition == "asyncapi: 3.0.0", "an inline definition is passed through as written"
    assert _async.spec.owner == "team-events" and _async.spec.lifecycle == "experimental", "an api may own itself"
}

test_catalog_absent = lambda {
    r = Release {**yaml.decode("""\
workload:
  name: zerg-api
  image: yurikrupnik/zerg-api:latest
""")}
    assert catalogEntities(r) == [], "no catalog block → no entities"
    assert all_true([o.apiVersion != "backstage.io/v1alpha1" for o in renderRelease(r)]), "entities must never reach the manifest stream"
    assert renderRelease(r)[0].metadata.labels["backstage.io/kubernetes-id"] == "zerg-api", "the plugin label does not wait for a catalog block"
}

# Typed CRD/k8s sub-objects never compare equal to dict literals; compare
# their plain JSON shape instead.
_plain = lambda x -> any {
    json.decode(json.encode(x))
}

# ── ServiceAccount: identity, token, workload identity, namespaced RBAC ──────
test_service_account = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
serviceAccount:
  cloud: azure
  identity: 11111111-2222-3333-4444-555555555555
  imagePullSecrets: [regcred]
  annotations: {team: zerg}
  rules:
    - resources: [configmaps]
      verbs: [get, watch]
      resourceNames: [zerg-flags]
""")}
    out = render(w)
    assert [m.kind for m in out][:4:] == ["ServiceAccount", "Role", "RoleBinding", "Deployment"], "identity before the pods that use it: ${[m.kind for m in out]}"
    sa = out[0]
    assert sa.metadata.name == "zerg-api" and sa.metadata.namespace == "zerg"
    assert sa.metadata.annotations == {"azure.workload.identity/client-id" = "11111111-2222-3333-4444-555555555555", team = "zerg"}, "cloud annotation merged with explicit ones"
    assert sa.automountServiceAccountToken == False and _plain(sa.imagePullSecrets) == [{name = "regcred"}]
    assert _plain(out[1].rules) == [{apiGroups = [""], resources = ["configmaps"], verbs = ["get", "watch"], resourceNames = ["zerg-flags"]}]
    rb = out[2]
    assert rb.roleRef.name == "zerg-api" and _plain(rb.subjects) == [{kind = "ServiceAccount", name = "zerg-api", namespace = "zerg"}], "bound to this ServiceAccount only"
    pod = out[3].spec.template
    assert pod.spec.serviceAccountName == "zerg-api" and pod.spec.automountServiceAccountToken == False
    assert pod.metadata.labels["azure.workload.identity/use"] == "true", "Azure's webhook only injects labelled pods"
    assert out[3].spec.selector.matchLabels == {app = "zerg-api"}, "the identity label never enters the immutable selector"

    # An existing ServiceAccount is referenced, never rendered
    ext = render(Workload {name = "web", image = "nginx", serviceAccount = {create = False, name = "shared", automountToken = True}})
    assert [m.kind for m in ext] == ["Deployment", "Service"]
    assert ext[0].spec.template.spec.serviceAccountName == "shared" and ext[0].spec.template.spec.automountServiceAccountToken == True
    assert ext[0].spec.template.metadata.labels?["azure.workload.identity/use"] == Undefined

    gke = render(Workload {name = "api", image = "i", serviceAccount = {cloud = "gcp", identity = "api@p.iam.gserviceaccount.com"}})[0]
    assert gke.metadata.annotations == {"iam.gke.io/gcp-service-account" = "api@p.iam.gserviceaccount.com"}
    eks = render(Workload {name = "api", image = "i", serviceAccount = {cloud = "aws", identity = "arn:aws:iam::123456789012:role/api"}})[0]
    assert eks.metadata.annotations == {"eks.amazonaws.com/role-arn" = "arn:aws:iam::123456789012:role/api"}

    # no serviceAccount → pods keep the namespace default, nothing is rendered
    plain = render(Workload {name = "api", image = "i"})[0]
    assert plain.spec.template.spec?.serviceAccountName == Undefined and plain.spec.template.spec?.automountServiceAccountToken == Undefined

    job = renderTask(Task {name = "migrate", image = "i", serviceAccount = {name = "migrator"}})
    assert [m.kind for m in job] == ["ServiceAccount", "Job"]
    assert job[1].spec.template.spec.serviceAccountName == "migrator"
}

# ── PodDisruptionBudget ──────────────────────────────────────────────────────
test_disruption_budget = lambda {
    out = render(Workload {name = "api", namespace = "zerg", image = "i", disruptionBudget = {maxUnavailable = "25%"}, scaler = {cpu = 70}})
    assert [m.kind for m in out] == ["Deployment", "Service", "PodDisruptionBudget", "ScaledObject"]
    pdb = out[2]
    assert pdb.spec.maxUnavailable == "25%" and pdb.spec?.minAvailable == Undefined
    assert pdb.spec.selector.matchLabels == {app = "api"}, "the same pods the Deployment selects"
}

# ── KEDA: TriggerAuthentication, auth refs, fallback, pause ──────────────────
test_scaler_auth = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
scaler:
  paused: true
  fallback: {replicas: 3}
  authentications:
    - name: prom
      secrets: [{parameter: bearerToken, name: prom-token, key: token}]
    - name: sqs
      podIdentity: aws
      identityId: arn:aws:iam::123456789012:role/keda
  triggers:
    - type: prometheus
      auth: prom
      metadata: {serverAddress: "http://prometheus:9090", query: up, threshold: "1", authModes: bearer}
    - type: aws-sqs-queue
      auth: sqs
      metadata: {queueURL: "https://sqs.eu-west-1.amazonaws.com/123456789012/q", queueLength: "5"}
    - type: kafka
      authenticationRef: {name: kafka-shared, kind: ClusterTriggerAuthentication}
      metadata: {topic: t, bootstrapServers: "kafka:9092", consumerGroup: g}
""")}
    out = render(w)
    assert [m.kind for m in out] == ["Deployment", "Service", "TriggerAuthentication", "TriggerAuthentication", "ScaledObject"], "auths before the ScaledObject that uses them"
    promAuth = out[2]
    assert promAuth.metadata.name == "zerg-api-prom" and promAuth.metadata.namespace == "zerg"
    assert _plain(promAuth.spec.secretTargetRef) == [{parameter = "bearerToken", name = "prom-token", key = "token"}]
    assert _plain(out[3].spec.podIdentity) == {provider = "aws", identityId = "arn:aws:iam::123456789012:role/keda"}
    so = out[4]
    assert so.metadata.annotations["autoscaling.keda.sh/paused"] == "true"
    assert so.spec.fallback.failureThreshold == 3 and so.spec.fallback.replicas == 3
    ts = so.spec.triggers
    assert ts[0].authenticationRef.name == "zerg-api-prom" and ts[1].authenticationRef.name == "zerg-api-sqs", "`auth` resolves to the rendered TriggerAuthentication"
    assert ts[2].authenticationRef.name == "kafka-shared" and ts[2].authenticationRef.kind == "ClusterTriggerAuthentication", "an existing auth passes through"
    assert all_true(["auth" not in t for t in ts]), "`auth` is this package's shorthand, never a KEDA field"
}

# ── KEDA ScaledJob: a Task driven by pending work ────────────────────────────
test_scaled_job = lambda {
    t = Task {**yaml.decode("""\
name: thumbnailer
namespace: media
image: i
backoffLimit: 2
successfulJobsHistoryLimit: 5
scaler:
  maxReplicas: 20
  strategy: accurate
  triggers:
    - type: rabbitmq
      metadata: {queueName: thumbs, mode: QueueLength, value: "10", hostFromEnv: AMQP_URL}
""")}
    out = renderTask(t)
    assert [m.kind for m in out] == ["ScaledJob"], "a scaler replaces the Job"
    sj = out[0]
    assert sj.apiVersion == "keda.sh/v1alpha1" and sj.metadata.name == "thumbnailer"
    assert sj.spec.minReplicaCount == 0 and sj.spec.maxReplicaCount == 20
    assert sj.spec.scalingStrategy.strategy == "accurate"
    assert sj.spec.successfulJobsHistoryLimit == 5 and sj.spec.failedJobsHistoryLimit == 1
    assert sj.spec.jobTargetRef.backoffLimit == 2
    job = renderTask(Task {**t, scaler = Undefined})[0]
    assert sj.spec.jobTargetRef.template.spec.containers[0].image == job.spec.template.spec.containers[0].image, "the ScaledJob runs the Job's own template"
    assert sj.spec.triggers[0].$type == "rabbitmq" and sj.spec.triggers[0].metadata.queueName == "thumbs"
}

# ── Monitoring: Prometheus Operator objects + Grafana dashboards ─────────────
test_monitoring = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
portName: web
metricsPath: /internal/metrics
monitoring:
  interval: 15s
  defaultRules: true
  rules:
    - alert: ZergApiErrors
      expr: sum(rate(http_requests_total{status=~"5.."}[5m])) > 1
      severity: critical
      runbookUrl: https://runbooks.example.com/errors
      labels: {team: zerg}
  dashboards:
    - name: overview
      folder: Zerg
      panels:
        - {title: RPS, expr: "sum(rate(http_requests_total[1m]))", unit: reqps}
    - name: imported
      json: '{"title": "hand-made"}'
""")}
    out = render(w)
    assert [m.kind for m in out] == ["Deployment", "Service", "ServiceMonitor", "PrometheusRule", "ConfigMap", "ConfigMap"], "${[m.kind for m in out]}"
    sm = out[2]
    assert sm.metadata.labels.release == "kube-prometheus-stack", "what kube-prometheus-stack's selectors match"
    assert sm.spec.selector.matchLabels == {app = "zerg-api"} and sm.spec.namespaceSelector.matchNames == ["zerg"]
    assert _plain(sm.spec.endpoints) == [{port = "web", path = "/internal/metrics", interval = "15s"}], "scrapes the named port + metricsPath"

    rules = out[3].spec.groups[0].rules
    assert [r.alert for r in rules] == ["AppTargetDown", "AppRestarting", "AppReplicasUnavailable", "ZergApiErrors"], "defaults first, then the workload's own"
    assert rules[0].expr == 'sum(up{namespace="zerg", job="zerg-api"}) == 0', "a ServiceMonitor's job is the Service name"
    assert rules[0].labels.severity == "critical" and rules[0].labels.app == "zerg-api"
    assert rules[3]["for"] == "5m" and rules[3].labels == {severity = "critical", app = "zerg-api", team = "zerg"}
    assert rules[3].annotations == {runbook_url = "https://runbooks.example.com/errors"}

    gen = out[4]
    assert gen.metadata.name == "zerg-api-dashboard-overview" and gen.metadata.namespace == "zerg"
    assert gen.metadata.labels.grafana_dashboard == "1" and gen.metadata.annotations == {grafana_folder = "Zerg"}
    d = json.decode(gen.data["zerg-api-overview.json"])
    assert d.uid == crypto.md5("zerg/zerg-api/overview"), "stable uid: a re-render updates the same dashboard"
    assert [p.title for p in d.panels] == ["Available replicas", "CPU (cores)", "Memory (working set)", "Container restarts", "Scrape targets up", "RPS"], "standard panels, then the workload's"
    assert d.panels[5].gridPos == {h = 8, w = 12, x = 12, y = 16} and d.panels[5].fieldConfig.defaults.unit == "reqps"
    assert all_true([p.datasource.uid == "\${datasource}" for p in d.panels]), "every panel follows the datasource variable"
    assert out[5].data["zerg-api-imported.json"] == '{"title": "hand-made"}', "json is shipped verbatim"

    # PodMonitor: no Service needed, and Prometheus names the job <ns>/<name>
    pm = render(Workload {name = "worker", namespace = "q", image = "i", service = False, monitoring = {kind = "PodMonitor", defaultRules = True}})
    assert [m.kind for m in pm] == ["Deployment", "PodMonitor", "PrometheusRule"]
    assert pm[1].spec.podMetricsEndpoints[0].port == "http"
    assert pm[2].spec.groups[0].rules[0].expr == 'sum(up{namespace="q", job="q/worker"}) == 0'

    # rules without a scrape: no monitor, and no alert on a scrape that does not exist
    ns = render(Workload {name = "w", namespace = "q", image = "i", monitoring = {scrape = False, defaultRules = True}})
    assert [m.kind for m in ns] == ["Deployment", "Service", "PrometheusRule"]
    assert [r.alert for r in ns[2].spec.groups[0].rules] == ["AppRestarting", "AppReplicasUnavailable"]
}

# ── Chaos Mesh: HTTP / IO / DNS / Time and the extra network actions ─────────
test_chaos_more_types = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
port: 3000
chaos:
  - {name: abort, type: http-abort, path: /api/*, method: POST}
  - {name: slow-http, type: http-delay, latency: 2s, httpTarget: Response, port: 9090}
  - {name: disk, type: io-latency, volumePath: /data, latency: 50ms, percent: 25, methods: [read]}
  - {name: eio, type: io-fault, volumePath: /data, errno: 28}
  - {name: dns, type: dns-random, patterns: ["*.svc"]}
  - {name: clock, type: time-skew, timeOffset: "2h", clockIds: [CLOCK_MONOTONIC]}
  - {name: narrow, type: bandwidth, rate: 10kbps}
  - {name: bits, type: corrupt, corrupt: "5", correlation: "25"}
  - {name: dup, type: duplicate}
""")}
    faults = render(w)[2::]
    assert [f.kind for f in faults] == ["HTTPChaos", "HTTPChaos", "IOChaos", "IOChaos", "DNSChaos", "TimeChaos", "NetworkChaos", "NetworkChaos", "NetworkChaos"]
    assert all_true([_plain(f.spec.selector) == {namespaces = ["zerg"], labelSelectors = {app = "zerg-api"}} for f in faults]), "every new kind is pinned to the workload too"

    abort = faults[0].spec
    assert abort.abort == True and abort.target == "Request" and abort.port == 3000, "an HTTP fault defaults to the workload's port"
    assert abort.path == "/api/*" and abort.method == "POST" and abort?.delay == Undefined
    slow = faults[1].spec
    assert slow.delay == "2s" and slow.target == "Response" and slow.port == 9090 and slow?.abort == Undefined
    disk = faults[2].spec
    assert disk.action == "latency" and disk.delay == "50ms" and disk.volumePath == "/data" and disk.percent == 25 and disk.methods == ["read"]
    eio = faults[3].spec
    assert eio.action == "fault" and eio.errno == 28 and eio?.delay == Undefined
    assert faults[4].spec.action == "random" and faults[4].spec.patterns == ["*.svc"]
    assert faults[5].spec.timeOffset == "2h" and faults[5].spec.clockIds == ["CLOCK_MONOTONIC"]
    assert faults[6].spec.action == "bandwidth" and _plain(faults[6].spec.bandwidth) == {rate = "10kbps", buffer = 10000, limit = 20971520}
    assert _plain(faults[7].spec.corrupt) == {corrupt = "5", correlation = "25"}
    assert _plain(faults[8].spec.duplicate) == {duplicate = "10"}

    # A Schedule embeds each kind under its own field
    sched = render(Workload {name = "a", namespace = "n", image = "i", chaos = [
        {name = "h", $type = "http-delay", schedule = "0 * * * *"}
        {name = "io", $type = "io-fault", volumePath = "/tmp", schedule = "0 * * * *"}
        {name = "t", $type = "time-skew", schedule = "0 * * * *"}
    ]})[2::]
    assert [[s.spec.$type] + [k for k in ["httpChaos", "ioChaos", "timeChaos"] if k in _plain(s.spec)] for s in sched] == [["HTTPChaos", "httpChaos"], ["IOChaos", "ioChaos"], ["TimeChaos", "timeChaos"]]
    assert sched[0].spec.httpChaos.port == 8080
}

# ── Litmus: ChaosEngine + ChaosExperiment + runner RBAC per fault ────────────
_litmusKinds = ["ServiceAccount", "Role", "RoleBinding", "Role", "RoleBinding", "ChaosExperiment", "ChaosEngine"]

# The env the ChaosEngine overrides the definition's defaults with.
_engineEnv = lambda engine -> {str:str} {
    {e.name: e.value for e in engine.spec.experiments[0].spec.components.env}
}

test_litmus_per_fault = lambda {
    w = Workload {**yaml.decode("""\
name: zerg-api
namespace: zerg
image: yurikrupnik/zerg-api:latest
port: 3000
chaos:
  - {name: kill, provider: litmus, type: pod-kill}
  - {name: restart, provider: litmus, type: container-kill, containerNames: [zerg-api]}
  - {name: slow, provider: litmus, type: delay, latency: 200ms, jitter: 50ms, correlation: "25", externalTargets: [postgres-rw.dbs.svc, 10.0.0.0/8], duration: 1m30s}
  - {name: lossy, provider: litmus, type: loss, loss: "30", mode: all}
  - {name: bits, provider: litmus, type: corrupt, corrupt: "5"}
  - {name: dup, provider: litmus, type: duplicate, mode: fixed-percent, value: "50"}
  - {name: narrow, provider: litmus, type: bandwidth, rate: 10kbps}
  - {name: cut, provider: litmus, type: partition, direction: both, mode: all, externalTargets: [postgres-rw.dbs.svc]}
  - {name: cpu, provider: litmus, type: cpu, workers: 2, load: 80, duration: 2m}
  - {name: mem, provider: litmus, type: memory, size: 1GB}
  - {name: slow-http, provider: litmus, type: http-delay, latency: 2s}
  - {name: abort, provider: litmus, type: http-abort, port: 9090}
  - {name: dns, provider: litmus, type: dns-error, patterns: [postgres-rw.dbs.svc]}
  - {name: dns-wild, provider: litmus, type: dns-error, patterns: ["*.dbs.svc"]}
""")}
    out = render(w)[2::]
    assert [o.kind for o in out] == _litmusKinds * 14, "seven objects per Litmus fault, after the core resources"
    engines = [o for o in out if o.kind == "ChaosEngine"]
    defs = [o for o in out if o.kind == "ChaosExperiment"]
    assert [d.metadata.labels.name for d in defs] == ["pod-delete", "container-kill", "pod-network-latency", "pod-network-loss", "pod-network-corruption", "pod-network-duplication", "pod-network-rate-limit", "pod-network-partition", "pod-cpu-hog", "pod-memory-hog", "pod-http-latency", "pod-http-reset-peer", "pod-dns-error", "pod-dns-error"], "the chaos-charts experiment per fault type"
    assert [e.metadata.name for e in engines] == ["zerg-zerg-api-" + n for n in ["kill", "restart", "slow", "lossy", "bits", "dup", "narrow", "cut", "cpu", "mem", "slow-http", "abort", "dns", "dns-wild"]], "engines carry the target namespace: everything lives in one `litmus` namespace"
    assert all_true([engines[i].spec.experiments[0].name == defs[i].metadata.name for i in range(len(engines))]), "each engine runs its own definition"
    assert all_true([d.metadata.name.startswith(d.metadata.labels.name + "-") and len(d.metadata.name) == len(d.metadata.labels.name) + 9 for d in defs]), "definitions are <experiment>-<8-char hash>"
    assert defs[12].metadata.name != defs[13].metadata.name, "two faults of one type get two definitions"
    assert all_true([d.spec.definition.image == "litmuschaos.docker.scarf.sh/litmuschaos/go-runner:3.31.0" for d in defs]), "the go-runner pinned with the operator"
    assert defs[2].spec.definition.args == ["-c", "./experiments -name pod-network-latency"]
    assert all_true([_plain(e.spec.appinfo) == {appns = "zerg", applabel = "app=zerg-api", appkind = "deployment"} for e in engines]), "every engine pinned to the workload's pods"
    assert all_true([e.metadata.namespace == "litmus" and e.spec.chaosServiceAccount == e.metadata.name and e.spec.jobCleanUpPolicy == "delete" for e in engines])
    assert all_true([e.spec?.engineState == Undefined for e in engines]), "engineState is the operator's to flip: re-asserting active would restart a finished run"
    env = [_engineEnv(e) for e in engines]
    assert env[0] == {TOTAL_CHAOS_DURATION = "1", CHAOS_INTERVAL = "1", FORCE = "true"}, "pod-delete: one forced kill, mode one = no PODS_AFFECTED_PERC: ${env[0]}"
    assert env[1] == {TOTAL_CHAOS_DURATION = "1", TARGET_CONTAINER = "zerg-api", CHAOS_INTERVAL = "1"}, "${env[1]}"
    assert env[2] == {TOTAL_CHAOS_DURATION = "90", NETWORK_LATENCY = "200", JITTER = "50", CORRELATION = "25", DESTINATION_IPS = "10.0.0.0/8", DESTINATION_HOSTS = "postgres-rw.dbs.svc"}, "${env[2]}"
    assert env[3] == {TOTAL_CHAOS_DURATION = "30", PODS_AFFECTED_PERC = "100", NETWORK_PACKET_LOSS_PERCENTAGE = "30"}, "mode all = 100%: ${env[3]}"
    assert env[4] == {TOTAL_CHAOS_DURATION = "30", NETWORK_PACKET_CORRUPTION_PERCENTAGE = "5"}
    assert env[5] == {TOTAL_CHAOS_DURATION = "30", PODS_AFFECTED_PERC = "50", NETWORK_PACKET_DUPLICATION_PERCENTAGE = "10"}
    assert env[6] == {TOTAL_CHAOS_DURATION = "30", NETWORK_BANDWIDTH = "10kbps", BURST = "10000", LIMIT = "20971520"}, "the same tc tbf arguments as Chaos Mesh"
    assert env[7] == {TOTAL_CHAOS_DURATION = "30", PODS_AFFECTED_PERC = "100", POLICY_TYPES = "all", DESTINATION_HOSTS = "postgres-rw.dbs.svc"}
    assert env[8] == {TOTAL_CHAOS_DURATION = "120", CPU_CORES = "2", CPU_LOAD = "80"}
    assert env[9] == {TOTAL_CHAOS_DURATION = "30", MEMORY_CONSUMPTION = "1024", NUMBER_OF_WORKERS = "1"}
    assert env[10] == {TOTAL_CHAOS_DURATION = "30", LATENCY = "2000", TARGET_SERVICE_PORT = "3000"}, "an HTTP fault defaults to the workload's port"
    assert env[11] == {TOTAL_CHAOS_DURATION = "30", RESET_TIMEOUT = "0", TARGET_SERVICE_PORT = "9090"}
    assert env[12] == {TOTAL_CHAOS_DURATION = "30", MATCH_SCHEME = "exact", TARGET_HOSTNAMES = json.encode(["postgres-rw.dbs.svc"])}
    assert env[13] == {TOTAL_CHAOS_DURATION = "30", MATCH_SCHEME = "substring", TARGET_HOSTNAMES = json.encode([".dbs.svc"])}, "a leading/trailing wildcard is a substring match"
}

test_litmus_rbac = lambda {
    out = render(Workload {name = "api", namespace = "zerg", image = "i", chaos = [
        {name = "kill", provider = "litmus", $type = "pod-kill"}
        {name = "cut", provider = "litmus", $type = "partition", mode = "all"}
        {name = "slow", provider = "litmus", $type = "delay"}
    ]})[2::]
    kill = out[0:7]
    assert [[o.kind, o.metadata.namespace, o.metadata.name] for o in kill[0:5]] == [["ServiceAccount", "litmus", "zerg-api-kill"], ["Role", "litmus", "zerg-api-kill"], ["RoleBinding", "litmus", "zerg-api-kill"], ["Role", "zerg", "zerg-api-kill"], ["RoleBinding", "zerg", "zerg-api-kill"]], "runner identity in `litmus`, only a Role + binding in the target"
    assert all_true([_plain(b.subjects) == [{kind = "ServiceAccount", name = "zerg-api-kill", namespace = "litmus"}] for b in [kill[2], kill[4]]]), "both bindings name the runner SA in `litmus`"
    runner = {r.resources[0]: r.verbs for r in kill[1].rules}
    assert "create" in runner["pods"] and "create" in runner["jobs"] and "create" in runner["chaosengines"], "runner, Job and helper pods are created in `litmus`"
    target = lambda objs -> {str:} {
        {r.resources[0]: r.verbs for r in objs[3].rules}
    }
    assert target(kill)["pods"] == ["get", "list", "delete", "deletecollection"], "only pod-delete may delete target pods"
    assert target(out[14:21])["pods"] == ["get", "list"] and "networkpolicies" not in target(out[14:21]), "a delay touches nothing in the target namespace"
    assert target(out[7:14])["networkpolicies"] == ["create", "delete", "get", "list"] and target(out[7:14])["pods"] == ["get", "list"], "partition fences with a NetworkPolicy"
    assert "deployments" in target(kill) and "rollouts" not in target(kill), "owner lookup up to the Deployment; Argo Rollouts only when the target kind is rollout"

    # The renderer the other packages call: any target, any engine name.
    objs = litmusObjects(Fault {name = "x", provider = "litmus", $type = "pod-kill"}, LitmusTarget {namespace = "dbs", labels = {"cnpg.io/cluster" = "pg"}, kind = "statefulset"}, "game-day-x", {}, False)
    assert objs[6].spec.engineState == "stop", "paused → the engine is rendered stopped"
    assert objs[6].spec.appinfo.applabel == "cnpg.io/cluster=pg" and objs[6].spec.appinfo.appkind == "statefulset"
}

# Mixed providers in one workload: each fault renders for its own operator.
test_litmus_mixed = lambda {
    out = render(Workload {name = "api", namespace = "zerg", image = "i", chaos = [
        {name = "a", $type = "pod-kill"}
        {name = "b", provider = "litmus", $type = "pod-kill"}
        {name = "c", $type = "delay"}
    ]})
    assert [o.kind for o in out] == ["Deployment", "Service", "PodChaos"] + _litmusKinds + ["NetworkChaos"]
}

# What Litmus cannot do is rejected at render time, not approximated. Called
# last at the bottom of this file, after test_route_rejected: a check failure
# runtime.catch swallowed is still reported by the next schema whose check
# calls a builtin (kcl 0.13), so nothing may be instantiated after one.
test_litmus_rejected = lambda {
    _bad = [
        {$type = "pod-failure"}
        {$type = "io-latency", volumePath = "/data"}
        {$type = "io-fault", volumePath = "/data"}
        {$type = "dns-random"}
        {$type = "time-skew"}
        {$type = "pod-kill", schedule = "0 * * * *"}
        {$type = "pod-kill", mode = "fixed", value = "2"}
        {$type = "pod-kill", mode = "random-max-percent", value = "50"}
        {$type = "delay", duration = "500ms"}
        {$type = "delay", latency = "1.5s"}
        {$type = "delay", jitter = "10us"}
        {$type = "loss", correlation = "0.5"}
        {$type = "memory"}
        {$type = "memory", size = "50%"}
        {$type = "http-delay", path = "/api"}
        {$type = "http-abort", method = "POST"}
        {$type = "dns-error", patterns = ["a*b.svc"]}
        {$type = "partition"}
    ]
    # the types Litmus lacks stay valid for Chaos Mesh
    assert len([Fault {name = "x", **b} for b in _bad[0:5]]) == 5
    assert all_true([runtime.catch(lambda {
        Fault {name = "x", provider = "litmus", **b}
    }) != "" for b in _bad]), "every shape Litmus cannot express is rejected"
    assert runtime.catch(lambda {
        LitmusTarget {namespace = "n", labels = {a = "1", b = "2"}}
    }) != "", "two labels: Litmus would OR them"
    assert runtime.catch(lambda {
        litmusObjects(Fault {name = "x", provider = "litmus", $type = "pod-kill"}, LitmusTarget {namespace = "dbs", labels = {a = "b"}}, "x" * 64, {})
    }) != "", "an engine name longer than a DNS label"
    assert runtime.catch(lambda {
        litmusObjects(Fault {name = "x", $type = "pod-kill"}, LitmusTarget {namespace = "dbs", labels = {a = "b"}}, "x", {})
    }) != "", "a chaos-mesh fault"
    assert runtime.catch(lambda {
        litmusObjects(Fault {name = "x", provider = "litmus", $type = "http-delay"}, LitmusTarget {namespace = "dbs", labels = {a = "b"}}, "x", {})
    }) != "", "an HTTP fault with no port"
}

# ── Dapr sidecar ─────────────────────────────────────────────────────────────
test_dapr_defaults = lambda {
    w = Workload {
        name = "orders"
        namespace = "zerg"
        image = "i"
        port = 8081
        prometheus = False
        readinessProbe = {$type = "http", path = "/healthz", port = 8081}
        dapr = {}
    }
    dep = render(w)[0]
    ann = dep.spec.template.metadata.annotations
    assert _plain(ann) == {
        "dapr.io/enabled" = "true"
        "dapr.io/app-id" = "orders"
        "dapr.io/app-port" = "8081"
        "dapr.io/app-protocol" = "http"
        "dapr.io/log-as-json" = "true"
        "dapr.io/sidecar-cpu-request" = "100m"
        "dapr.io/sidecar-memory-request" = "64Mi"
        "dapr.io/sidecar-memory-limit" = "256Mi"
        "dapr.io/enable-app-health-check" = "true"
        "dapr.io/app-health-check-path" = "/healthz"
    }, "dapr defaults: ${ann}"
    # Pod Security `restricted` admits the injected sidecar only through the pod-level profile
    assert dep.spec.template.spec.securityContext.seccompProfile.$type == "RuntimeDefault"
    # no dapr → no dapr annotation at all
    plain = render(Workload {name = "orders", image = "i"})[0]
    assert not any_true(["dapr.io/" in k for k in plain.spec.template.metadata.annotations]), "no dapr: block → no sidecar"
}

test_dapr_overrides = lambda {
    w = Workload {
        name = "orders"
        image = "i"
        # a probe on another port is not one daprd can reach on the app port
        livenessProbe = {$type = "http", path = "/live", port = 9000}
        podAnnotations = {"dapr.io/log-level" = "debug"}
        dapr = {appId = "orders-v2", maxConcurrency = 5, config = "tracing", sidecarResources = {requests = {memory = "32Mi"}, limits = {cpu = "1"}}}
    }
    ann = render(w)[0].spec.template.metadata.annotations
    assert ann["dapr.io/app-id"] == "orders-v2"
    assert ann["dapr.io/app-max-concurrency"] == "5" and ann["dapr.io/config"] == "tracing"
    assert ann["dapr.io/sidecar-memory-request"] == "32Mi" and ann["dapr.io/sidecar-cpu-limit"] == "1"
    assert ann?["dapr.io/sidecar-cpu-request"] == Undefined, "sidecarResources replaces the defaults"
    assert ann?["dapr.io/enable-app-health-check"] == Undefined, "probe on another port → no app health check"
    assert ann["dapr.io/log-level"] == "debug", "podAnnotations still pass through"
    assert ann["prometheus.io/scrape"] == "true", "prometheus annotations sit next to dapr's"

    grpc = render(Workload {name = "g", image = "i", readinessProbe = {$type = "http", path = "/ready", port = 8080}, dapr = {protocol = "grpc"}})[0].spec.template.metadata.annotations
    assert grpc["dapr.io/app-protocol"] == "grpc"
    assert grpc?["dapr.io/enable-app-health-check"] == Undefined, "daprd health-checks a grpc app over grpc, not an http path"
    off = render(Workload {name = "o", image = "i", readinessProbe = {$type = "http", path = "/ready", port = "http"}, dapr = {appHealthCheck = False}})[0].spec.template.metadata.annotations
    assert off?["dapr.io/enable-app-health-check"] == Undefined
}

_daprWorkload = lambda dapr: {str:} {
    Workload {name = "orders", image = "i", dapr = dapr}
}

test_dapr_rejected = lambda {
    assert runtime.catch(lambda {
        _daprWorkload({protocol = "tcp"})
    }), "app protocol other than http / grpc is rejected"
}

test_dapr_rejected_app_id = lambda {
    assert runtime.catch(lambda {
        _daprWorkload({appId = "Orders_v2"})
    }), "app-id that is not a DNS label is rejected"
}

# Dapr's own checks are exercised on a bare Dapr: a check failing inside a
# schema nested in Workload survives runtime.catch in KCL 0.13 and fails the
# rest of the module.
test_dapr_rejected_sidecar_resources = lambda {
    assert runtime.catch(lambda {
        Dapr {sidecarResources = {requests = {"ephemeral-storage" = "1Gi"}}}
    }), "a resource the injector has no annotation for is rejected"
    assert runtime.catch(lambda {
        Dapr {maxConcurrency = 0}
    }), "zero concurrency is rejected"
}

test_dapr_example = lambda {
    r = Release {**yaml.decode(file.read("examples/values-dapr-worker.yaml"))}
    out = renderRelease(r)
    assert [m.kind for m in out] == ["ServiceAccount", "Deployment", "ScaledObject", "ConfigMap"], "dapr worker example: ${[m.kind for m in out]}"
    ann = out[1].spec.template.metadata.annotations
    assert ann["dapr.io/enabled"] == "true" and ann["dapr.io/app-id"] == "zerg-orders-worker" and ann["dapr.io/app-port"] == "8080"
    assert ann["dapr.io/app-max-concurrency"] == "10" and ann["dapr.io/app-health-check-path"] == "/healthz"
}

# ── HTTPRoute (Gateway API) ──────────────────────────────────────────────────
_routeWorkload = lambda route: {str:} {
    Workload {name = "api", namespace = "zerg", image = "i", port = 8080, route = route}
}

test_route_single_rule = lambda {
    out = render(_routeWorkload({
        hostnames = ["api.example.org"]
        gateway = {name = "main-gateway", namespace = "gateway", sectionName = "https"}
        timeout = "30s"
        requestHeaders = {set = {"X-Env" = "dev"}, remove = ["X-Debug"]}
    }))
    assert [m.kind for m in out] == ["Deployment", "Service", "HTTPRoute"], "${[m.kind for m in out]}"
    r = out[2]
    assert r.apiVersion == "gateway.networking.k8s.io/v1"
    assert r.metadata.name == "api" and r.metadata.namespace == "zerg" and r.metadata.labels["app.kubernetes.io/name"] == "api"
    assert r.spec.hostnames == ["api.example.org"]
    p = r.spec.parentRefs[0]
    assert p.name == "main-gateway" and p.namespace == "gateway" and p.sectionName == "https" and p?.port == Undefined
    first = r.spec.rules[0]
    assert len(r.spec.rules) == 1
    assert first.matches[0].path.$type == "PathPrefix" and first.matches[0].path.value == "/"
    assert first.backendRefs[0].name == "api" and first.backendRefs[0].port == 8080, "the Service the workload renders"
    assert first.timeouts.request == "30s"
    f = first.filters[0]
    assert f.$type == "RequestHeaderModifier"
    assert f.requestHeaderModifier.set[0].name == "X-Env" and f.requestHeaderModifier.set[0].value == "dev"
    assert f.requestHeaderModifier.remove == ["X-Debug"] and f.requestHeaderModifier?.add == Undefined
}

test_route_rules_take_route_defaults = lambda {
    r = render(_routeWorkload({
        hostnames = ["api.example.org"]
        gateway = {name = "gw"}
        port = 9090
        timeout = "10s"
        rules = [{path = "/api"}, {path = "/healthz", pathType = "Exact", port = 8081, timeout = "1s"}]
    }))[2]
    rules = r.spec.rules
    assert len(rules) == 2
    assert rules[0].matches[0].path.value == "/api" and rules[0].backendRefs[0].port == 9090 and rules[0].timeouts.request == "10s"
    assert rules[1].matches[0].path.$type == "Exact" and rules[1].backendRefs[0].port == 8081 and rules[1].timeouts.request == "1s"
    assert rules[0]?.filters == Undefined, "no header filter unless asked"
    assert r.spec.parentRefs[0]?.sectionName == Undefined and r.spec.parentRefs[0]?.namespace == Undefined
}

test_route_https_redirect = lambda {
    out = render(_routeWorkload({
        hostnames = ["api.example.org"]
        gateway = {name = "gw", namespace = "edge", sectionName = "https", port = 443}
        httpsRedirect = {}
    }))
    assert [m.kind for m in out] == ["Deployment", "Service", "HTTPRoute", "HTTPRoute"]
    assert out[2].spec.parentRefs[0].port == 443
    rd = out[3]
    assert rd.metadata.name == "api-https-redirect" and rd.spec.hostnames == ["api.example.org"]
    p = rd.spec.parentRefs[0]
    assert p.sectionName == "http" and p.namespace == "edge" and p?.port == Undefined, "the plain-HTTP listener, not the HTTPS one's port"
    f = rd.spec.rules[0].filters[0]
    assert f.$type == "RequestRedirect" and f.requestRedirect.scheme == "https" and f.requestRedirect.statusCode == 301
    assert rd.spec.rules[0]?.backendRefs == Undefined, "a redirect sends nothing to the workload"
}

test_route_enabled_flag_per_env = lambda {
    base = {workload = {name = "api", image = "i", route = {hostnames = ["api.example.org"], gateway = {name = "gw"}}}}
    off = mergeValues(base, {workload = {route = {enabled = False}}})
    assert [m.kind for m in renderRelease(Release {**base})] == ["Deployment", "Service", "HTTPRoute"]
    assert [m.kind for m in renderRelease(Release {**off})] == ["Deployment", "Service"], "an overlay turns the route off"
    assert [m.kind for m in render(Workload {name = "api", image = "i", route = {enabled = False}})] == ["Deployment", "Service"], "disabled needs no hostnames or gateway"
}

# The checks are exercised on bare schemas (see test_dapr_rejected_sidecar_resources).
test_route_rejected = lambda {
    assert runtime.catch(lambda {
        HttpRoute {gateway = {name = "gw"}}
    }), "an enabled route without hostnames"
    assert runtime.catch(lambda {
        HttpRoute {hostnames = ["a.example.org"]}
    }), "an enabled route without a gateway"
    assert runtime.catch(lambda {
        HttpRoute {hostnames = ["a.example.org"], gateway = {name = "gw"}, path = "/x", rules = [{path = "/y"}]}
    }), "route-level path next to rules"
    assert runtime.catch(lambda {
        HttpRoute {hostnames = ["a.example.org"], gateway = {name = "gw"}, httpsRedirect = {}}
    }), "a redirect without an HTTPS listener to keep the route on"
    assert runtime.catch(lambda {
        HttpRoute {hostnames = ["a.example.org"], gateway = {name = "gw", sectionName = "http"}, httpsRedirect = {}}
    }), "the route on the listener that redirects"
    assert runtime.catch(lambda {
        HeaderFilter {}
    }), "a header filter that does nothing"
    assert runtime.catch(lambda {
        HeaderFilter {set = {"X-A" = "1"}, remove = ["X-A"]}
    }), "a header both set and removed"
}

# invalid faults (no namespace, fixed mode without value, delay with direction
# from, duplicate names, io-* without volumePath) and the other invalid shapes
# (monitoring without namespace, ServiceMonitor with service: false, RBAC rules
# without namespace, fallback next to cpu/memory, an `auth` naming no
# authentication, a Task with both schedule and scaler) are rejected by the
# schema `check` blocks.
test_backend()
test_frontend()
test_task_job()
test_task_cronjob()
test_helpers()
test_values_from_yaml()
test_examples_valid()
test_release()
test_merge_values()
test_scaler_cpu_mem()
test_scaler_scale_to_zero()
test_scaler_paths()
test_replicas_ownership()
test_chaos_one_shot()
test_chaos_schedule()
test_chaos_release_order()
test_catalog_component()
test_catalog_task_type()
test_catalog_apis()
test_catalog_absent()
test_service_account()
test_disruption_budget()
test_scaler_auth()
test_scaled_job()
test_monitoring()
test_chaos_more_types()
test_litmus_per_fault()
test_litmus_rbac()
test_litmus_mixed()
test_dapr_defaults()
test_dapr_overrides()
test_dapr_rejected()
test_dapr_rejected_app_id()
test_dapr_rejected_sidecar_resources()
test_dapr_example()
test_route_single_rule()
test_route_rules_take_route_defaults()
test_route_https_redirect()
test_route_enabled_flag_per_env()
test_route_rejected()
test_litmus_rejected()
