# Tests for the manager package: Flux dependencies, cert-manager issuers,
# cluster-scope chaos, Workflows.
# Run: kcl test
import yaml
import file
import app.lib as app

_kinds = lambda items: [any] -> [str] {
    [m.kind for m in items]
}
_named = lambda items: [any], name: str -> any {
    [t for t in items if t.name == name][0]
}

# ── Dependencies → HelmRepository + HelmRelease per chart ─────────────────────
test_dependencies = lambda {
    m = Manager {**yaml.decode("""\
name: platform
role: manager
dependencies:
  - name: chaos-mesh
    type: application
    repo: https://charts.chaos-mesh.org
    version: 2.8.4
    values:
      dashboard: {create: false}
  - name: kube-prometheus-stack
    type: application
    repo: oci://ghcr.io/prometheus-community/charts
    chart: kube-prometheus-stack
    namespace: monitoring
    dependsOn: [chaos-mesh]
    interval: 1h
""")}
    out = render(m)
    assert _kinds(out) == ["HelmRepository", "HelmRepository", "HelmRelease", "HelmRelease"], "one repo + one release per dependency, repos first: ${_kinds(out)}"
    assert all_true([o.metadata.namespace == "flux-system" for o in out]), "Flux objects live in the manager namespace"
    assert all_true([o.metadata.labels["app.kubernetes.io/part-of"] == "platform" for o in out])
    assert all_true([o.metadata.labels["platform.example.org/type"] == "application" for o in out]), "type → label on the repo and the release"

    repo = out[0]
    assert repo.spec.url == "https://charts.chaos-mesh.org" and repo.spec?.$type == Undefined, "https index → default type"
    oci = out[1]
    assert oci.spec.$type == "oci" and oci.spec.interval == "1h", "oci:// repo → type oci"

    hr = out[2]
    assert hr.spec.releaseName == "chaos-mesh" and hr.spec.targetNamespace == "chaos-mesh", "namespace defaults to the name"
    assert hr.spec.chart.spec.chart == "chaos-mesh" and hr.spec.chart.spec.version == "2.8.4"
    assert hr.spec.chart.spec.sourceRef.kind == "HelmRepository" and hr.spec.chart.spec.sourceRef.name == "chaos-mesh"
    assert hr.spec.install.createNamespace == True
    assert hr.spec.values.dashboard.create == False
    assert "chartRef" not in hr.spec, "the None that satisfied has(chart) != has(chartRef) must not be emitted"
    assert "dependsOn" not in hr.spec

    kps = out[3]
    assert kps.spec.targetNamespace == "monitoring"
    assert kps.spec.chart.spec.version == "*", "no version → Flux default (latest)"
    assert len(kps.spec.dependsOn) == 1 and kps.spec.dependsOn[0].name == "chaos-mesh" and kps.spec.dependsOn[0].namespace == "flux-system", "dependsOn → HelmRelease dependency edge"
    assert "values" not in kps.spec
}

# Beyond the sugar, a Dependency carries the Flux objects' own fields, typed by
# the generated CRD schemas; the manager's install defaults survive the merge.
test_dependency_flux_fields = lambda {
    m = Manager {**yaml.decode("""\
role: manager
dependencies:
  - name: kube-prometheus-stack
    type: application
    repo: oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts
    provider: aws
    secretRef: {name: ecr-pull}
    valuesFrom:
      - {kind: Secret, name: grafana-admin, valuesKey: password, targetPath: grafana.adminPassword}
    install: {crds: CreateReplace, remediation: {retries: 5}}
    upgrade: {crds: CreateReplace, remediation: {retries: 3, strategy: rollback}}
    driftDetection: {mode: enabled, ignore: [{paths: [/spec/replicas]}]}
    postRenderers:
      - kustomize:
          patches:
            - target: {kind: Deployment, name: grafana}
              patch: |
                - op: add
                  path: /metadata/labels/team
                  value: sre
""")}
    out = render(m)
    repo = out[0]
    assert repo.spec.$type == "oci" and repo.spec.provider == "aws" and repo.spec.secretRef.name == "ecr-pull"

    hr = out[1]
    assert hr.spec.install.createNamespace == True and hr.spec.install.crds == "CreateReplace", "user install merged over the defaults"
    assert hr.spec.install.remediation.retries == 5, "user install wins where both set"
    assert hr.spec.upgrade.remediation.strategy == "rollback"
    assert hr.spec.driftDetection.mode == "enabled" and hr.spec.driftDetection.ignore[0].paths == ["/spec/replicas"]
    assert hr.spec.valuesFrom[0].kind == "Secret" and hr.spec.valuesFrom[0].targetPath == "grafana.adminPassword"
    assert hr.spec.postRenderers[0].kustomize.patches[0].target.kind == "Deployment"

    plain = render(Manager {role = "manager", dependencies = [{name = "keda", $type = "application", repo = "https://kedacore.github.io/charts"}]})[1]
    assert plain.spec.install.createNamespace == True and plain.spec.install.remediation.retries == 3 and plain.spec.install?.crds == Undefined, "no install → defaults only"
    assert all_true([k not in plain.spec for k in ["upgrade", "driftDetection", "postRenderers", "valuesFrom"]]), "unset Flux fields are not emitted"
}

