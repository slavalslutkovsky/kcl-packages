# Tests for the app package: Workload (BE/FE) + Task (CLI Job/CronJob) + helpers.
# Run: kcl test   (asserts logical contracts of the rendered manifests)
import yaml
import file

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
        hpa = {minReplicas = 1, maxReplicas = 10, cpu = 70, memory = 80}
    }
    out = render(w)
    assert len(out) == 3, "BE renders Deployment + Service + HPA"
    dep = out[0]
    svc = out[1]
    hpa = out[2]
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
    assert hpa.kind == "HorizontalPodAutoscaler"
    assert hpa.spec.minReplicas == 1 and hpa.spec.maxReplicas == 10
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
    assert len(out) == 2, "FE renders Deployment + Service (no HPA)"
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
hpa:
  minReplicas: 2
  maxReplicas: 8
""")
    w = Workload {**_beValues}
    out = render(w)
    assert len(out) == 3, "values.yaml-driven BE → Deployment + Service + HPA"
    assert out[0].metadata.name == "zerg-api"
    assert out[0].spec.template.spec.containers[0].envFrom[1].secretRef.name == "zerg-api-secrets"
    assert out[2].spec.minReplicas == 2 and out[2].spec.maxReplicas == 8

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
    assert [m.kind for m in beOut] == ["Deployment", "Service", "HorizontalPodAutoscaler", "ConfigMap", "ExternalSecret"], "backend example → Deployment + Service + HPA + ConfigMap + ExternalSecret"
    assert be.workload.name == "zerg-api" and be.workload.prometheus == True
    assert beOut[3].metadata.name == "zerg-api-config", "config → <name>-config ConfigMap"
    assert beOut[4].metadata.name == "zerg-api-secrets", "externalSecret → <name>-secrets"

    fe = Release {**yaml.decode(file.read("examples/values-frontend.yaml"))}
    assert [m.kind for m in renderRelease(fe)] == ["Deployment", "Service"], "frontend example → Deployment + Service"
    assert fe.workload.prometheus == False and fe.workload.runAsGroup == 101

    cli = Release {**yaml.decode(file.read("examples/values-cli.yaml"))}
    assert renderRelease(cli)[0].kind == "Job", "cli example (no schedule) → Job"
    assert cli.task.command == ["/app/migrate"]

    ch = Release {**yaml.decode(file.read("examples/values-chaos.yaml"))}
    assert [m.kind for m in renderRelease(ch)] == ["Deployment", "Service", "HorizontalPodAutoscaler", "Schedule", "NetworkChaos", "NetworkChaos", "NetworkChaos", "Schedule", "StressChaos"], "chaos example → core + one Chaos Mesh object per fault"

    wk = Release {**yaml.decode(file.read("examples/values-worker.yaml"))}
    wkOut = renderRelease(wk)
    assert [m.kind for m in wkOut] == ["Deployment", "ScaledObject", "ConfigMap"], "worker example → Deployment (no Service) + KEDA ScaledObject + ConfigMap"
    assert wkOut[0].spec?.replicas == Undefined, "worker Deployment leaves replicas to KEDA"
    assert wkOut[1].spec.minReplicaCount == 0 and wkOut[1].spec.triggers[0].$type == "nats-jetstream"
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
  hpa:
    minReplicas: 1
    maxReplicas: 10
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
    assert kinds == ["Deployment", "Service", "HorizontalPodAutoscaler", "ConfigMap", "ExternalSecret"], "release → 5 resources in order: ${kinds}"
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
  hpa:
    minReplicas: 1
    maxReplicas: 5
config:
  PORT: "8080"
  OAUTH_AUTO_LINK: "true"
  CORS: localhost
""")
    _prod = yaml.decode("""\
workload:
  hpa:
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
    assert m.workload.hpa.minReplicas == 1, "deep-nested base kept"
    assert m.workload.hpa.maxReplicas == 20, "deep-nested overlay wins"
    # merged result still builds a valid, type-checked Release
    r = Release {**m}
    out = renderRelease(r)
    assert out[2].spec.maxReplicas == 20, "HPA reflects prod overlay"
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

test_scaler_or_hpa_valid_paths = lambda {
    # both single-choice paths render their respective autoscaler
    wh = Workload {name = "x", image = "i", port = 8080, hpa = {}}
    assert [m.kind for m in render(wh)][2] == "HorizontalPodAutoscaler", "hpa path"
    ws = Workload {name = "x", image = "i", port = 8080, scaler = {cpu = 70}}
    assert [m.kind for m in render(ws)][2] == "ScaledObject", "scaler path"
    # idleReplicas → idleReplicaCount (0 is a real value, not "unset")
    wi = Workload {name = "x", image = "i", port = 8080, scaler = {cpu = 70, minReplicas = 1, idleReplicas = 0}}
    assert render(wi)[2].spec.idleReplicaCount == 0, "idleReplicas 0 is emitted"
}

# mutual exclusion (hpa AND scaler) is enforced by the schema `check` block.

# ── Deployment omits spec.replicas when autoscaled (GitOps/Flagger safe) ──────
test_replicas_ownership = lambda {
    # no autoscaler → replicas present (fixed count, e.g. frontend)
    plain = Workload {name = "web", image = "nginx", port = 8080, replicas = 2}
    dep0 = render(plain)[0]
    assert dep0.spec.replicas == 2, "no autoscaler → spec.replicas set"
    # HPA → replicas omitted (HPA owns it)
    wh = Workload {name = "api", image = "i", port = 8080, hpa = {}}
    deph = render(wh)[0]
    assert deph.spec?.replicas == Undefined, "hpa → spec.replicas omitted"
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

# invalid faults (no namespace, fixed mode without value, delay with direction
# from, duplicate names) are rejected by the schema `check` blocks.
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
test_scaler_or_hpa_valid_paths()
test_replicas_ownership()
test_chaos_one_shot()
test_chaos_schedule()
test_chaos_release_order()
