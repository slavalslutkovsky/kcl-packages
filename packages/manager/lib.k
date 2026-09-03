"""
Cluster manager manifests — typed schemas + renderers (single source of truth).

Where `app` describes one workload, `manager` describes the cluster around the
workloads. One values.yaml, three concerns:

  • dependencies → the platform charts as Flux HelmRepository + HelmRelease
    pairs. The declarative twin of devkit.toml's `[[deps]]`: `dependsOn`
    replaces waves, `values:` replaces `set = [...]`. Flux (source-controller +
    helm-controller) must already be on the cluster.
  • chaos.experiments → Chaos Mesh experiments with a free selector
    (namespaces, labels, nodes, pod phases): the cluster-scope counterpart of a
    Workload's `chaos:` faults, built from the same `app.Fault` schema and the
    same renderers, so a fault means the same thing in both packages.
  • chaos.workflows → Chaos Mesh Workflows: several faults run in series or in
    parallel under one deadline, with optional pauses between steps. This is
    how "runs" are managed: a game day is one Workflow, not a pile of
    experiments applied by hand.

`chaos.paused` annotates every rendered experiment and Schedule so a whole
values file can be held without deleting anything; `chaos.namespaces` labels
namespaces `chaos-mesh.org/inject=enabled` for clusters where Chaos Mesh runs
with `enableFilterNamespace`.

Rendered like `app`: `kcl run packages/manager -D values=<file> [-D env=<env>]`,
or in code `import manager.lib as manager; manager.render(manager.Manager {**values})`.
"""

import k8s.api.core.v1 as corev1
import app.lib as app
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_helm_repository as helmrepo
import flux_helm.models.v2.helm_toolkit_fluxcd_io_v2_helm_release as helmrelease
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_workflow as cmworkflow

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Dependency:
    """
    One platform chart, delivered by Flux. `repo` is an https:// index or an
    oci:// registry; `dependsOn` names other dependencies in the same values
    file and becomes HelmRelease.spec.dependsOn (helm-controller waits for them
    to be Ready — the `wave` of devkit.toml).

    The sugar stops at the fields above. Everything else is the Flux object's
    own shape, typed by the generated CRD schemas: `install` / `upgrade` /
    `driftDetection` / `postRenderers` / `valuesFrom` are HelmRelease.spec
    fields, `secretRef` / `provider` are HelmRepository.spec fields.
    """
    name: str
    repo: str
    # default: name
    chart?: str
    # default: latest ("*")
    version?: str
    # target namespace, created on install; default: name
    namespace?: str
    # → HelmRelease.spec.values (nested, like a values file)
    values: {str:} = {}
    # → HelmRelease.spec.valuesFrom: Secrets / ConfigMaps merged under `values`
    valuesFrom: [helmrelease.HelmToolkitFluxcdIoV2HelmReleaseSpecValuesFromItems0] = []
    dependsOn: [str] = []
    interval: str = "10m"
    timeout: str = "10m"
    # → HelmRelease.spec.install, over the defaults createNamespace + 3 retries
    install?: helmrelease.HelmToolkitFluxcdIoV2HelmReleaseSpecInstall
    upgrade?: helmrelease.HelmToolkitFluxcdIoV2HelmReleaseSpecUpgrade
    driftDetection?: helmrelease.HelmToolkitFluxcdIoV2HelmReleaseSpecDriftDetection
    postRenderers?: [helmrelease.HelmToolkitFluxcdIoV2HelmReleaseSpecPostRenderersItems0]
    # → HelmRepository.spec.secretRef: credentials for a private index / registry
    secretRef?: helmrepo.SourceToolkitFluxcdIoV1HelmRepositorySpecSecretRef
    # → HelmRepository.spec.provider: cloud-native auth, oci:// registries only
    provider?: "aws" | "azure" | "gcp"

    check:
        repo.startswith("https://") or repo.startswith("http://") or repo.startswith("oci://"), "dependency ${name}: repo must be an http(s):// chart index or an oci:// registry"
        not provider or repo.startswith("oci://"), "dependency ${name}: provider only applies to an oci:// registry"