# ── Role: which dependencies a cluster installs ──────────────────────────────
# A manager cluster runs crossplane AND the apps' operators; a workload cluster
# runs the operators only. Same file, one overlay key.
_roleValues = """\
name: platform
dependencies:
  - name: crossplane
    type: manager
    repo: https://charts.crossplane.io/stable
  - name: cert-manager
    type: application
    repo: https://charts.jetstack.io
  - name: keda
    type: application
    repo: https://kedacore.github.io/charts
  - name: provider-configs
    type: manager
    repo: oci://ghcr.io/example/charts
    dependsOn: [crossplane, cert-manager]
issuers:
  - {name: platform-root, type: self-signed}
"""
test_role = lambda {
    manager = render(Manager {**yaml.decode(_roleValues), role = "manager"})
    assert [o.metadata.name for o in manager if o.kind == "HelmRelease"] == ["crossplane", "cert-manager", "keda", "provider-configs"], "a manager cluster installs every type"
    assert [o.metadata.labels["platform.example.org/type"] for o in manager if o.kind == "HelmRelease"] == ["manager", "application", "application", "manager"]
    assert [o.kind for o in manager][-1] == "ClusterIssuer" and manager[-1].metadata.labels["platform.example.org/type"] == "application", "issuers take cert-manager's type"

    workload = render(Manager {**yaml.decode(_roleValues), role = "workload"})
    assert _kinds(workload) == ["HelmRepository", "HelmRepository", "HelmRelease", "HelmRelease", "ClusterIssuer"], "a workload cluster: application charts and the issuers that follow cert-manager, nothing manager-typed: ${_kinds(workload)}"
    assert [o.metadata.name for o in workload if o.kind == "HelmRelease"] == ["cert-manager", "keda"]
    assert all_true([o.metadata.labels["platform.example.org/type"] == "application" for o in workload])

    # cert-manager typed manager (or absent) → the issuers are manager-cluster objects
    noCm = render(Manager {role = "workload", issuers = [{name = "root", $type = "self-signed"}]})
    assert noCm == [], "no cert-manager dependency → issuers are manager-only → nothing on a workload cluster"
    assert render(Manager {role = "manager", issuers = [{name = "root", $type = "self-signed"}]})[0].metadata.labels["platform.example.org/type"] == "manager"
}

