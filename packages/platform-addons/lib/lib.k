"""
Client platform addons: detection rows in, Flux or Argo CD install objects
out (contract §2, §3).

The ClientPlatform controller (kcl-operator) scans a client's repositories
before they are applied and passes what it saw as `params`:

  detected   one row per (group, kind), with the spec.provider values seen
  provided   groups the client defines itself (its own CRDs and XRDs)
  previous   addons state.json says are installed
  config     the client's ClientConfig from its bucket

`plan` maps detection onto the catalog (catalog.k) and returns the plan the
operator reads:

  items      Flux HelmRepository/HelmRelease, GitRepository/OCIRepository/
             Kustomization, or Argo CD Applications. Only kinds whose CRDs
             exist before any addon is installed: the KclModule dry-run
             rejects an unknown kind for the whole render, so a Provider or a
             ClusterProviderConfig here would block every install.
  addons     per addon: installed, required, why, and what it depends on
  unmapped   detected groups no addon serves
  warnings   detection the plan deliberately ignores

Installs are sticky. An addon stays installed after its last detected object
goes (`previous`) until the config says `remove: true`; the operator owns the
state, this package only applies the formula.

  import platform_addons.lib as addons; addons.plan(addons.Params {**params})
"""
import regex

# ── Constants ────────────────────────────────────────────────────────────────
addon_label = "platform.shluviza.com/addon"
managed_by = "platform-addons"
argocd_namespace = "argocd"
in_cluster_server = "https://kubernetes.default.svc"
argocd_cascade_finalizer = "resources-finalizer.argocd.argoproj.io"
# The Config Management Plugin gitops' Argo CD runs for every substituting
# Application (vendor/gitops/argocd/install/cmp-flux-envsubst.yaml). Env FOO
# arrives as ARGOCD_ENV_FOO; the plugin strips the prefix and runs
# `kubectl kustomize . | flux envsubst --strict`.
argocd_envsubst_plugin = "flux-envsubst"

# Kinds the plan may emit: their CRDs ship with Flux or Argo CD itself.
allowed_kinds = [
    "source.toolkit.fluxcd.io/v1/GitRepository"
    "source.toolkit.fluxcd.io/v1/OCIRepository"
    "source.toolkit.fluxcd.io/v1/HelmRepository"
    "helm.toolkit.fluxcd.io/v2/HelmRelease"
    "kustomize.toolkit.fluxcd.io/v1/Kustomization"
    "argoproj.io/v1alpha1/Application"
    "v1/Namespace"
    "v1/ConfigMap"
    # Argo CD repository declarations (`argocd.argoproj.io/secret-type:
    # repository`); credential-free, only for OCI Helm repos.
    "v1/Secret"
]

# Groups every cluster serves (or that Flux and Argo CD bring): never mapped,
# never unmapped.
builtin_groups = [
    ""
    "apps"
    "batch"
    "autoscaling"
    "policy"
    "rbac.authorization.k8s.io"
    "networking.k8s.io"
    "storage.k8s.io"
    "scheduling.k8s.io"
    "coordination.k8s.io"
    "discovery.k8s.io"
    "node.k8s.io"
    "admissionregistration.k8s.io"
    "apiextensions.k8s.io"
    "apiregistration.k8s.io"
    "certificates.k8s.io"
    "flowcontrol.apiserver.k8s.io"
    "kustomize.config.k8s.io"
    "source.toolkit.fluxcd.io"
    "kustomize.toolkit.fluxcd.io"
    "helm.toolkit.fluxcd.io"
    "notification.toolkit.fluxcd.io"
    "image.toolkit.fluxcd.io"
]
# argoproj.io is Argo CD's own only for these; Rollouts and analyses map to
# argo-rollouts.
argocd_kinds = ["Application", "AppProject", "ApplicationSet"]

# ── Input schemas (contract §2, §3) ──────────────────────────────────────────
schema Detected:
    group: str
    kind: str
    version?: str
    versions: [str] = []
    count: int = 0
    providers: [str] = []
    sources: [str] = []

