"""
Local platform — one values file, composed from three other packages.

  values.yaml ──► Platform ──┬─► cluster.kind.Cluster    (-D output=kind)   → kind create cluster --config -
                             └─► manifests               (default)          → kubectl apply -f -
                                   ├─ engine flux:   manager.render → HelmRepository + HelmRelease per chart
                                   └─ engine argocd: one Argo CD Application per chart (+ OCI repo Secrets)

What each imported package owns, so nothing is re-implemented here:

  • cluster.kind      the Kind config: node layout, the ingress-ready control
                      plane, the tainted `dedicated=database` worker pool.
                      `cluster.dbWorkers` here is its `db_workers` option.
  • manager           the dependency model: `manager.Dependency` rows, the
                      capability `bundles`, the manager/application `type`
                      split, `role` filtering, and every check on top of them
                      (unique names, dependsOn targets, no application → manager
                      edge). The Flux render is `manager.render` as-is.
  • app               `mergeValues`, the deep right-wins merge every values
                      override in this repo uses.
  • providers/argocd, providers/cnpg
                      the typed CRD schemas the Argo CD Applications and the
                      CloudNativePG Cluster are validated against.

What this package adds is the glue a local manager cluster needs, and two
open-source apps that show the two shapes a platform app comes in:

  • postgres (CloudNativePG) — an app that brings KUBERNETES RESOURCES the
    platform runs on: the operator chart, plus the Namespace and the
    `postgresql.cnpg.io/v1 Cluster` holding the platform's own state. The
    Cluster is pinned to the Kind database pool whenever the cluster has one
    (`cluster.dbWorkers > 0`), which is the point of composing the two
    packages in one file: the check that the pool exists runs on `kcl run`,
    not as a Pending pod.
  • metricsServer — an app that is ONLY Helm values: nothing rendered but its
    chart. The values are generated from typed fields with Kind-safe defaults
    (`--kubelet-insecure-tls`, small requests), then `values` is deep-merged
    over them.

Both follow the same override contract: generated defaults, then the
user's map merged over them (maps merge key by key; lists and scalars
replace). `postgres.values` overrides the operator chart, `postgres.database.spec`
the Cluster spec — validated against the CNPG CRD schema after the merge.

Rendered like `manager` and `gitops`:

  kcl run packages/local-platform -D values=<file> [-D env=<env>] [-D output=kind] -q
  # in code:
  import local_platform.lib as platform; platform.render(platform.Platform {**values})
"""

import regex
import k8s.api.core.v1 as corev1
import cluster.kind
import app.lib as app
import manager.lib as manager
import cnpg.models.v1.postgresql_cnpg_io_v1_cluster as pg
import argocd.models.v1alpha1.argoproj_io_v1alpha1_application as application

# Where an Argo CD Application deploys: the cluster Argo CD itself runs in.
in_cluster_server = "https://kubernetes.default.svc"

# Deleting the Application deletes what it deployed, like a pruning HelmRelease.
argocd_cascade_finalizer = "resources-finalizer.argocd.argoproj.io"

# The worker pool cluster.kind labels and taints `dedicated=database:NoSchedule`.
database_pool = "database"

