"""
GitOps for a self-hosted forge — typed schemas + renderers.

One values file closes the loop between a seed repository on GitHub and a
Forgejo instance this platform runs:

  1. A GitOps engine reads the cluster's desired state from the seed repo
     (`source.origin: github`). `engine` picks which one: `flux` (default)
     renders a GitRepository + Kustomization, `argocd` an AppProject +
     Application — either way in `namespace` (flux-system / argocd by
     default).
  2. What that state contains is rendered here too: the tenant Namespace, the
     cluster-scoped `Entitlement` that unlocks the paid capabilities, and the
     `Forge` XR that installs Forgejo through provider-helm.
  3. A `Repository` XR per entry in `repositories` re-creates those
     repositories INSIDE the forge over its REST API — including the gitops
     repo itself.
  4. Once the history has been pushed into the forge, flip
     `source.origin: forge`: the very same values file now points the engine
     at the in-cluster clone URL instead of GitHub, and the cluster reconciles
     from the forge it runs.

Nothing here mirrors git history: neither the `Forge` nor the `Repository`
capability can pull commits from GitHub (the Repository XRD models create /
update / delete over the Forgejo API, not mirroring). Step 3 creates an EMPTY
repository — `autoInit` defaults to false for exactly that reason — and the
push between step 3 and step 4 is a human `git push`, which is why the origin
switch is an explicit field rather than something that flips itself.

The entitlement rules the Compositions enforce at render time in the cluster
are re-stated as `check` blocks below, so a values file that a tenant is not
entitled to fails on `kcl run`, not as a fatal render result three minutes
after `kubectl apply`.

Rendered like `app`, `manager` and `cncf`:

  kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -q
  # in code:
  import gitops.lib as gitops; gitops.render(gitops.Gitops {**values})
"""

import k8s.api.core.v1 as corev1
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_git_repository as gitrepo
import flux_kustomize.models.v1.kustomize_toolkit_fluxcd_io_v1_kustomization as kustomization
import argocd.models.v1alpha1.argoproj_io_v1alpha1_app_project as appproject
import argocd.models.v1alpha1.argoproj_io_v1alpha1_application as application

# The group both capabilities are served under (packages/cloud/*/xrd/xrd.yaml).
cloud_api_version = "cloud.example.org/v1alpha1"
# The Entitlement CRD lives in packages/platform/entitlement/crd.yaml.
platform_api_version = "platform.example.org/v1alpha1"

# The forgejo chart names its web Service "<release>-http" and serves on 3000.
# Both the API root a Repository XR needs and the in-cluster clone URL are
# built from it, so it is spelled once.
http_service_suffix = "-http"
http_port = 3000

# Where an Argo CD Application deploys: the cluster Argo CD itself runs in,
# which is also where the Flux Kustomization applies.
in_cluster_server = "https://kubernetes.default.svc"

# Deleting the Application deletes what it deployed, the way deleting a
# pruning Kustomization garbage-collects its inventory.
argocd_cascade_finalizer = "resources-finalizer.argocd.argoproj.io"

# ── Schemas ──────────────────────────────────────────────────────────────────
schema Quota:
    """Ceilings the Entitlement record puts on the tenant's namespace."""
    # Caps Forge.spec.storageGb. A forge asking for more fails its render.
    storageGb: int = 50
    # Caps how many Repository XRs the namespace may hold.
    repositories: int = 50

    check:
        storageGb > 0, "quota.storageGb must be positive"
        repositories > 0, "quota.repositories must be positive"

schema Tenant:
    """
    The tenant the forge belongs to. A tenant IS a namespace here: the
    Compositions look the grant up by the XR's namespace, so the Entitlement's
    metadata.name must equal `namespace`.
    """
    namespace: str

    # Paid tier. `private` repositories need team or better; highAvailability
    # needs enterprise.
    plan: "free" | "team" | "enterprise" = "team"
    # Feature keys the Compositions check before composing anything.
    features: [str] = ["forgejo", "repository"]
    quota: Quota = Quota {}
    # Free-form billing pointer echoed by the record (subscription id, …).
    reference?: str
    # Emit the Namespace object. False when something else owns it.
    createNamespace: bool = True

    # Emit the cluster-scoped Entitlement. False when billing writes it and
    # this file must not fight that writer.
    manageEntitlement: bool = True

    check:
        "repository" in features, "tenant.features must grant `repository`, or the Forge XR composes nothing"
        "forgejo" in features, "tenant.features must grant `forgejo`, or the Forge XR composes nothing"

