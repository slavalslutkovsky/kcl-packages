"""
Cluster manager manifests — typed schemas + renderers (single source of truth).

Where `app` describes one workload, `manager` describes the cluster around the
workloads. One values.yaml, four concerns:

  • dependencies → the platform charts as Flux HelmRepository + HelmRelease
    pairs. The declarative twin of devkit.toml's `[[deps]]`: `dependsOn`
    replaces waves, `values:` replaces `set = [...]`. Flux (source-controller +
    helm-controller) must already be on the cluster.

    Two kinds of cluster, so two kinds of dependency. A *manager* cluster
    manages other clusters and cloud resources (Crossplane, its providers,
    the fleet machinery); a *workload* cluster only runs apps. Every
    dependency has a `type` saying which clusters install it:
      manager      → manager clusters only (crossplane, …)
      application  → every cluster that runs apps — workload clusters, and
                     manager clusters too, since a manager can also run apps
                     (keda, chaos-mesh, monitoring, …)
    `Manager.role` says which kind of cluster a values file describes and
    selects what renders: `manager` renders both types, `workload` renders
    application only. One base values file with a `role: workload` overlay
    therefore serves both. The type is also emitted as the label
    `platform.example.org/type`, so a rendered stream can still be split:

      kcl run packages/manager -D values=<file> -q | kubectl apply -l platform.example.org/type=application -f -

    An application dependency may not depend on a manager one: it has to
    install on a workload cluster, where manager dependencies do not exist.
  • issuers → cert-manager ClusterIssuers (or namespaced Issuers): the thing
    an Ingress names in `cert-manager.io/cluster-issuer`. ACME (Let's
    Encrypt) with HTTP01 or DNS01 solvers for public certificates,
    self-signed and CA issuers for the in-cluster PKI. cert-manager itself is
    just another dependency above — list it there; the issuers take its
    `type` (so they render wherever the chart does) and apply the render
    twice (idempotent) if they race the CRDs the chart installs.
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

  • catalog → the Backstage entities for this cluster: one Resource for the
    cluster itself, one per chaos Workflow, so a game day is an owned thing
    in the portal instead of a CR someone applied by hand. Built with `app`'s
    entity atoms and rendered on their own (`-D catalog=true`) — a Backstage
    entity is not a Kubernetes object.

Rendered like `app`: `kcl run packages/manager -D values=<file> [-D env=<env>]`,
or in code `import manager.lib as manager; manager.render(manager.Manager {**values})`.
"""

import k8s.api.core.v1 as corev1
import regex
import app.lib as app
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_helm_repository as helmrepo
import flux_helm.models.v2.helm_toolkit_fluxcd_io_v2_helm_release as helmrelease
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_workflow as cmworkflow
import cert_manager.models.v1.cert_manager_io_v1_cluster_issuer as cmclusterissuer
import cert_manager.models.v1.cert_manager_io_v1_issuer as cmissuer

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

    # Which clusters install this chart: `manager` (manager clusters only) or
    # `application` (every cluster that runs apps). Becomes the label
    # `platform.example.org/type` on the HelmRepository and the HelmRelease.
    $type: "manager" | "application"
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