schema HelmSpec:
    repo: str
    chart: str
    version: str
    releaseName?: str

schema KustomizeSpec:
    platformPath?: str
    url?: str
    ref?: str
    path?: str

    check:
        (platformPath and not url) or (url and ref and path and not platformPath), "kustomize needs platformPath, or url + ref + path"

schema ManifestsSpec:
    url: str
    ref: str
    path: str = "./"

schema AddonConfig:
    """
    One `config.addons` entry. For a catalog addon only `version`, `values`
    and `namespace` override it; anything else names a custom addon, which
    needs exactly one of helm, kustomize or manifests.
    """
    enabled?: bool
    remove: bool = False
    version?: str
    values: {str:any} = {}
    # The operator resolves it into `values` before rendering.
    valuesFile?: any
    namespace?: str
    helm?: HelmSpec
    kustomize?: KustomizeSpec
    manifests?: ManifestsSpec
    dependsOn: [str] = []

schema FluxSourceRef:
    kind: "GitRepository" | "OCIRepository" | "Bucket" = "GitRepository"
    name: str = "flux-system"
    namespace: str = "flux-system"

schema ArgoSourceRef:
    repoURL: str = "https://github.com/shluviza/gitops.git"
    targetRevision: str = "main"

schema PlatformSource:
    flux: FluxSourceRef = FluxSourceRef {}
    argo: ArgoSourceRef = ArgoSourceRef {}

schema Crossplane:
    families: [str] = []
    extraClouds: [str] = []
    vars: {str:str} = {}

schema ClientConfig:
    apiVersion: str = "platform.shluviza.com/v1alpha1"
    kind: str = "ClientConfig"
    cloud: "gcp" | "aws" | "azure"
    delivery: "flux" | "argo" = "flux"
    namespace: str = "flux-system"
    platformSource: PlatformSource = PlatformSource {}
    crossplane: Crossplane = Crossplane {}
    addons: {str:AddonConfig} = {}

    check:
        all c in crossplane.extraClouds { c in ["gcp", "aws", "azure"] }, "crossplane.extraClouds: ${crossplane.extraClouds} must be gcp, aws or azure"
        all f in crossplane.families { f in families[cloud] }, "crossplane.families: ${crossplane.families} must be families of ${cloud}: ${families[cloud]}"
        not [n for n, a in addons if a.valuesFile], "addons ${[n for n, a in addons if a.valuesFile]}: valuesFile must arrive resolved into values (the operator reads it from the client source)"

schema Params:
    client: str
    config: ClientConfig
    detected: [Detected] = []
    provided: [str] = []
    previous: [str] = []

    _catalogNames = [a.name for a in catalog]
    _badCustom = [n for n, c in config.addons if n not in _catalogNames and len([x for x in [c.helm, c.kustomize, c.manifests] if x]) != 1]
    # Built only from valid entries, so the check below reports the entry
    # rather than the Addon schema failing on an empty row.
    _rows = rows(config) if not _badCustom else {}
    _badRequires = ["${n} -> ${q}" for n, a in _rows for q in a.requires if q not in _rows]
    _cycles = [" -> ".join(c) for c in [find_cycle(_rows, n, []) for n in _rows] if c] if not _badRequires else []

    check:
        not _badCustom, "addons ${_badCustom}: a custom addon needs exactly one of helm, kustomize or manifests"
        not _badRequires, "unknown requires/dependsOn: ${_badRequires}"
        not _cycles, "requires cycle: ${_cycles[0] if _cycles else ''}"

# ── Output schema ────────────────────────────────────────────────────────────
schema AddonStatus:
    name: str
    installed: bool
    required: bool
    reasons: [str]
    dependsOn: [str]

schema Plan:
    items: [{str:any}]
    addons: [AddonStatus]
    unmapped: [str]
    warnings: [str]

    _bad = ["${i.apiVersion}/${i.kind}" for i in items if "${i.apiVersion}/${i.kind}" not in allowed_kinds]

    check:
        not _bad, "items may only hold kinds whose CRDs exist before any addon is installed; got ${_bad}"