schema Database:
    """Where Forgejo keeps its metadata. Chart 17.x bundles no PostgreSQL."""
    mode: "sqlite" | "postgres" = "sqlite"
    # host:port of a server that ALREADY exists (e.g. a Postgres XR next door).
    host?: str
    name?: str
    user?: str
    # Secret whose key holds the single line `PASSWD=<password>`; mounted
    # through gitea.additionalConfigSources so it never enters the Release.
    passwordSecret?: PasswordSecret

    check:
        mode != "postgres" or host, "database.host is required when database.mode is postgres"

schema PasswordSecret:
    name: str
    key: str = "password"

schema Ingress:
    """How the forge is published. The chart serves plain HTTP behind it."""
    enabled: bool = True
    className?: str
    # A TLS Secret covering the hostname also flips ROOT_URL to https.
    tlsSecretName?: str

schema Forge:
    """
    The Forgejo instance, as the `Forge` capability models it. Field-for-field
    the XR's spec, minus what this package computes (the release name is the
    XR name, the XR name is `name`).
    """
    name: str = "git"

    # The name clients resolve: clone URLs, webhooks and OAuth redirects are
    # built from it by Forgejo itself.
    hostname: str
    storageGb: int = 10
    database: Database = Database {}
    ingress: Ingress = Ingress {}
    # Two replicas on one sqlite file corrupt it — hence the check below.
    highAvailability: bool = False
    # Pinned so a re-render never silently upgrades a running forge.
    chartVersion: str = "17.1.5"
    imageTag?: str
    # Existing Secret with `username` / `password`; empty keeps the chart's
    # generated admin.
    adminSecret?: str
    deletionPolicy: "Delete" | "Orphan" = "Delete"
    # Raw chart values, deep-merged last by the Composition.
    values: {str:} = {}

    # Secret in the tenant namespace holding the forge credential under the key
    # `authorization`, whose value is the LITERAL header `token <PAT>`. Every
    # Repository XR reads it; it is never rendered, only referenced.
    tokenSecret: str = "forge-token"

    check:
        storageGb > 0, "forge.storageGb must be positive"
        not highAvailability or database.mode == "postgres", "forge.highAvailability needs database.mode postgres: replicas share one volume and concurrent writers corrupt sqlite"

schema Organization:
    """Attributes of an organization this file owns (createOrganization)."""
    fullName?: str
    description?: str
    visibility: "public" | "limited" | "private" = "private"
    website?: str

schema Webhook:
    """The single push webhook a Repository XR can express."""
    url: str
    # Secret whose key `secret` holds the HMAC shared secret.
    secretRef?: str
    events: [str] = ["push"]
    active: bool = True

schema Repository:
    """
    One repository inside the forge. `name` is the forge-side repository name
    and the XR name; `owner` is the organization (or user) that holds it and
    must exist unless `createOrganization` is set.
    """
    name: str
    owner: str
    description?: str
    private: bool = True
    defaultBranch: str = "main"

    # Create-only, and false on purpose: these repositories are seeded by
    # pushing an existing history, and an initial commit would collide.
    autoInit: bool = False
    license?: str
    gitignores?: str
    readme?: str
    # Owning the organization means deleting this XR deletes the org and every
    # repository in it. Leave false whenever two repositories share an owner.
    createOrganization: bool = False
    organization?: Organization
    webhook?: Webhook
    # Orphan by default: a repository carries history no other object holds.
    deletionPolicy: "Delete" | "Orphan" = "Orphan"

    check:
        not license or autoInit, "repository ${name}: license only applies to an autoInit repository"
        not gitignores or autoInit, "repository ${name}: gitignores only applies to an autoInit repository"
        not readme or autoInit, "repository ${name}: readme only applies to an autoInit repository"
        not organization or createOrganization, "repository ${name}: organization attributes are ignored unless createOrganization is true"