schema Solver:
    """
    One ACME challenge solver: how cert-manager proves control of a domain.

    `http01` serves the token from a temporary Ingress — the boring choice for
    a cluster that already terminates HTTP in-cluster, and the one that cannot
    issue wildcards. `dns01` writes a TXT record through a cloud DNS API, the
    only way to get `*.example.com` and the only way to issue for a cluster the
    internet cannot reach. Credentials are ambient in every provider below
    (GKE Workload Identity, IRSA, Azure Workload Identity): a keyless cluster
    is the point of packages/cloud/workload-identity, and a Secret full of
    long-lived cloud keys is not something this package will help write.

    `dnsNames` / `dnsZones` / `labels` narrow a solver to part of the estate,
    so one issuer can solve the wildcard zone over DNS and everything else
    over HTTP.
    """
    $type: "http01" | "dns01" = "http01"
    # → solver.selector
    dnsNames: [str] = []
    dnsZones: [str] = []
    labels: {str:str} = {}

    # http01: ingressClassName of the solver Ingress; unset → the cluster default
    ingressClass?: str
    # dns01: which API writes the TXT record
    provider?: "cloud-dns" | "route53" | "azure-dns"
    # cloud-dns: the project that owns the zone. route53: the region the SDK
    # signs against (Route 53 is global, the SDK still needs one).
    project?: str
    region?: str
    # Pin the zone instead of letting cert-manager search every zone in the
    # account: hostedZoneID for route53, hostedZoneName for the other two.
    hostedZoneID?: str
    hostedZoneName?: str
    # route53: the IAM role cert-manager assumes (IRSA / EKS Pod Identity).
    role?: str
    # azure-dns: the zone's subscription + resource group, and the managed
    # identity cert-manager federates with.
    subscriptionID?: str
    resourceGroupName?: str
    clientID?: str

    check:
        $type == "dns01" or not provider, "an http01 solver has no dns provider: drop `provider` or set type: dns01"
        $type == "http01" or not ingressClass, "ingressClass is an http01 field: a dns01 solver serves nothing over HTTP"
        $type == "http01" or provider, "a dns01 solver needs a provider (cloud-dns | route53 | azure-dns)"
        provider != "cloud-dns" or project, "a cloud-dns solver needs the `project` that owns the zone"
        provider != "route53" or region, "a route53 solver needs a `region` to sign against"
        provider != "azure-dns" or (subscriptionID and resourceGroupName), "an azure-dns solver needs `subscriptionID` and `resourceGroupName`"

schema Issuer:
    """
    A cert-manager issuer — cluster-scoped by default, because a ClusterIssuer
    is what an Ingress in *any* namespace may name in the
    `cert-manager.io/cluster-issuer` annotation. Set `namespace` for a
    namespaced Issuer instead (one tenant, one CA, no cluster-wide reach).

    Three kinds, and nothing else this package pretends to support:
      • `acme` — Let's Encrypt or any other ACME CA. Needs `email` and at
        least one solver; the account key is kept in `privateKeySecret`
        (default `<name>-account-key`).
      • `self-signed` — signs with the requester's own key. Used to bootstrap
        the root of an internal PKI, and for throwaway clusters.
      • `ca` — signs from an existing keypair in `caSecret` (tls.crt +
        tls.key). The in-cluster PKI case: mTLS, webhooks, internal names no
        public CA will ever sign.
    """
    name: str
    $type: "acme" | "self-signed" | "ca" = "acme"
    # set → a namespaced Issuer instead of a ClusterIssuer
    namespace?: str
    # acme. The default is Let's Encrypt production; point `server` at
    # https://acme-staging-v02.api.letsencrypt.org/directory while wiring up
    # DNS, because production is rate-limited per registered domain.
    server: str = "https://acme-v02.api.letsencrypt.org/directory"
    email?: str
    privateKeySecret?: str
    solvers: [Solver] = []

    # ca: the Secret holding the signing keypair, in cert-manager's namespace
    # for a ClusterIssuer, in `namespace` for an Issuer.
    caSecret?: str

    check:
        $type == "acme" or not solvers, "issuer ${name}: solvers are an ACME concept; a ${$type} issuer solves no challenges"
        $type == "acme" or not email, "issuer ${name}: email is the ACME account address; a ${$type} issuer has no account"
        $type != "acme" or email, "issuer ${name}: an ACME issuer needs the account `email`"
        $type != "acme" or len(solvers) > 0, "issuer ${name}: an ACME issuer needs at least one solver, or nothing can ever be issued"
        $type != "ca" or caSecret, "issuer ${name}: a ca issuer needs `caSecret` — the keypair it signs with"
        $type == "ca" or not caSecret, "issuer ${name}: caSecret only applies to a ca issuer"

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