# Dependency names of the two generated apps. An explicit `dependencies` row
# with the same name replaces the generated one (the bundle rule of `manager`).
metrics_server_name = "metrics-server"
postgres_name = "cloudnative-pg"

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Cluster:
  """
    The local Kind cluster: the knobs of `cluster.kind.Cluster`, which are `-D`
    options there and typed fields here, so the file that lists the charts
    also sizes the cluster they land on.
    """
  name: str = "platform-local"
  # plain workers
  workers: int = 1
  # workers labelled and tainted dedicated=database:NoSchedule
  dbWorkers: int = 0
  # map host ports 80/443 to the control plane (labelled ingress-ready=true)
  ingress: bool = False

  check:
    workers >= 0, "cluster.workers must be >= 0"
    dbWorkers >= 0, "cluster.dbWorkers must be >= 0"
    regex.match(name, r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"), "cluster.name '${name}' must be a DNS label: kind builds container and kubeconfig context names from it"

schema MetricsServer:
  """
    metrics-server: an app that needs no platform resources, only Helm values.
    They are generated from the fields below, then `values` is deep-merged
    over them. `kubectl top`, every HorizontalPodAutoscaler and KEDA's CPU /
    memory scalers read it.
    """
  enabled: bool = True
  repo: str = "https://kubernetes-sigs.github.io/metrics-server"
  version: str = "3.14.0"
  namespace: str = "kube-system"
  replicas: int = 1

  # Kind's kubelets serve self-signed certificates: without this flag the
  # scraper rejects every node. Turn it off on a cluster with real certs.
  insecureKubeletTLS: bool = True
  # ServiceMonitor for kube-prometheus-stack (the `sre` bundle); needs its CRDs.
  serviceMonitor: bool = False
  # raw chart values, deep-merged over the generated ones
  values: {str:} = {}

  check:
    replicas >= 1, "metricsServer.replicas must be >= 1"

schema Database:
  """
    The CloudNativePG `Cluster` the platform keeps its own state in. Generated
    from the fields below; `spec` is deep-merged over the generated spec and
    the result is validated against the CNPG CRD schema.
    """
  name: str = "platform-db"
  namespace: str = "platform"
  instances: int = 1
  storage: str = "1Gi"
  # bootstrap.initdb: the application database and the role that owns it
  database: str = "platform"
  owner: str = "platform"
  # pin a PostgreSQL image; unset → the operator's default
  imageName?: str
  # Pin the instances to the Kind database pool (nodeSelector + toleration).
  # Unset → pinned exactly when the cluster has one (cluster.dbWorkers > 0).
  dedicated?: bool
  # raw Cluster.spec, deep-merged over the generated one
  spec: {str:} = {}

  check:
    instances >= 1, "postgres.database.instances must be >= 1"

schema Postgres:
  """
    CloudNativePG: an app that brings Kubernetes resources the platform needs.
    The operator chart (generated values, `values` merged over them), plus the
    Namespace and the `Cluster` in `database` — instances of the CRDs the
    chart installs.
    """
  enabled: bool = True
  repo: str = "https://cloudnative-pg.github.io/charts"
  version: str = "0.29.2"
  # where the operator runs
  namespace: str = "cnpg-system"
  # raw chart values, deep-merged over the generated ones
  values: {str:} = {}
  database: Database = Database {}

schema ArgoCD:
  """Argo CD settings, read only when `engine` is argocd."""
  project: str = "default"
  server: str = in_cluster_server
  prune: bool = True
  selfHeal: bool = True

# ── Generated values ─────────────────────────────────────────────────────────
metricsServerValues = lambda m: MetricsServer -> {str:} {
  """metrics-server chart values: the generated defaults, then `values` over them."""
  _generated = {
    replicas = m.replicas
    # appended to the chart's defaultArgs
    args = ["--kubelet-insecure-tls"] if m.insecureKubeletTLS else []
    resources.requests = {cpu = "50m", memory = "64Mi"}
    metrics.enabled = m.serviceMonitor
    serviceMonitor.enabled = m.serviceMonitor
  }
  app.mergeValues(_generated, m.values)
}

postgresValues = lambda p: Postgres -> {str:} {
  """cloudnative-pg chart values: the generated defaults, then `values` over them."""
  _generated = {
    # the Cluster below is an instance of these CRDs
    crds.create = True
    config.clusterWide = True
    resources.requests = {cpu = "50m", memory = "128Mi"}
  }
  app.mergeValues(_generated, p.values)
}

_metricsServerDependency = lambda m: MetricsServer -> manager.Dependency {
  manager.Dependency {
    name = metrics_server_name
    $type = "application"
    repo = m.repo
    version = m.version
    namespace = m.namespace
    values = metricsServerValues(m)
  }
}

_postgresDependency = lambda p: Postgres -> manager.Dependency {
  manager.Dependency {
    name = postgres_name
    $type = "application"
    repo = p.repo
    version = p.version
    namespace = p.namespace
    values = postgresValues(p)
  }
}

# Longest dependsOn chain below `n`: the Argo CD sync wave. `budget` bounds the
# recursion; a cycle exhausts it and returns len(edges), which Platform rejects.
_depth = lambda edges: {str:[str]}, n: str, budget: int -> int {
  _next = [e for e in edges[n] if e in edges] if n in edges else []
  0 if not _next else len(edges) if budget <= 0 else 1 + max([_depth(edges, e, budget - 1) for e in _next])
}

schema Platform:
  """
    A local cluster and everything delivered onto it, in one object.

    `role` and `bundles` / `dependencies` are `manager`'s, unchanged: a
    `manager` cluster gets every row, a `workload` cluster the `application`
    rows only. The two generated apps join `dependencies` as `application`
    rows, so they land on both kinds of cluster.
    """
  # labels everything app.kubernetes.io/part-of
  name: str = "local"

  # Which GitOps engine reconciles the charts. It must already be running:
  # nothing here installs Flux or Argo CD.
  engine: "flux" | "argocd" = "flux"
  role: "manager" | "workload" = "manager"
  # where the HelmRepository / HelmRelease or Application objects live
  namespace: str = "argocd" if engine == "argocd" else "flux-system"
  cluster: Cluster = Cluster {}
  bundles: [manager.Bundle] = []
  dependencies: [manager.Dependency] = []
  metricsServer: MetricsServer = MetricsServer {}
  postgres: Postgres = Postgres {}
  argocd: ArgoCD = ArgoCD {}

  _explicit = {d.name: 1 for d in dependencies}
  _generated: [manager.Dependency] = ([_metricsServerDependency(metricsServer)] if metricsServer.enabled else []) + ([_postgresDependency(postgres)] if postgres.enabled else [])

  # `manager` owns the bundle merge, the role filter and the dependency
  # checks; this schema only feeds it rows.
  _manager: manager.Manager = manager.Manager {
    name = name
    role = role
    namespace = namespace
    dependencies = dependencies + [d for d in _generated if d.name not in _explicit]
    bundles = bundles
  }
  _installed: [manager.Dependency] = _manager._deps if role == "manager" else [d for d in _manager._deps if d.$type == "application"]
  _edges: {str:[str]} = {d.name: d.dependsOn for d in _installed}
  _waves: {str:int} = {d.name: _depth(_edges, d.name, len(_edges)) for d in _installed}
  _dedicated: bool = postgres.database.dedicated if postgres.database.dedicated not in [None, Undefined] else cluster.dbWorkers > 0

  check:
    all_true([w < len(_installed) for _, w in _waves]), "dependsOn has a cycle: ${_edges}"
    not (postgres.enabled and _dedicated) or cluster.dbWorkers > 0, "postgres.database.dedicated pins the instances to the database pool, but cluster.dbWorkers is 0: they would stay Pending"
    not postgres.enabled or postgres_name in _waves, "postgres is enabled but the ${postgres_name} dependency does not install on a ${role} cluster: its Cluster would have no operator"
    engine != "argocd" or all_true([not (d.valuesFrom or d.postRenderers or d.secretRef or d.provider) for d in _installed]), "engine argocd: valuesFrom / postRenderers / secretRef / provider are Flux-only fields and would be dropped: ${[d.name for d in _installed if d.valuesFrom or d.postRenderers or d.secretRef or d.provider]}"

# ── Kind ─────────────────────────────────────────────────────────────────────
kindConfig = lambda p: Platform -> kind.Cluster {
  """The Kind config for `p.cluster`: `kind create cluster --config <this>`."""
  kind.Cluster {
    name = p.cluster.name
    _workers = p.cluster.workers
    _db_workers = p.cluster.dbWorkers
    _ingress = p.cluster.ingress
  }
}

# ── Manifests ────────────────────────────────────────────────────────────────
_labels = lambda p: Platform -> {str:str} {
  {"app.kubernetes.io/managed-by" = "local-platform", "app.kubernetes.io/part-of" = p.name}
}

# The CNPG Cluster is an instance of a CRD the chart installs. Argo CD: one
# wave after the operator, and skip the dry run that would fail before the CRD
# exists. Flux: same stream as the HelmRelease, so a bare cluster needs a
# second apply once helm-controller reports cloudnative-pg Ready.
_postgresObjects = lambda p: Platform -> [any] {
  _d = p.postgres.database
  _argo = {
    "argocd.argoproj.io/sync-wave" = str(p._waves[postgres_name] + 1)
    "argocd.argoproj.io/sync-options" = "SkipDryRunOnMissingResource=true"
  }
  _generated = {
    instances = _d.instances
    # one instance cannot satisfy a PDB: it would block every node drain
    enablePDB = _d.instances > 1
    storage.size = _d.storage
    bootstrap.initdb = {database = _d.database, owner = _d.owner}
    if _d.imageName:
      imageName = _d.imageName
    if p._dedicated:
      affinity = {
        nodeSelector.dedicated = database_pool
        tolerations = [{key = "dedicated", operator = "Equal", value = database_pool, effect = "NoSchedule"}]
      }
  }
  [
    corev1.Namespace {
      metadata = {name = _d.namespace, labels = _labels(p)}
    }
    pg.Cluster {
      metadata = {
        name = _d.name
        namespace = _d.namespace
        labels = _labels(p) | {"platform.example.org/type" = "application"}
        if p.engine == "argocd":
          annotations = _argo
      }
      spec = app.mergeValues(_generated, _d.spec)
    }
  ]
}

# Argo CD reads a Helm OCI registry as host/path without the scheme, and only
# after a repository Secret marks it enableOCI.
_argoRepo = lambda repo: str -> str {
  repo.removeprefix("oci://")
}

_ociRepoSecret = lambda p: Platform, repo: str -> corev1.Secret {
  _url = _argoRepo(repo)
  _name = "helm-oci-" + regex.replace(_url.lower(), r"[^a-z0-9]+", "-").strip("-")
  corev1.Secret {
    metadata = {
      name = _name
      namespace = p.namespace
      labels = _labels(p) | {"argocd.argoproj.io/secret-type" = "repository"}
      annotations = {"argocd.argoproj.io/sync-wave" = "-1"}
    }
    stringData = {"name" = _name, "type" = "helm", "url" = _url, "enableOCI" = "true"}
  }
}

_application = lambda p: Platform, d: manager.Dependency -> application.Application {
  application.Application {
    metadata = {
      name = d.name
      namespace = p.namespace
      labels = _labels(p) | {"platform.example.org/type" = d.$type}
      # dependsOn → waves. They order the Applications when a parent
      # Application syncs this stream and Argo CD's health check for
      # argoproj.io/Application is enabled (off by default since 1.8);
      # applied with kubectl, every Application syncs at once.
      annotations = {"argocd.argoproj.io/sync-wave" = str(p._waves[d.name])}
      finalizers = [argocd_cascade_finalizer]
    }
    spec = {
      project = p.argocd.project
      source = {
        repoURL = _argoRepo(d.repo)
        chart = d.chart or d.name
        targetRevision = d.version or "*"
        helm = {releaseName = d.name} | ({valuesObject = d.values} if d.values else {})
      }
      destination = {server = p.argocd.server, namespace = d.namespace or d.name}
      syncPolicy = {
        automated = {prune = p.argocd.prune, selfHeal = p.argocd.selfHeal}
        # ServerSideApply: CRDs such as kube-prometheus-stack's exceed
        # the client-side last-applied annotation limit.
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
      }
    }
  }
}

_argoObjects = lambda p: Platform -> [any] {
  _oci = {d.repo: 1 for d in p._installed if d.repo.startswith("oci://")}
  [_ociRepoSecret(p, r) for r in _oci] + [_application(p, d) for d in p._installed]
}

# ── Public API ───────────────────────────────────────────────────────────────
render = lambda p: Platform -> [any] {
  """
    All manifests for a Platform, in apply order. Flux: `manager.render` (a
    HelmRepository + HelmRelease per chart), then the postgres Namespace and
    Cluster. Argo CD: a repository Secret per OCI registry, an Application per
    chart, then the same postgres objects.
    """
  _charts: [any] = manager.render(p._manager) if p.engine == "flux" else _argoObjects(p)
  _charts + (_postgresObjects(p) if p.postgres.enabled else [])
}