schema Source:
    """
    Where the GitOps engine reads the cluster's desired state from, and the
    one switch that closes the loop: `github` follows `url`, `forge` follows
    the in-cluster clone URL of the `repository` entry below.
    """
    origin: "github" | "forge" = "github"

    # The seed repository. Required for origin `github`; kept (and ignored)
    # after the switch so the way back is one word, not an edit.
    url?: str
    # Flux: GitRepository.spec.ref.branch. Argo CD: Application targetRevision.
    branch: str = "main"
    # Directory inside the repository the engine applies.
    path: str = "./clusters/dev"

    # Flux only: how often the source is polled, and how often the
    # Kustomization runs. Argo CD polls on its controller-wide
    # `timeout.reconciliation` (argocd-cm) and has no per-Application interval.
    interval: str = "1m"
    reconcileInterval: str = "10m"

    # Flux only: Secret in `namespace` with the git credential. Private on
    # both origins: basic-auth (username/password) for GitHub with a PAT, and
    # the same shape for Forgejo. Flux never reads the forge's `authorization`
    # Secret. Argo CD matches credentials to a repository by URL, never by
    # name — `engine: argocd` rejects this field (see Gitops).
    secretRef?: str
    # Flux: Kustomization prune. Argo CD: automated prune plus the cascade
    # finalizer, so deleting the Application garbage-collects like Flux does.
    prune: bool = True

    # Flux only: Kustomization wait / timeout. Argo CD always waits for health
    # between sync waves.
    wait: bool = True
    timeout: str = "5m"

    # Which `repositories` entry to follow once origin is `forge`.
    repository?: str

    check:
        origin != "github" or url, "source.url is required while source.origin is github"
        not url or url.startswith("https://") or url.startswith("http://") or url.startswith("ssh://"), "source.url must be an http(s):// or ssh:// git URL"
        origin != "forge" or repository, "source.origin forge needs source.repository: the clone URL is built from that repository's owner and name"

schema Gitops:
    """
    The whole loop in one object. `render()` emits, in apply order: the tenant
    Namespace, the Entitlement, the Forge XR, one Repository XR per entry, and
    the engine's pair that reconciles the cluster — Flux GitRepository +
    Kustomization, or Argo CD AppProject + Application.
    """
    # Names the engine objects and labels everything app.kubernetes.io/part-of.
    name: str = "gitops"

    # Which GitOps engine reconciles the cluster. It must already be running:
    # nothing here installs Flux or Argo CD.
    engine: "flux" | "argocd" = "flux"

    # Where the engine objects live — the namespace the engine watches. The
    # Forge and its repositories live in `tenant.namespace` instead.
    namespace: str = "argocd" if engine == "argocd" else "flux-system"
    tenant: Tenant
    source: Source
    forge: Forge
    repositories: [Repository] = []

    check:
        engine != "argocd" or not source.secretRef, "source.secretRef is Flux-only: Argo CD matches credentials by repository URL, not by name. Drop it and create a Secret in ${namespace} labelled argocd.argoproj.io/secret-type=repository carrying url (the repository Argo CD clones), username and password"
        len(repositories) <= tenant.quota.repositories, "repositories: ${len(repositories)} exceeds the tenant's quota.repositories (${tenant.quota.repositories})"
        forge.storageGb <= tenant.quota.storageGb, "forge.storageGb ${forge.storageGb} exceeds the tenant's quota.storageGb (${tenant.quota.storageGb})"
        not repositories or "repository" in tenant.features, "tenant.features must grant `repository` to manage repositories inside the forge"
        not any_true([r.private for r in repositories]) or tenant.plan in ["team", "enterprise"], "a private repository needs plan team or enterprise, not ${tenant.plan}"
        not forge.highAvailability or tenant.plan == "enterprise", "forge.highAvailability needs plan enterprise, not ${tenant.plan}"
        source.origin != "forge" or any_true([r.name == source.repository for r in repositories]), "source.repository '${source.repository}' is not one of repositories[]"

# ── Derived values ───────────────────────────────────────────────────────────
_labels = lambda g: Gitops -> {str:str} {
    """Identity every rendered object carries."""
    {
        "app.kubernetes.io/part-of" = g.name
        "app.kubernetes.io/managed-by" = "kcl"
    }
}

