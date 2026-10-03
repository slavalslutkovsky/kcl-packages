"""
Fleet — the app of apps, typed. One values file for a whole cluster's
delivery tree: what the PLATFORM team owns, what each APPLICATION team owns,
and the order between them.

Everything here renders to `Component` XRs (packages/platform/component), one
per application, plus the team Namespaces. A Component is the platform's unit
of delivery — one Flux source (OCIRepository | GitRepository | HelmRepository)
plus one delivery object (Kustomization | HelmRelease) — so this package adds
no second way to reconcile anything; it decides how many Components exist, what
each one points at, and which ones wait for which.

  values.yaml ──► fleet.render ──► [Namespace…, Component…]  ──► Flux ──► cluster
                                    (platform.example.org/v1alpha1)

WHY A PACKAGE AND NOT ONE MORE XRD

The Component XR already models one app. What a platform team actually edits is
the LIST: add a team, add a chart, pin a version, make the whole application
layer wait for the new CRDs. That list is a file, reviewed and diffed as a file,
and rendering it here means a bad edit fails on `kcl run` instead of becoming
fifteen XRs that partially apply.

TWO LAYERS, ONE BARRIER

  platform:  what the cluster must have before any team's app can work —
             Crossplane and its providers, the XRDs and Compositions, operators,
             CRDs. Rendered first.
  teams:     one entry per application team, each with its own target namespace
             and its own apps. Rendered second, and by default every one of them
             gets `dependsOn` on every platform app (`waitForPlatform`), which
             is what makes this an app OF APPS rather than a pile of XRs: Flux
             holds the whole application layer until the platform layer is
             Ready. An app that must not wait sets `waitForPlatform: false`.

THREE ENGINES, BECAUSE TEAMS DO NOT AGREE

  helm        a chart out of a Helm repository (http(s):// index or oci://
              registry) — `chart` + `version` — or an OCI artifact that IS a
              chart (source.kind: OCIRepository, no `chart`). The nginx case.
  kustomize   plain YAML in a Git repository or an OCI artifact, applied by
              kustomize-controller at `path`.
  crossplane  the same Kustomization, applied to content that is CROSSPLANE
              CLAIMS/XRs rather than core objects. Separate from `kustomize` on
              purpose: it is what tells a reader that this app's real work
              happens in a Composition, it defaults to `wait: true` so the XRs'
              readiness gates the Component, and it is the layer most likely to
              need `serviceAccount` — an app team allowed to create XRs is not
              automatically allowed to create anything a Composition composes.

WHERE THE OBJECTS LIVE

Every Component XR is created in `namespace` (flux-system by default), while the
WORKLOAD lands in the team's namespace through `deliver.targetNamespace`. That
is deliberate: `Component.spec.dependsOn` names sibling Components *in the same
namespace*, so one namespace for the tree is what makes cross-team ordering
expressible at all. Per-team blast radius is bought with `serviceAccount` (the
identity the Flux controller impersonates while applying), not by scattering the
Components.

Rendered like `app`, `manager` and `cncf`:

  kcl run packages/fleet -D values=<file> [-D env=<env>] -q | kubectl apply -f -
  # in code:
  import fleet.lib as fleet; fleet.render(fleet.Fleet {**values})

Crossplane with the Component XRD and its Composition (`just install-module
component`) and Flux must already be on the cluster — this renders XRs, nothing
installs itself.
"""

import k8s.api.core.v1 as corev1