# ── Issuers → cert-manager ClusterIssuer / Issuer ─────────────────────────────
test_issuers = lambda {
    m = Manager {**yaml.decode("""\
name: platform
role: manager
issuers:
  - name: letsencrypt
    email: platform@example.com
    solvers:
      - type: dns01
        provider: cloud-dns
        project: my-project
        hostedZoneName: example-com
        dnsZones: [example.com]
      - type: http01
        ingressClass: nginx
        dnsNames: [app.example.com]
        labels: {use-solver: http}
  - name: tenant-a
    namespace: tenant-a
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: tenant-a@example.com
    privateKeySecret: tenant-a-acme
    solvers:
      - {type: http01}
  - name: platform-root
    type: self-signed
  - name: platform-ca
    type: ca
    caSecret: platform-ca-tls
""")}
    out = render(m)
    assert _kinds(out) == ["ClusterIssuer", "Issuer", "ClusterIssuer", "ClusterIssuer"], "namespace → namespaced Issuer, otherwise ClusterIssuer: ${_kinds(out)}"

    le = out[0]
    assert le.apiVersion == "cert-manager.io/v1" and le.metadata?.namespace == Undefined, "a ClusterIssuer is cluster-scoped"
    assert le.metadata.labels["platform.example.org/type"] == "manager", "issuers travel with the manager phase"
    assert le.spec.acme.server == "https://acme-v02.api.letsencrypt.org/directory", "default ACME endpoint is Let's Encrypt production"
    assert le.spec.acme.privateKeySecretRef.name == "letsencrypt-account-key", "account key secret defaults to <name>-account-key"

    dns01 = le.spec.acme.solvers[0]
    assert dns01.dns01.cloudDNS.project == "my-project" and dns01.dns01.cloudDNS.hostedZoneName == "example-com"
    assert dns01.dns01.cloudDNS?.serviceAccountSecretRef == Undefined, "cloud-dns is keyless: Workload Identity, not a Secret"
    assert dns01.selector.dnsZones == ["example.com"] and dns01.selector?.dnsNames == Undefined
    http01 = le.spec.acme.solvers[1]
    assert http01.http01.ingress.ingressClassName == "nginx"
    assert http01.selector.dnsNames == ["app.example.com"] and http01.selector.matchLabels == {"use-solver" = "http"}

    tenant = out[1]
    assert tenant.metadata.namespace == "tenant-a", "namespaced Issuer lands in its own namespace"
    assert tenant.spec.acme.server.startswith("https://acme-staging") and tenant.spec.acme.privateKeySecretRef.name == "tenant-a-acme"
    assert tenant.spec.acme.solvers[0].http01.ingress?.ingressClassName == Undefined, "no ingressClass → the cluster's default ingress class"
    assert tenant.spec.acme.solvers[0]?.selector == Undefined, "an unnarrowed solver emits no selector"

    assert out[2].spec?.selfSigned != Undefined and out[2].spec?.acme == Undefined, "self-signed carries no ACME account"
    assert out[3].spec.ca.secretName == "platform-ca-tls"
}

# The other two DNS01 providers, both keyless: IRSA on AWS, workload identity
# on Azure. No solver ever emits a credential Secret reference.
test_issuer_dns01_providers = lambda {
    out = render(Manager {**yaml.decode("""\
role: manager
issuers:
  - name: route53
    email: platform@example.com
    solvers:
      - type: dns01
        provider: route53
        region: eu-west-1
        hostedZoneID: Z123456789
        role: arn:aws:iam::123456789012:role/cert-manager
  - name: azure
    email: platform@example.com
    solvers:
      - type: dns01
        provider: azure-dns
        subscriptionID: 00000000-0000-0000-0000-000000000000
        resourceGroupName: dns-rg
        hostedZoneName: example.com
        clientID: 11111111-1111-1111-1111-111111111111
""")})
    r53 = out[0].spec.acme.solvers[0].dns01.route53
    assert r53.region == "eu-west-1" and r53.hostedZoneID == "Z123456789"
    assert r53.role == "arn:aws:iam::123456789012:role/cert-manager", "IRSA: a role to assume, never an access key"
    az = out[1].spec.acme.solvers[0].dns01.azureDNS
    assert az.subscriptionID == "00000000-0000-0000-0000-000000000000" and az.resourceGroupName == "dns-rg"
    assert az.hostedZoneName == "example.com" and az.managedIdentity.clientID == "11111111-1111-1111-1111-111111111111"
    assert all_true([s.dns01?.route53?.accessKeyIDSecretRef in [None, Undefined] and s.dns01?.azureDNS?.clientSecretSecretRef in [None, Undefined] for o in out for s in o.spec.acme.solvers]), "no long-lived cloud keys: both providers authenticate as the workload"
}