# ── Helpers ──────────────────────────────────────────────────────────────────
uniq = lambda l: [any] -> [any] {
    """Drop repeats, keep first-seen order."""
    [x for i, x in l if x not in l[:i]]
}

merge = lambda a: {str:any}, b: {str:any} -> {str:any} {
    """Deep merge, right wins; lists replace."""
    {k: (merge(a[k], b[k]) if typeof(a[k]) == "dict" and typeof(b[k]) == "dict" else b[k]) if k in b else a[k] for k in [x for x in a] + [x for x in b if x not in a]}
}

find_cycle = lambda rows: {str:}, name: str, path: [str] -> [str] {
    """The first requires cycle through `name`, as a path, or []."""
    found = [c for c in [find_cycle(rows, q, path + [name]) for q in rows[name].requires if q in rows] if c] if name not in path else []
    path + [name] if name in path else (found[0] if found else [])
}

_customRow = lambda name: str, c: AddonConfig -> Addon {
    Addon {
        name = name
        namespace = c.namespace or name
        requires = c.dependsOn
        helm = [{
            repo = c.helm.repo
            chart = c.helm.chart
            version = c.version or c.helm.version
            releaseName = c.helm.releaseName
            values = c.values
        }] if c.helm else []
        kustomize = [{
            platformPath = c.kustomize.platformPath
            url = c.kustomize.url
            ref = c.version or c.kustomize.ref
            path = c.kustomize.path
        }] if c.kustomize else []
        manifests = [{
            url = c.manifests.url
            ref = c.version or c.manifests.ref
            path = c.manifests.path
        }] if c.manifests else []
    }
}

# A catalog addon: `version` and `values` reach its first Helm release (the
# main chart; istiod for istio), or its first manifests ref.
_overrideRow = lambda a: Addon, c: AddonConfig -> Addon {
    Addon {
        **a
        namespace = c.namespace or a.namespace
        helm = [Helm {**h, version = c.version or h.version, values = merge(h.values, c.values)} if i == 0 else h for i, h in a.helm]
        manifests = [Manifests {**m, ref = c.version or m.ref} if i == 0 and not a.helm else m for i, m in a.manifests]
    }
}

rows = lambda cfg: ClientConfig -> {str:Addon} {
    """The catalog with config overrides applied, plus the custom addons."""
    _names = [a.name for a in catalog]
    {
        **{a.name: _overrideRow(a, cfg.addons[a.name]) if a.name in cfg.addons else a for a in catalog}
        **{n: _customRow(n, c) for n, c in cfg.addons if n not in _names}
    }
}

_gated = lambda row: Addon, allowed: [str] -> bool {
    bool(row.cloud) and row.cloud not in allowed
}

_gateMsg = lambda row: Addon, cfg: ClientConfig -> str {
    "${row.name} is for cloud ${row.cloud}, but config.cloud is ${cfg.cloud} and ${row.cloud} is not in crossplane.extraClouds"
}

_builtin = lambda d: Detected -> bool {
    d.group in builtin_groups or (d.group == "argoproj.io" and d.kind in argocd_kinds)
}

_triggered = lambda t: Trigger, d: Detected -> bool {
    (d.group == t.group if t.group else d.group.endswith(t.suffix)) and (not t.kinds or d.kind in t.kinds)
}