serviceHost = lambda g: Gitops -> str {
    """In-cluster host:port of the forge's web Service."""
    "${g.forge.name}${http_service_suffix}.${g.tenant.namespace}.svc:${http_port}"
}

apiUrl = lambda g: Gitops -> str {
    """
    REST API root every Repository XR points at — the string the Forge XR
    publishes as status.apiUrl, computed here because it is deterministic.
    """
    "http://${serviceHost(g)}/api/v1"
}

cloneUrl = lambda g: Gitops, r: Repository -> str {
    """In-cluster HTTP clone URL of one repository inside the forge."""
    "http://${serviceHost(g)}/${r.owner}/${r.name}.git"
}

sourceUrl = lambda g: Gitops -> str {
    """
    What the engine clones: the seed repository, or — after the switch — the
    forge's own copy of it.
    """
    _followed = [r for r in g.repositories if r.name == g.source.repository]
    cloneUrl(g, _followed[0]) if g.source.origin == "forge" else g.source.url
}

# ── Renderers ────────────────────────────────────────────────────────────────
_namespace = lambda g: Gitops -> corev1.Namespace {
    corev1.Namespace {
        metadata = {
            name = g.tenant.namespace
            labels = _labels(g)
        }
    }
}

schema Shared:
    name: str
    namespace?: str = "aris"

schema Datas(Shared):
    len: int

#list: list()
_entitlement = lambda g: Gitops -> any {
    """
    The paid-feature record the Forge and Repository Compositions FETCH at
    render time (a RequiredResources item), keyed by the tenant namespace.
    Cluster-scoped, so it carries no namespace.
    """
    {
        apiVersion = platform_api_version
        kind = "Entitlement"
        metadata = {
            name = g.tenant.namespace
            labels = _labels(g)
        }
        spec = {
            plan = g.tenant.plan
            features = g.tenant.features
            quota = {
                storageGb = g.tenant.quota.storageGb
                repositories = g.tenant.quota.repositories
            }
            if g.tenant.reference:
                reference = g.tenant.reference
        }
    }
}

_forge = lambda g: Gitops -> any {
    """The Forge XR: one Forgejo instance, installed by provider-helm."""
    _f = g.forge
    _db = _f.database
    {
        apiVersion = cloud_api_version
        kind = "Forge"
        metadata = {
            name = _f.name
            namespace = g.tenant.namespace
            labels = _labels(g)
        }
        spec = {
            hostname = _f.hostname
            storageGb = _f.storageGb
            database = {
                mode = _db.mode
                if _db.host:
                    host = _db.host
                if _db.name:
                    name = _db.name
                if _db.user:
                    user = _db.user
                if _db.passwordSecret:
                    passwordSecret = {name = _db.passwordSecret.name, key = _db.passwordSecret.key}
            }
            ingress = {
                enabled = _f.ingress.enabled
                if _f.ingress.className:
                    className = _f.ingress.className
                if _f.ingress.tlsSecretName:
                    tlsSecretName = _f.ingress.tlsSecretName
            }
            highAvailability = _f.highAvailability
            chartVersion = _f.chartVersion
            if _f.imageTag:
                imageTag = _f.imageTag
            if _f.adminSecret:
                adminSecret = _f.adminSecret
            deletionPolicy = _f.deletionPolicy
            if _f.values:
                values = _f.values
        }
    }
}

_repository = lambda g: Gitops, r: Repository -> any {
    """
    One Repository XR. `forge.baseUrl` is the API root computed above rather
    than a reference: the XRD has no cross-XR reference mechanism on purpose,
    an operator is expected to copy status.apiUrl — and this package is that
    operator.
    """
    {
        apiVersion = cloud_api_version
        kind = "Repository"
        metadata = {
            name = r.name
            namespace = g.tenant.namespace
            labels = _labels(g)
        }
        spec = {
            forge = {
                baseUrl = apiUrl(g)
                secretRef = g.forge.tokenSecret
            }
            owner = r.owner
            name = r.name
            if r.description:
                description = r.description
            private = r.private
            defaultBranch = r.defaultBranch
            autoInit = r.autoInit
            if r.license:
                license = r.license
            if r.gitignores:
                gitignores = r.gitignores
            if r.readme:
                readme = r.readme
            createOrganization = r.createOrganization
            if r.organization:
                organization = {
                    fullName = r.organization.fullName or r.owner
                    if r.organization.description:
                        description = r.organization.description
                    visibility = r.organization.visibility
                    if r.organization.website:
                        website = r.organization.website
                }
            if r.webhook:
                webhook = {
                    url = r.webhook.url
                    if r.webhook.secretRef:
                        secretRef = r.webhook.secretRef
                    events = r.webhook.events
                    active = r.webhook.active
                }
            deletionPolicy = r.deletionPolicy
        }
    }
}