schema Target:
    """
    Which pods a cluster-scope fault hits. `namespaces` is required: a Chaos
    Mesh selector without it is cluster-wide, and nothing here is allowed to be.
    """
    namespaces: [str]
    labels: {str:str} = {}
    # node names / node labels the pods must run on
    nodes: [str] = []
    nodeLabels: {str:str} = {}
    # Pending | Running | Succeeded | Failed | Unknown
    phases: [str] = []

    check:
        len(namespaces) > 0, "a target needs at least one namespace"

schema Experiment(app.Fault):
    """An `app.Fault` with an explicit target instead of a workload. Same types, same knobs, same `schedule`."""
    target: Target

schema Step(app.Fault):
    """
    One step of a Workflow: an `app.Fault` run for `duration` against `target`
    (default: the workflow's). A step is never scheduled — the Workflow is the
    run — so `schedule` is rejected.
    """
    target?: Target

    check:
        not schedule, "step ${name}: a workflow step cannot have a schedule; put the cron on the Workflow via chaos.experiments instead"

schema Workflow:
    """
    A managed run: steps in series (default) or in parallel under one
    deadline. `pauseBetween` inserts a Suspend of that length between serial
    steps, so a run can be "kill, wait 5m, cut the database, wait 5m, stress".
    """
    name: str
    target: Target
    steps: [Step]
    parallel: bool = False
    deadline: str = "1h"
    pauseBetween?: str

    check:
        len(steps) > 0, "workflow ${name} needs at least one step"
        len(steps) == len({s.name: 1 for s in steps}), "workflow ${name}: step names must be unique"
        not (parallel and pauseBetween), "workflow ${name}: pauseBetween only applies to serial steps"

schema Chaos:
    """Cluster-scope chaos: where the objects live, whether they are paused, and what runs."""
    # namespace the experiments / Workflows are created in
    namespace: str = "chaos-mesh"
    # annotate every experiment and Schedule experiment.chaos-mesh.org/pause=true
    paused: bool = False
    # namespaces labelled chaos-mesh.org/inject=enabled
    namespaces: [str] = []
    experiments: [Experiment] = []
    workflows: [Workflow] = []

    check:
        len(experiments) == len({e.name: 1 for e in experiments}), "experiment names must be unique"
        len(workflows) == len({w.name: 1 for w in workflows}), "workflow names must be unique"

schema Manager:
    """The whole cluster-management release: one values.yaml."""
    name: str = "manager"
    # namespace the HelmRepository / HelmRelease objects live in
    namespace: str = "flux-system"
    dependencies: [Dependency] = []
    chaos?: Chaos

    check:
        len(dependencies) == len({d.name: 1 for d in dependencies}), "dependency names must be unique"
        all_true([dep in [d.name for d in dependencies] for d in dependencies for dep in d.dependsOn]), "dependsOn must name another dependency in this file"

# ── Dependencies (Flux) ──────────────────────────────────────────────────────
_labels = lambda m: Manager -> {str:str} {
    {"app.kubernetes.io/managed-by" = "manager", "app.kubernetes.io/part-of" = m.name}
}

_helmRepository = lambda m: Manager, d: Dependency -> helmrepo.HelmRepository {
    helmrepo.HelmRepository {
        metadata = {name = d.name, namespace = m.namespace, labels = _labels(m)}
        spec = {
            url = d.repo
            interval = d.interval
            if d.repo.startswith("oci://"):
                $type = "oci"
            if d.secretRef:
                secretRef = d.secretRef
            if d.provider:
                provider = d.provider
        }
    }
}

# A chart that failed to install because its dependency was not up yet should
# retry, not stay wedged; a Dependency's own `install` is deep-merged over this
# (right wins), the same merge the values overlays use.
_installDefaults = {createNamespace = True, remediation = {retries = 3}}