_scan = lambda rs: {str:Addon}, cfg: ClientConfig, allowed: [str], d: Detected -> {str:any} {
    """One detected row -> [addon, reason] hits, warnings, unmapped."""
    gk = "${d.group}/${d.kind}"
    matched = [a for _, a in rs if any t in a.triggers { _triggered(t, d) }]
    targets = [[a.name, gk] for a in matched] + [[t, "${gk} provider=${p}"] for a in matched for p in d.providers if p in a.providers for t in a.providers[p]] + [[t, "${gk} cloud=${cfg.cloud}"] for a in matched if cfg.cloud in a.cloudRequires for t in a.cloudRequires[cfg.cloud]]
    {
        hits = [x for x in targets if not _gated(rs[x[0]], allowed)]
        warnings = ["${x[1]}: ${_gateMsg(rs[x[0]], cfg)}" for x in targets if _gated(rs[x[0]], allowed)] + ["${gk}: unknown provider \"${p}\"; ${a.name} knows ${sorted(a.providers)}" for a in matched if a.providers for p in d.providers if p not in a.providers]
        unmapped = [] if matched else [gk]
    }
}

_reach = lambda rs: {str:Addon}, blocked: [str], name: str -> [str] {
    """`name` and everything it requires, transitively, minus `blocked`."""
    [name] + [x for q in rs[name].requires if q not in blocked for x in _reach(rs, blocked, q)]
}

_closure = lambda rs: {str:Addon}, blocked: [str], names: [str] -> [str] {
    uniq([x for n in names if n not in blocked for x in _reach(rs, blocked, n)])
}

# ── Units: one install object per Helm release, kustomize path or directory ─
units = lambda a: Addon -> [{str:any}] {
    [{type = "helm", id = u.id, spec = u} for u in a.helm] + [{type = "kustomize", id = u.id, spec = u} for u in a.kustomize] + [{type = "manifests", id = u.id, spec = u} for u in a.manifests]
}

object_name = lambda addon: str, id -> str {
    "${addon}-${id}" if id and id != addon else addon
}

_unitOf = lambda a: Addon, ref: str -> {str:any} {
    [u for u in units(a) if (u.id == ref) or (not u.id and ref == a.name)][0]
}

_unitDepth = lambda rs: {str:Addon}, inst: [str], a: Addon, u: {str:any} -> int {
    ds = [_unitDepth(rs, inst, a, _unitOf(a, d)) + 1 for d in u.spec.dependsOn] + [addon_depth(rs, inst, q) + 1 for q in a.requires if q in inst]
    max(ds) if ds else 0
}

addon_depth = lambda rs: {str:Addon}, inst: [str], name: str -> int {
    max([_unitDepth(rs, inst, rs[name], u) for u in units(rs[name])])
}

_labels = lambda name: str -> {str:str} {
    {
        "platform.shluviza.com/addon" = name
        "app.kubernetes.io/managed-by" = managed_by
    }
}

_isTag = lambda ref: str -> bool {
    regex.match(ref, r"^v?[0-9]+(\.[0-9]+)*")
}

# Same-type dependency names: sibling units by id, and every unit of each
# installed required addon. Flux dependsOn only reaches its own kind; the
# order across a HelmRelease and a Kustomization comes from Flux retrying
# until the CRDs it needs exist.
_deps = lambda rs: {str:Addon}, inst: [str], a: Addon, u: {str:any}, types: [str] -> [str] {
    [object_name(a.name, _unitOf(a, d).id) for d in u.spec.dependsOn if _unitOf(a, d).type in types] + [object_name(q, v.id) for q in a.requires if q in inst for v in units(rs[q]) if v.type in types and not (v.type == "kustomize" and v.spec.leaf)]
}