schema Catalog:
    """
    Backstage entities for the cluster this values file describes.

    Where `app`'s `catalog:` describes one workload, this describes what
    surrounds them: a Resource of type `kubernetes-cluster`, and a Resource of
    type `chaos-workflow` per game day. One id links entity to cluster — every
    experiment and Workflow rendered here is labelled
    `backstage.io/kubernetes-id` with its own name, so the Kubernetes plugin
    resolves the live Chaos Mesh objects from the entity page.

    What the portal can answer without cluster access comes from annotations
    derived here, never hand-written: which charts Flux keeps installed
    (`platform.example.org/charts`), which cluster-scope experiments exist
    (`platform.example.org/chaos-experiments`), and for each game day its steps
    and target namespaces.
    """
    # spec.owner. Required: Backstage will not accept an ownerless entity.
    owner: str
    # entity name of the cluster Resource; default: the Manager's `name`
    name?: str
    title?: str
    description?: str
    # spec.system of the cluster and of every game day under it
    system?: str
    tags: [str] = []
    # merged OVER the derived annotations
    annotations: {str:str} = {}
    links: [app.Link] = []

    # linked from the cluster and from every game day: where a run is watched.
    # `devkit.toml` keeps the Chaos Mesh dashboard off by default (docs/chaos.md).
    dashboardUrl?: str
    # entity refs the cluster depends on, e.g. "resource:aws-account-prod"
    dependsOn: [str] = []

    check:
        name == Undefined or regex.match(name, r"^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$"), "catalog name '${name}' is not a valid Backstage entity name: [A-Za-z0-9._-], starting and ending alphanumeric, at most 63 characters"
        all t in tags {regex.match(t, r"^[a-z0-9][a-z0-9+#-]*$")}, "catalog tags must be lowercase [a-z0-9+#-] and start alphanumeric — Backstage rejects the rest: ${tags}"

schema Manager:
    """The whole cluster-management release: one values.yaml per cluster."""
    name: str = "manager"

    # The kind of cluster this file describes. `manager` renders every
    # dependency; `workload` renders only the `application` ones.
    role: "manager" | "workload"
    # namespace the HelmRepository / HelmRelease objects live in
    namespace: str = "flux-system"
    dependencies: [Dependency] = []

    # cert-manager issuers. Cluster-scoped unless a row sets `namespace`; the
    # cert-manager chart itself belongs in `dependencies` above.
    issuers: [Issuer] = []
    chaos?: Chaos
    catalog?: Catalog
    _typeOf = {d.name: d.$type for d in dependencies}

    check:
        len(dependencies) == len({d.name: 1 for d in dependencies}), "dependency names must be unique"
        all_true([dep in _typeOf for d in dependencies for dep in d.dependsOn]), "dependsOn must name another dependency in this file"
        all_true([_typeOf[dep] == "application" for d in dependencies if d.$type == "application" for dep in d.dependsOn if dep in _typeOf]), "an application dependency may not depend on a manager dependency: it must install on a workload cluster, where manager dependencies are absent"
        len(issuers) == len({i.name: 1 for i in issuers}), "issuer names must be unique"

# Which dependencies a cluster of this role installs.
_installed = lambda m: Manager -> [Dependency] {
    m.dependencies if m.role == "manager" else [d for d in m.dependencies if d.$type == "application"]
}

# Issuers are instances of cert-manager's CRDs, so they go wherever the
# cert-manager chart goes. Without the chart in this file: manager clusters.
_issuerType = lambda m: Manager -> str {
    _cm = [d for d in m.dependencies if d.name == "cert-manager"]
    _cm[0].$type if _cm else "manager"
}

# ── Dependencies (Flux) ──────────────────────────────────────────────────────
_labels = lambda m: Manager -> {str:str} {
    {"app.kubernetes.io/managed-by" = "manager", "app.kubernetes.io/part-of" = m.name}
}

# The phase selector: `kubectl apply -l platform.example.org/type=<type>`.
_dependencyLabels = lambda m: Manager, d: Dependency -> {str:str} {
    _labels(m) | {"platform.example.org/type" = d.$type}
}