_emit = lambda obj -> any {
    """
    A typed Flux object as a plain manifest, with `None` attributes dropped.
    The generated CRD schemas type-check the object; `None` is how a check
    like GitRepository's "serviceAccountName only with provider aws/azure" is
    satisfied (an unset optional is Undefined, and Undefined != None), but a
    literal `serviceAccountName: null` in the applied YAML is a validation
    error against the CRD — so it is set for the check and stripped here.
    Same two-step as packages/platform/component/flux.
    """
    {
        apiVersion = obj.apiVersion
        kind = obj.kind
        metadata = obj.metadata
        spec = {k: v for k, v in obj.spec if v != None}
    }
}

_gitRepository = lambda g: Gitops -> any {
    """The Flux source. Its URL is the whole point of `source.origin`."""
    _emit(gitrepo.GitRepository {
        metadata = {
            name = g.name
            namespace = g.namespace
            labels = _labels(g)
        }
        spec = {
            url = sourceUrl(g)
            interval = g.source.interval
            ref = {branch = g.source.branch}
            serviceAccountName = None
            if g.source.secretRef:
                secretRef = {name = g.source.secretRef}
        }
    })
}

_kustomization = lambda g: Gitops -> any {
    """What Flux applies out of that source."""
    _emit(kustomization.Kustomization {
        metadata = {
            name = g.name
            namespace = g.namespace
            labels = _labels(g)
        }
        spec = {
            interval = g.source.reconcileInterval
            path = g.source.path
            prune = g.source.prune
            wait = g.source.wait
            timeout = g.source.timeout
            sourceRef = {
                kind = "GitRepository"
                name = g.name
            }
        }
    })
}

_appProject = lambda g: Gitops -> any {
    """
    The Argo CD project the Application belongs to. It admits exactly the one
    repository `sourceUrl` resolves to — after the forge switch, the
    in-cluster clone and nothing else — and, like the Flux Kustomization,
    any namespace and any cluster-scoped kind on the local cluster.
    """
    _emit(appproject.AppProject {
        metadata = {
            name = g.name
            namespace = g.namespace
            labels = _labels(g)
        }
        spec = {
            description = "${g.name}: cluster state reconciled from ${sourceUrl(g)}"
            sourceRepos = [sourceUrl(g)]
            destinations = [{server = in_cluster_server, namespace = "*"}]
            clusterResourceWhitelist = [{group = "*", kind = "*"}]
        }
    })
}

_application = lambda g: Gitops -> any {
    """What Argo CD syncs out of that repository, automatically."""
    _emit(application.Application {
        metadata = {
            name = g.name
            namespace = g.namespace
            labels = _labels(g)
            if g.source.prune:
                finalizers = [argocd_cascade_finalizer]
        }
        spec = {
            project = g.name
            source = {
                repoURL = sourceUrl(g)
                targetRevision = g.source.branch
                path = g.source.path
            }
            destination.server = in_cluster_server
            syncPolicy.automated = {
                prune = g.source.prune
                selfHeal = True
            }
        }
    })
}

_engine = lambda g: Gitops -> [any] {
    """The pair that keeps the cluster reconciled, for the chosen engine."""
    [_appProject(g), _application(g)] if g.engine == "argocd" else [_gitRepository(g), _kustomization(g)]
}

render = lambda g: Gitops -> [any] {
    """
    Every object, in apply order: the tenant namespace and its grant first
    (the Compositions read the grant), then the forge, then the repositories
    inside it, then the engine objects that keep the whole thing reconciled.
    """
    ([_namespace(g)] if g.tenant.createNamespace else []) + ([_entitlement(g)] if g.tenant.manageEntitlement else []) + [_forge(g)] + [_repository(g, r) for r in g.repositories] + _engine(g)
}