# The Component capability: packages/platform/component/xrd/xrd.yaml.
component_api_version = "platform.example.org/v1alpha1"
component_kind = "Component"

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Source:
    """
    Where one app's content comes from — the `Component.spec.source` half.

    `kind` is derived when unset: a helm app indexes a Helm repository, anything
    else pulls an OCI artifact when the URL is oci:// and clones Git otherwise.
    Set it explicitly only for the one case derivation cannot guess: a helm app
    whose chart IS an OCI artifact (kind OCIRepository, delivered by chartRef).
    """
    url: str
    kind?: "OCIRepository" | "GitRepository" | "HelmRepository"
    # Which revision to track. Flux's own precedence applies when several are
    # set (digest > semver > tag for OCI; name > tag > semver > branch for Git),
    # so this package forwards them and does not re-implement the rules.
    tag?: str
    branch?: str
    semver?: str
    digest?: str
    # How often the SOURCE is re-checked upstream — the latency between "pushed"
    # and "the cluster notices". The delivery interval is App.interval.
    interval: str = "1m"
    # Plain-HTTP OCI registry (the in-cluster kind registry serves HTTP).
    insecure: bool = False

    # EXISTING Secret in the fleet namespace with the source credentials. No
    # secret material is ever rendered here, only named.
    secretRef?: str

    check:
        url, "source.url is required"
        not (url.endswith("/")), "source.url must not end in '/': Flux joins paths itself, got '${url}'"

schema App:
    """
    One delivered application — one `Component` XR.

    `name` is the XR name, the Flux objects' name, and the handle siblings use
    in `dependsOn`, so it is unique across the whole fleet, not just its team.
    """
    name: str

    # How the content becomes cluster state. See the module docstring: helm →
    # HelmRelease, kustomize/crossplane → Kustomization.
    engine: "helm" | "kustomize" | "crossplane"
    source: Source

    # helm: the chart's name inside the Helm repository and the version range.
    # An OCI-artifact chart (source.kind OCIRepository) carries neither — the
    # artifact IS the chart, and source.tag pins it.
    chart?: str
    version?: str
    # → HelmRelease.spec.values, verbatim.
    values: {str:} = {}

    # kustomize / crossplane: directory inside the source.
    path: str = "./"

    # Namespace the WORKLOAD is created in. Defaults to the team's namespace;
    # a platform app with none lets its own manifests or chart decide.
    targetNamespace?: str
    # Sibling app names that must be Ready first. Plus, for a team app, every
    # platform app — unless waitForPlatform says otherwise.
    dependsOn: [str] = []
    # Opt out of the platform barrier (Fleet.waitForPlatform) for this app.
    waitForPlatform?: bool
    # Reconcile interval of the DELIVERY object, and the per-apply timeout.
    interval: str = "5m"
    timeout: str = "5m"

    # Kustomization only: garbage-collect what disappears from the source, and
    # health-check what was applied before reporting Ready.
    prune: bool = True
    wait: bool = True
    # Stop reconciling, leave what is applied in place. The source keeps fetching.
    suspend: bool = False

    # ServiceAccount in the fleet namespace for the Flux controller to
    # impersonate while applying this app — the blast-radius control.
    serviceAccount?: str
    # Extra labels on the Component XR (team, cost centre, …).
    labels: {str:str} = {}

    # Derived so the checks below and the renderers agree on one answer.
    _kind: str = source.kind or ("HelmRepository" if engine == "helm" else "OCIRepository" if source.url.startswith("oci://") else "GitRepository")

    check:
        engine != "helm" or _kind in ["HelmRepository", "OCIRepository"], "app ${name}: a helm app is fed by a HelmRepository (chart + version) or an OCIRepository whose artifact is the chart, not a ${_kind}"
        engine == "helm" or _kind in ["OCIRepository", "GitRepository"], "app ${name}: a ${engine} app applies manifests, and a HelmRepository holds charts — use an OCIRepository or a GitRepository"
        _kind != "HelmRepository" or chart, "app ${name}: a chart pulled from a Helm repository needs `chart` (the chart's name in the index)"
        engine != "helm" or _kind != "OCIRepository" or not chart, "app ${name}: an OCIRepository artifact IS the chart (delivered by chartRef) — drop `chart` or point `source.url` at a Helm repository"
        engine == "helm" or not chart, "app ${name}: `chart`/`version` are helm fields; a ${engine} app selects content with `path`"
        engine == "helm" or not values, "app ${name}: `values` are Helm values; a ${engine} app has no values (substitute upstream, in the source)"
        _kind != "GitRepository" or not source.digest, "app ${name}: `digest` pins an OCI artifact; a Git source is pinned by tag, branch or semver"
        _kind == "GitRepository" or not source.branch, "app ${name}: `branch` is a Git concept; an OCI registry has tags, semver ranges and digests"
        not source.insecure or _kind == "OCIRepository", "app ${name}: source.insecure allows a plain-HTTP OCI registry; a ${_kind} has no such mode (use https:// or an ssh:// Git URL)"
        _kind != "GitRepository" or source.url.startswith("https://") or source.url.startswith("http://") or source.url.startswith("ssh://"), "app ${name}: a Git source needs an http(s):// or ssh:// URL, got '${source.url}'"
        _kind != "OCIRepository" or source.url.startswith("oci://"), "app ${name}: an OCIRepository needs an oci:// URL, got '${source.url}'"
        _kind != "HelmRepository" or source.url.startswith("https://") or source.url.startswith("http://") or source.url.startswith("oci://"), "app ${name}: a Helm repository is an http(s):// index or an oci:// registry, got '${source.url}'"