# ── Experiments: app faults with a free target ───────────────────────────────
test_experiments = lambda {
    m = Manager {**yaml.decode("""\
role: manager
chaos:
  namespaces: [zerg, dbs]
  experiments:
    - name: random-kill
      type: pod-kill
      target:
        namespaces: [zerg]
        labels: {tier: backend}
      schedule: "0 * * * *"
    - name: node-memory
      type: memory
      mode: all
      size: 512MB
      duration: 5m
      target:
        namespaces: [zerg, dbs]
        nodes: [worker-1]
        nodeLabels: {pool: db}
        phases: [Running]
    - name: db-loss
      type: loss
      loss: "10"
      externalTargets: [postgres-rw.dbs.svc]
      target:
        namespaces: [zerg]
""")}
    out = render(m)
    assert _kinds(out) == ["Namespace", "Namespace", "Schedule", "StressChaos", "NetworkChaos"], "namespaces first, then one object per experiment: ${_kinds(out)}"
    assert out[0].metadata.name == "zerg" and out[0].metadata.labels["chaos-mesh.org/inject"] == "enabled"
    assert all_true([o.metadata.namespace == "chaos-mesh" for o in out[2::]]), "experiments live in chaos.namespace"
    assert all_true([o.metadata?.annotations == Undefined for o in out[2::]]), "not paused → no pause annotation"

    kill = out[2]
    assert kill.spec.$type == "PodChaos" and kill.spec.schedule == "0 * * * *"
    assert kill.spec.podChaos.selector.namespaces == ["zerg"]
    assert kill.spec.podChaos.selector.labelSelectors == {tier = "backend"}

    mem = out[3]
    assert mem.spec.mode == "all" and mem.spec.duration == "5m"
    assert mem.spec.stressors.memory.size == "512MB"
    sel = mem.spec.selector
    assert sel.namespaces == ["zerg", "dbs"] and sel.nodes == ["worker-1"]
    assert sel.nodeSelectors == {pool = "db"} and sel.podPhaseSelectors == ["Running"]
    assert sel?.labelSelectors == Undefined, "no labels → no labelSelectors"

    loss = out[4]
    assert loss.spec.action == "loss" and loss.spec.loss.loss == "10"
    assert loss.spec.externalTargets == ["postgres-rw.dbs.svc"]
}

test_paused = lambda {
    m = Manager {**yaml.decode("""\
role: manager
chaos:
  paused: true
  experiments:
    - {name: kill, type: pod-kill, target: {namespaces: [zerg]}}
    - {name: sched, type: cpu, schedule: "0 3 * * *", target: {namespaces: [zerg]}}
  workflows:
    - name: run
      target: {namespaces: [zerg]}
      steps:
        - {name: kill, type: pod-kill}
""")}
    out = render(m)
    assert out[0].metadata.annotations["experiment.chaos-mesh.org/pause"] == "true", "one-shot experiment paused"
    assert out[1].metadata.annotations["experiment.chaos-mesh.org/pause"] == "true", "Schedule paused"
    assert out[2].kind == "Workflow" and out[2].metadata?.annotations == Undefined, "Workflows are not pausable by annotation"
}

# ── Workflows: managed runs ──────────────────────────────────────────────────
test_workflow_serial = lambda {
    m = Manager {**yaml.decode("""\
role: manager
chaos:
  workflows:
    - name: game-day
      deadline: 30m
      pauseBetween: 5m
      target:
        namespaces: [zerg]
      steps:
        - name: kill-half
          type: pod-kill
          mode: fixed-percent
          value: "50"
        - name: cut-db
          type: partition
          direction: both
          externalTargets: [postgres-rw.dbs.svc]
          duration: 2m
        - name: cpu-burn
          type: cpu
          duration: 3m
          target:
            namespaces: [zerg]
            labels: {app: zerg-api}
""")}
    wf = render(m)[0]
    assert wf.kind == "Workflow" and wf.metadata.name == "game-day" and wf.metadata.namespace == "chaos-mesh"
    assert wf.spec.entry == "entry"
    entry = wf.spec.templates[0]
    assert entry.templateType == "Serial" and entry.deadline == "30m"
    assert entry.children == ["kill-half", "pause-1", "cut-db", "pause-2", "cpu-burn"], "pauses interleaved between serial steps: ${entry.children}"
    names = [t.name for t in wf.spec.templates]
    assert names == ["entry", "kill-half", "cut-db", "cpu-burn", "pause-1", "pause-2"], "every child has a template: ${names}"

    kill = _named(wf.spec.templates, "kill-half")
    assert kill.templateType == "PodChaos" and kill.deadline == "30s"
    assert kill.podChaos.action == "pod-kill" and kill.podChaos.value == "50"
    assert kill.podChaos.selector.namespaces == ["zerg"], "step inherits the workflow target"
    assert kill.podChaos?.duration == Undefined, "in a workflow the deadline is the duration"

    cut = _named(wf.spec.templates, "cut-db")
    assert cut.templateType == "NetworkChaos" and cut.deadline == "2m"
    assert cut.networkChaos.action == "partition" and cut.networkChaos.direction == "both"
    assert cut.networkChaos?.duration == Undefined

    cpu = _named(wf.spec.templates, "cpu-burn")
    assert cpu.templateType == "StressChaos" and cpu.deadline == "3m"
    assert cpu.stressChaos.selector.labelSelectors == {app = "zerg-api"}, "a step target narrows the workflow target"
    assert cpu.stressChaos?.duration == Undefined

    pause = _named(wf.spec.templates, "pause-1")
    assert pause.templateType == "Suspend" and pause.deadline == "5m"
}