# ── Flux ─────────────────────────────────────────────────────────────────────
_fluxUnit = lambda rs: {str:Addon}, inst: [str], cfg: ClientConfig, a: Addon, u: {str:any} -> [{str:any}] {
    name = object_name(a.name, u.id)
    meta = {name = name, namespace = cfg.namespace, labels = _labels(a.name)}
    s = u.spec
    helmDeps = [{name = d} for d in _deps(rs, inst, a, u, ["helm"])]
    ksDeps = [{name = d} for d in _deps(rs, inst, a, u, ["kustomize", "manifests"])]
    vars = cfg.crossplane.vars
    url = s.url if u.type != "helm" else ""
    gitSource = [{
        apiVersion = "source.toolkit.fluxcd.io/v1"
        kind = "OCIRepository" if url.startswith("oci://") else "GitRepository"
        metadata = meta
        spec = {
            interval = "1h"
            url = url
            ref = {tag = s.ref} if url.startswith("oci://") or _isTag(s.ref) else {branch = s.ref}
        }
    }] if url else []
    sourceRef = {kind = gitSource[0].kind, name = name, namespace = cfg.namespace} if url else {
        kind = cfg.platformSource.flux.kind
        name = cfg.platformSource.flux.name
        namespace = cfg.platformSource.flux.namespace
    }
    [
        {
            apiVersion = "source.toolkit.fluxcd.io/v1"
            kind = "HelmRepository"
            metadata = meta
            spec = {
                interval = "12h"
                url = s.repo
                if s.repo.startswith("oci://"):
                    type = "oci"
            }
        }
        {
            apiVersion = "helm.toolkit.fluxcd.io/v2"
            kind = "HelmRelease"
            metadata = meta
            spec = {
                interval = "30m"
                timeout = "10m"
                releaseName = s.releaseName or name
                targetNamespace = a.namespace
                storageNamespace = a.namespace
                chart.spec = {
                    chart = s.chart
                    version = s.version
                    sourceRef = {kind = "HelmRepository", name = name}
                }
                install = {
                    createNamespace = True
                    crds = "CreateReplace"
                    remediation.retries = 3
                }
                upgrade = {
                    crds = s.upgradeCrds
                    remediation.retries = 3
                }
                if s.values:
                    values = s.values
                if helmDeps:
                    dependsOn = helmDeps
            }
        }
    ] if u.type == "helm" else gitSource + [{
        apiVersion = "kustomize.toolkit.fluxcd.io/v1"
        kind = "Kustomization"
        metadata = meta
        spec = {
            interval = "10m"
            timeout = "10m"
            # A path whose CRDs another addon brings fails its dry-run until
            # they exist; retry sooner than `interval`.
            retryInterval = "1m"
            path = s.path if url else s.platformPath
            prune = True
            wait = True
            sourceRef = sourceRef
            if ksDeps:
                dependsOn = ksDeps
            if u.type == "kustomize" and s.substitute and vars:
                postBuild.substitute = vars
        }
    }]
}

# ── Argo CD ──────────────────────────────────────────────────────────────────
_argoUnit = lambda rs: {str:Addon}, inst: [str], cfg: ClientConfig, a: Addon, u: {str:any} -> [{str:any}] {
    s = u.spec
    platform = u.type == "kustomize" and not s.url
    repoURL = cfg.platformSource.argo.repoURL if platform else (s.repo.removeprefix("oci://") if u.type == "helm" else s.url)
    source = {
        repoURL = repoURL
        if u.type == "helm":
            chart = s.chart
            targetRevision = s.version
            helm = {
                releaseName = s.releaseName or object_name(a.name, u.id)
                if s.values:
                    valuesObject = s.values
            }
        elif platform:
            targetRevision = cfg.platformSource.argo.targetRevision
            path = s.platformPath.removeprefix("./")
            if s.substitute:
                plugin = {
                    name = argocd_envsubst_plugin
                    if cfg.crossplane.vars:
                        env = [{name = k, value = v} for k, v in cfg.crossplane.vars]
                }
        else:
            targetRevision = s.ref
            path = s.path.removeprefix("./") or "."
            if u.type == "manifests":
                directory.recurse = True
    }
    ociRepo = [{
        # Argo CD reads a Helm repoURL without a scheme as OCI only when a
        # repository declares it with enableOCI, public registries included.
        apiVersion = "v1"
        kind = "Secret"
        metadata = {
            name = "repo-${object_name(a.name, u.id)}"
            namespace = argocd_namespace
            labels = _labels(a.name) | {"argocd.argoproj.io/secret-type" = "repository"}
        }
        stringData = {
            type = "helm"
            name = object_name(a.name, u.id)
            url = repoURL
            enableOCI = "true"
        }
    }] if u.type == "helm" and s.repo.startswith("oci://") else []
    ociRepo + [{
        apiVersion = "argoproj.io/v1alpha1"
        kind = "Application"
        metadata = {
            name = object_name(a.name, u.id)
            namespace = argocd_namespace
            labels = _labels(a.name)
            annotations = {"argocd.argoproj.io/sync-wave" = str(_unitDepth(rs, inst, a, u))}
            finalizers = [argocd_cascade_finalizer]
        }
        spec = {
            project = "default"
            destination = {server = in_cluster_server, namespace = a.namespace}
            source = source
            syncPolicy = {
                automated = {prune = True, selfHeal = True}
                syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
            }
        }
    }]
}