# The generated HelmRelease schema carries the CRD's `has(chart) != has(chartRef)`
# rule, which KCL can only satisfy with an explicit `chartRef = None`; the None
# is stripped from the emitted object because the API server rejects a literal
# null there (same dance as platform/component/flux).
_helmRelease = lambda m: Manager, d: Dependency -> {str:} {
    _hr = helmrelease.HelmRelease {
        metadata = {name = d.name, namespace = m.namespace, labels = _labels(m)}
        spec = {
            interval = d.interval
            timeout = d.timeout
            releaseName = d.name
            targetNamespace = d.namespace or d.name
            install = app.mergeValues(_installDefaults, {k: v for k, v in d.install if v not in [None, Undefined]}) if d.install else _installDefaults
            chart = {
                spec = {
                    chart = d.chart or d.name
                    sourceRef = {kind = "HelmRepository", name = d.name, namespace = m.namespace}
                    if d.version:
                        version = d.version
                }
            }
            chartRef = None
            if d.dependsOn:
                dependsOn = [{name = dep, namespace = m.namespace} for dep in d.dependsOn]
            if d.values:
                values = d.values
            if d.valuesFrom:
                valuesFrom = d.valuesFrom
            if d.upgrade:
                upgrade = d.upgrade
            if d.driftDetection:
                driftDetection = d.driftDetection
            if d.postRenderers:
                postRenderers = d.postRenderers
        }
    }
    {apiVersion = _hr.apiVersion, kind = _hr.kind, metadata = _hr.metadata, spec = {k: v for k, v in _hr.spec if v not in [None, Undefined]}}
}

# ── Chaos (Chaos Mesh) ───────────────────────────────────────────────────────
_selector = lambda t: Target -> {str:} {
    {namespaces = t.namespaces} | ({labelSelectors = t.labels} if t.labels else {}) | ({nodes = t.nodes} if t.nodes else {}) | ({nodeSelectors = t.nodeLabels} if t.nodeLabels else {}) | ({podPhaseSelectors = t.phases} if t.phases else {})
}

# Workflows are not pausable by annotation (delete or let the deadline pass),
# so only experiments and Schedules get the pause marker.
_chaosMeta = lambda m: Manager, name: str, pausable: bool -> {str:} {
    {name = name, namespace = m.chaos.namespace, labels = _labels(m)} | ({
        annotations = {"experiment.chaos-mesh.org/pause" = "true"}
    } if pausable and m.chaos.paused else {})
}

_chaosNamespace = lambda m: Manager, ns: str -> corev1.Namespace {
    corev1.Namespace {
        metadata = {name = ns, labels = {"chaos-mesh.org/inject" = "enabled"}}
    }
}

_experiment = lambda m: Manager, e: Experiment -> any {
    app.experiment(e, _selector(e.target), _chaosMeta(m, e.name, True))
}

# In a Workflow the template `deadline` is the fault's duration; the embedded
# spec carries everything else.
_stepTemplate = lambda w: Workflow, s: Step -> {str:} {
    _kind = app.faultKind(s)
    _spec = {k: v for k, v in app.faultSpec(s, _selector(s.target or w.target)) if k != "duration"}
    {name = s.name, templateType = _kind, deadline = s.duration} | ({podChaos = _spec} if _kind == "PodChaos" else {networkChaos = _spec} if _kind == "NetworkChaos" else {stressChaos = _spec})
}

_workflow = lambda m: Manager, w: Workflow -> cmworkflow.Workflow {
    _names = [s.name for s in w.steps]
    # Serial with a pause: step, pause-1, step, pause-2, step
    _pauses = [{name = "pause-${i + 1}", templateType = "Suspend", deadline = w.pauseBetween} for i in range(len(_names) - 1)] if w.pauseBetween else []
    _children = _names if not _pauses else sum([[_names[i], _pauses[i].name] for i in range(len(_pauses))], []) + [_names[-1]]
    cmworkflow.Workflow {
        metadata = _chaosMeta(m, w.name, False)
        spec = {
            entry = "entry"
            templates = [{name = "entry", templateType = "Parallel" if w.parallel else "Serial", deadline = w.deadline, children = _children}] + [_stepTemplate(w, s) for s in w.steps] + _pauses
        }
    }
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda m: Manager -> [any] {
    """
    All manifests for a Manager, in apply order: chaos-enabled Namespaces,
    HelmRepositories, HelmReleases, experiments (one-shot or Schedule), Workflows.
    """
    #_namespace = corev1.Namespace
    _namespaces: [any] = [_chaosNamespace(m, ns) for ns in m.chaos.namespaces] if m.chaos else []
    _deps: [any] = [_helmRepository(m, d) for d in m.dependencies] + [_helmRelease(m, d) for d in m.dependencies]
    _runs: [any] = ([_experiment(m, e) for e in m.chaos.experiments] + [_workflow(m, w) for w in m.chaos.workflows]) if m.chaos else []
    _namespaces + _deps + _runs
}