test_workflow_parallel = lambda {
    m = Manager {**yaml.decode("""\
role: manager
chaos:
  workflows:
    - name: all-at-once
      parallel: true
      deadline: 10m
      target: {namespaces: [zerg]}
      steps:
        - {name: latency, type: delay, latency: 300ms, duration: 5m}
        - {name: memory, type: memory, size: 256MB, duration: 5m}
""")}
    wf = render(m)[0]
    entry = wf.spec.templates[0]
    assert entry.templateType == "Parallel" and entry.children == ["latency", "memory"]
    assert len(wf.spec.templates) == 3, "no Suspend templates without pauseBetween"
    assert _named(wf.spec.templates, "latency").networkChaos.delay.latency == "300ms"
    assert _named(wf.spec.templates, "memory").stressChaos.stressors.memory.size == "256MB"
}

# ── Release order and the shipped example ────────────────────────────────────
test_example_valid = lambda {
    m = Manager {**yaml.decode(file.read("examples/values.yaml"))}
    out = render(m)
    assert _kinds(out) == ["Namespace", "Namespace"] + ["HelmRepository"] * 5 + ["HelmRelease"] * 5 + ["ClusterIssuer"] * 4 + ["Schedule", "StressChaos", "NetworkChaos", "Workflow", "Workflow"], "example → namespaces, repos, releases, issuers, experiments, workflows: ${_kinds(out)}"
    assert m.name == "platform" and m.role == "manager" and len(m.dependencies) == 5 and len(m.issuers) == 4 and len(m.chaos.experiments) == 3
    assert [d.$type for d in m.dependencies] == ["manager", "application", "application", "application", "application"], "crossplane is what makes it a manager cluster; the apps' operators go everywhere"

    # The shipped overlay: the same file on a workload cluster loses crossplane and nothing else.
    w = render(Manager {**app.mergeValues(yaml.decode(file.read("examples/values.yaml")), yaml.decode(file.read("examples/values.workload.yaml")))})
    assert [o.metadata.name for o in w if o.kind == "HelmRelease"] == ["cert-manager", "chaos-mesh", "keda", "kube-prometheus-stack"], "workload overlay drops the manager-type charts"
    assert len(w) == len(out) - 2, "exactly crossplane's repo + release are gone: ${_kinds(w)}"
    _cm = [d for d in m.dependencies if d.name == "cert-manager"][0]
    assert _cm.values.crds.enabled == True, "the chart's CRDs are off by default and startupapicheck fails without them"
    assert [i.$type for i in m.issuers] == ["acme", "acme", "self-signed", "ca"], "the example covers every issuer kind"
    _le = m.issuers[0]
    assert [s.$type for s in _le.solvers] == ["dns01", "http01"], "the wildcard zone is solved over DNS, the rest over HTTP"
}

test_empty = lambda {
    assert render(Manager {role = "manager"}) == [], "an empty Manager renders nothing"
    assert _kinds(render(Manager {
        role = "workload"
        chaos = {}
    })) == [], "an empty chaos block renders nothing"
}

# invalid inputs — a target without namespaces, a step with a schedule,
# dependsOn naming an unknown dependency, an application dependency depending
# on a manager one, a dependency without a type, a Manager without a role, a
# non-http/oci repo, pauseBetween on a parallel workflow, duplicate names — are
# rejected by the schema `check` blocks.
test_dependencies()
test_dependency_flux_fields()
test_role()
test_experiments()
test_paused()
test_workflow_serial()
test_workflow_parallel()
test_issuers()
test_issuer_dns01_providers()
test_example_valid()
test_empty()