# ── Plan ─────────────────────────────────────────────────────────────────────
plan = lambda p: Params -> Plan {
    cfg = p.config
    rs = rows(cfg)
    allowed = [cfg.cloud] + cfg.crossplane.extraClouds
    gated = [n for n, a in rs if _gated(a, allowed)]
    removed = [n for n, c in cfg.addons if c.remove or c.enabled == False]
    forced = ["crossplane-${cfg.cloud}-${f}" for f in cfg.crossplane.families]
    enabled = [n for n, c in cfg.addons if c.enabled == True] + forced

    scans = [_scan(rs, cfg, allowed, d) for d in p.detected if d.group not in p.provided and not _builtin(d)]
    hits = [h for s in scans for h in s.hits]
    required = _closure(rs, gated, uniq([h[0] for h in hits]))
    candidates = [n for n in uniq(required + [x for x in p.previous if x in rs] + enabled) if n not in removed and n not in gated]
    installed = _closure(rs, gated + removed, candidates)

    # "previous" only when stickiness is what keeps an addon installed: a
    # required or removed addon would otherwise gain or lose it on the render
    # after its first state write, and that alone rewrites state.json and the
    # KclModule once more.
    reasons = lambda n: str -> [str] {
        uniq([h[1] for h in hits if h[0] == n] + ["requires:${q}" for q in required if n in rs[q].requires] + (["previous"] if n in p.previous and n in installed and n not in required else []) + (["config"] if n in enabled else []) + ["requires:${q}" for q in installed if n in rs[q].requires])
    }
    names = sorted(uniq(required + installed + p.previous + [n for n in cfg.addons] + forced))
    substituting = [n for n in installed if any u in rs[n].kustomize { u.substitute }]

    warnings = [w for s in scans for w in s.warnings] + ["${n} is required by ${[r for r in reasons(n) if r not in ['config', 'previous']]} but config.addons.${n} removes it" for n in required if n in removed] + ["${n} requires ${q}: ${_gateMsg(rs[q], cfg)}" for n in uniq(required + installed) for q in rs[n].requires if q in gated] + ["${n} requires ${q}, which config.addons.${q} removes" for n in installed for q in rs[n].requires if q in removed] + ["previous addon ${n} is neither in the catalog nor in config.addons" for n in p.previous if n not in rs] + ["${n}: ${_gateMsg(rs[n], cfg)}; left uninstalled" for n in p.previous if n in gated] + (["crossplane.vars is empty, but ${substituting} substitute it" if cfg.delivery == "flux" else "crossplane.vars is empty, but ${substituting} substitute it; the flux-envsubst plugin fails on unset variables"] if substituting and not cfg.crossplane.vars else [])

    emit = _fluxUnit if cfg.delivery == "flux" else _argoUnit
    Plan {
        items = [o for n in sorted(installed) for u in units(rs[n]) for o in emit(rs, installed, cfg, rs[n], u)]
        addons = [{
            name = n
            installed = n in installed
            required = n in required
            reasons = reasons(n)
            dependsOn = rs[n].requires if n in rs else []
        } for n in names]
        unmapped = sorted(uniq([u for s in scans for u in s.unmapped]))
        warnings = sorted(uniq(warnings))
    }
}