schema Team:
    """
    One application team: a namespace, and the apps that land in it.

    The team does not own the Component XRs (those live in the fleet namespace
    so ordering works) — it owns what they deliver, and `namespace` is where
    that lands unless an app overrides `targetNamespace`.
    """
    name: str
    namespace: str

    # Emit the Namespace object. False when something else owns it — a tenant
    # controller, a Terraform run, or a cluster where it already exists.
    createNamespace: bool = True
    # Labels added to the team's Namespace and to every one of its Components.
    labels: {str:str} = {}
    apps: [App]

    check:
        len(apps) > 0, "team ${name} has no apps: delete the entry instead of rendering an empty team"
        len(apps) == len({a.name: 1 for a in apps}), "team ${name}: app names must be unique"

schema Fleet:
    """The whole delivery tree of one cluster: one values file, two layers."""
    name: str = "fleet"

    # Where every Component XR is created. One namespace for the tree, because
    # Component.spec.dependsOn only reaches siblings in the same namespace.
    namespace: str = "flux-system"

    # What must exist before any team's app can work: Crossplane, its providers,
    # the XRDs and Compositions, CRDs, operators.
    platform: [App] = []
    teams: [Team] = []

    # Make every team app depend on every platform app. The barrier that makes
    # this an app of apps; an individual app opts out with waitForPlatform: false.
    waitForPlatform: bool = True

    _platformNames: [str] = [a.name for a in platform]
    _all: [App] = platform + [a for t in teams for a in t.apps]
    _names: [str] = [a.name for a in _all]

    check:
        len(_names) == len({n: 1 for n in _names}), "app names must be unique across the fleet: every app is a Component XR in namespace ${namespace}, and dependsOn resolves by name"
        len(teams) == len({t.name: 1 for t in teams}), "team names must be unique"
        all_true([dep in _names for a in _all for dep in a.dependsOn]), "dependsOn must name another app in this file (platform or team)"
        all_true([dep in _platformNames for a in platform for dep in a.dependsOn]), "a platform app may only depend on another platform app: the platform layer is applied first, so a dependency on a team app would deadlock it"

# ── Derived values ───────────────────────────────────────────────────────────
_labels = lambda f: Fleet, layer: str, team: str -> {str:str} {
    """Identity every rendered object carries. `layer` is the phase selector: `kubectl get component -l platform.example.org/layer=platform`."""
    {
        "app.kubernetes.io/part-of" = f.name
        "app.kubernetes.io/managed-by" = "fleet"
        "platform.example.org/layer" = layer
    } | ({"platform.example.org/team" = team} if team else {})
}