_helmRepository = lambda m: Manager, d: Dependency -> helmrepo.HelmRepository {
    helmrepo.HelmRepository {
        metadata = {name = d.name, namespace = m.namespace, labels = _dependencyLabels(m, d)}
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
        metadata = {name = d.name, namespace = m.namespace, labels = _dependencyLabels(m, d)}
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

# ── Issuers (cert-manager) ───────────────────────────────────────────────────
# The DNS01 provider blocks, keyless in every case: no credential fields are
# emitted, so cert-manager uses the identity its ServiceAccount is federated
# with (see packages/cloud/workload-identity for the GSA/role/identity itself).
_dns01 = lambda s: Solver -> {str:} {
    _cloudDNS = {project = s.project} | ({hostedZoneName = s.hostedZoneName} if s.hostedZoneName else {})
    _route53 = {region = s.region} | ({hostedZoneID = s.hostedZoneID} if s.hostedZoneID else {}) | ({role = s.role} if s.role else {})
    _azureDNS = {subscriptionID = s.subscriptionID, resourceGroupName = s.resourceGroupName} | ({hostedZoneName = s.hostedZoneName} if s.hostedZoneName else {}) | ({
        managedIdentity = {clientID = s.clientID}
    } if s.clientID else {})
    {cloudDNS = _cloudDNS} if s.provider == "cloud-dns" else {route53 = _route53} if s.provider == "route53" else {azureDNS = _azureDNS}
}

_solver = lambda s: Solver -> {str:} {
    _http01 = {ingress = {ingressClassName = s.ingressClass} if s.ingressClass else {}}
    _challenge = {http01 = _http01} if s.$type == "http01" else {dns01 = _dns01(s)}
    _selectorFields = ({dnsNames = s.dnsNames} if s.dnsNames else {}) | ({dnsZones = s.dnsZones} if s.dnsZones else {}) | ({matchLabels = s.labels} if s.labels else {})
    _challenge | ({selector = _selectorFields} if _selectorFields else {})
}

_issuerSpec = lambda i: Issuer -> {str:} {
    _acme = {
        server = i.server
        email = i.email
        privateKeySecretRef = {name = i.privateKeySecret or "${i.name}-account-key"}
        solvers = [_solver(s) for s in i.solvers]
    }
    {acme = _acme} if i.$type == "acme" else {
        selfSigned = {}
    } if i.$type == "self-signed" else {
        ca = {secretName = i.caSecret}
    }
}

# An issuer is an instance of a cert-manager CRD, so it carries the type of
# the cert-manager dependency and renders on the same clusters as the chart.
_issuer = lambda m: Manager, i: Issuer -> any {
    _meta = {name = i.name, labels = _labels(m) | {"platform.example.org/type" = _issuerType(m)}}
    cmissuer.Issuer {
        metadata = _meta | {namespace = i.namespace}
        spec = _issuerSpec(i)
    } if i.namespace else cmclusterissuer.ClusterIssuer {
        metadata = _meta
        spec = _issuerSpec(i)
    }
}

# ── Chaos (Chaos Mesh) ───────────────────────────────────────────────────────
_selector = lambda t: Target -> {str:} {
    {namespaces = t.namespaces} | ({labelSelectors = t.labels} if t.labels else {}) | ({nodes = t.nodes} if t.nodes else {}) | ({nodeSelectors = t.nodeLabels} if t.nodeLabels else {}) | ({podPhaseSelectors = t.phases} if t.phases else {})
}

# Workflows are not pausable by annotation (delete or let the deadline pass),
# so only experiments and Schedules get the pause marker.
_chaosMeta = lambda m: Manager, name: str, pausable: bool -> {str:} {
    {name = name, namespace = m.chaos.namespace, labels = _labels(m) | {"backstage.io/kubernetes-id" = name}} | ({
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

# ── Backstage catalog ────────────────────────────────────────────────────────
# Entity atoms come from `app` (app.entity / app.link / app.faultSummary), so a
# cluster entity and a component entity are built the same way. Nothing here is
# a Kubernetes object: `catalogEntities` is a separate render, never part of
# the manifest stream.

# What Flux keeps installed on this cluster, as "<chart>=<type>" pairs — the
# roster the `role` already decided, not every row in the file.
_chartSummary = lambda deps: [Dependency] -> str {
    ",".join(["${d.name}=${d.$type}" for d in deps])
}

_dashboardLink = lambda c: Catalog -> [{str:}] {
    [app.link(app.Link {url = c.dashboardUrl, title = "Chaos dashboard", icon = "dashboard"})] if c.dashboardUrl else []
}

_clusterEntity = lambda m: Manager -> {str:} {
    _c = m.catalog
    _name = _c.name or m.name
    _deps = _installed(m)
    _experiments = m.chaos.experiments if m.chaos else []
    _links = _dashboardLink(_c) + [app.link(l) for l in _c.links]
    _ann = {
        "backstage.io/kubernetes-id" = _name
        "platform.example.org/cluster-role" = m.role
    } | ({"platform.example.org/charts" = _chartSummary(_deps)} if _deps else {}) | ({
        "platform.example.org/chaos-experiments" = app.faultSummary(_experiments)
    } if _experiments else {}) | _c.annotations
    app.entity("Resource", {
        name = _name
        annotations = _ann
    } | ({title = _c.title} if _c.title else {}) | ({description = _c.description} if _c.description else {}) | ({tags = _c.tags} if _c.tags else {}) | ({links = _links} if _links else {}), {
        $type = "kubernetes-cluster"
        owner = _c.owner
    } | ({system = _c.system} if _c.system else {}) | ({dependsOn = _c.dependsOn} if _c.dependsOn else {}))
}

# A game day as a catalog object. Its kubernetes-id is the Workflow's own name,
# which is exactly what _chaosMeta labels the Workflow with, so the entity page
# shows the live run and its nodes. The description is derived — a values file
# cannot claim a run does something other than what it renders.
_workflowEntity = lambda m: Manager, w: Workflow -> {str:} {
    _c = m.catalog
    _shape = "parallel" if w.parallel else "series"
    app.entity("Resource", {
        name = w.name
        description = "${len(w.steps)} chaos faults in ${_shape}, ${w.deadline} deadline, against ${','.join(w.target.namespaces)}"
        annotations = {
            "backstage.io/kubernetes-id" = w.name
            "backstage.io/kubernetes-namespace" = m.chaos.namespace
            "platform.example.org/chaos-steps" = app.faultSummary(w.steps)
            "platform.example.org/chaos-target" = ",".join(w.target.namespaces)
        } | _c.annotations
    } | ({tags = _c.tags} if _c.tags else {}) | ({links = _dashboardLink(_c)} if _c.dashboardUrl else {}), {
        $type = "chaos-workflow"
        owner = _c.owner
        # The run belongs to the cluster it is aimed at, so the portal shows
        # both sides of the edge.
        dependsOn = ["resource:${_c.name or m.name}"]
    } | ({system = _c.system} if _c.system else {}))
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda m: Manager -> [any] {
    """
    All manifests for a Manager, in apply order: chaos-enabled Namespaces,
    HelmRepositories, HelmReleases, issuers, experiments (one-shot or
    Schedule), Workflows. Dependencies (and the issuers, which follow
    cert-manager) are filtered by `role`: a workload cluster gets the
    `application` type only.

    Issuers come after the releases on purpose — the cert-manager CRDs they are
    instances of arrive with the chart, so a first apply on a bare cluster can
    reject them; the render is idempotent, apply it again once helm-controller
    reports cert-manager Ready.
    """
    _deps = _installed(m)
    _namespaces: [any] = [_chaosNamespace(m, ns) for ns in m.chaos.namespaces] if m.chaos else []
    _flux: [any] = [_helmRepository(m, d) for d in _deps] + [_helmRelease(m, d) for d in _deps]
    _issuers: [any] = [_issuer(m, i) for i in m.issuers] if m.role == "manager" or _issuerType(m) == "application" else []
    _runs: [any] = ([_experiment(m, e) for e in m.chaos.experiments] + [_workflow(m, w) for w in m.chaos.workflows]) if m.chaos else []
    _namespaces + _flux + _issuers + _runs
}

catalogEntities = lambda m: Manager -> [any] {
    """
    The Backstage entities for a Manager: the cluster Resource, plus one per
    chaos Workflow. Empty when the values file has no `catalog:`.

    A second render rather than extra items in `render`, because a Backstage
    entity is not a Kubernetes object:

      kcl run packages/manager -D values=<file> -D catalog=true -q > catalog-info.yaml

    Cluster-scope experiments are listed on the cluster entity instead of
    getting one each: an experiment is a fault, a Workflow is a run, and only a
    run is worth owning in a catalog.
    """
    _c = m.catalog
    ([_clusterEntity(m)] + ([_workflowEntity(m, w) for w in m.chaos.workflows] if m.chaos else [])) if _c else []
}