_dependsOn = lambda f: Fleet, a: App, layer: str -> [str] {
    """
    An app's own dependencies, plus the platform barrier for a team app.
    Order is stable (own first, then the platform layer in file order) and
    duplicates are dropped, so the rendered XR does not churn between runs.
    """
    _barrier = f._platformNames if (layer == "application" and (a.waitForPlatform if a.waitForPlatform not in [None, Undefined] else f.waitForPlatform)) else []
    _seen = a.dependsOn
    _seen + [n for n in _barrier if n not in _seen and n != a.name]
}

# ── Renderers ────────────────────────────────────────────────────────────────
_sourceSpec = lambda a: App -> {str:} {
    """`Component.spec.source`. Only the fields that are set are emitted: the XRD applies its own defaults, and an unset `ref` field means "let Flux decide"."""
    _ref = ({tag = a.source.tag} if a.source.tag else {}) | ({branch = a.source.branch} if a.source.branch else {}) | ({semver = a.source.semver} if a.source.semver else {}) | ({digest = a.source.digest} if a.source.digest else {})
    {
        kind = a._kind
        url = a.source.url
        interval = a.source.interval
    } | ({ref = _ref} if _ref else {}) | ({insecure = True} if a.source.insecure else {}) | ({secretRef = a.source.secretRef} if a.source.secretRef else {})
}

_deliverSpec = lambda a: App, namespace: str -> {str:} {
    """
    `Component.spec.deliver`. A helm app becomes a HelmRelease (chart + version
    out of a Helm repository, or chartRef when the source is the artifact);
    kustomize and crossplane become a Kustomization at `path`. The keys the
    other kind ignores are left out rather than sent and dropped.
    """
    _ns = a.targetNamespace or namespace
    _common = {timeout = a.timeout} | ({targetNamespace = _ns} if _ns else {})
    _helm = {kind = "HelmRelease"} | ({chart = a.chart} if a.chart else {}) | ({version = a.version} if a.version else {}) | ({values = a.values} if a.values else {})
    _kustomize = {kind = "Kustomization", path = a.path, prune = a.prune, wait = a.wait}
    _common | (_helm if a.engine == "helm" else _kustomize)
}

_component = lambda f: Fleet, a: App, layer: str, team: str, namespace: str -> {str:} {
    """One app → one Component XR in the fleet namespace."""
    {
        apiVersion = component_api_version
        kind = component_kind
        metadata = {
            name = a.name
            namespace = f.namespace
            labels = _labels(f, layer, team) | {"platform.example.org/engine" = a.engine} | a.labels
        }
        spec = {
            source = _sourceSpec(a)
            deliver = _deliverSpec(a, namespace)
            interval = a.interval
            if _dependsOn(f, a, layer):
                dependsOn = _dependsOn(f, a, layer)
            if a.suspend:
                suspend = True
            if a.serviceAccount:
                serviceAccountName = a.serviceAccount
        }
    }
}

_namespace = lambda f: Fleet, t: Team -> corev1.Namespace {
    corev1.Namespace {
        metadata = {
            name = t.namespace
            labels = _labels(f, "application", t.name) | t.labels
        }
    }
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda f: Fleet -> [any] {
    """
    Every manifest for a Fleet, in apply order: the team Namespaces, the
    platform layer's Components, then the teams' Components in file order.

    Apply order is a convenience — the real ordering is `dependsOn` on the
    delivery objects, enforced by the Flux controllers, so the whole stream can
    be applied at once and in any order.
    """
    _namespaces: [any] = [_namespace(f, t) for t in f.teams if t.createNamespace]
    _platform: [any] = [_component(f, a, "platform", "", a.targetNamespace or "") for a in f.platform]
    _apps: [any] = [_component(f, a, "application", t.name, t.namespace) for t in f.teams for a in t.apps]
    _namespaces + _platform + _apps
}
