# forge (forgejo) — Crossplane Composition logic (function-kcl module).
# The only backend: no cloud account, no IAM. Typed against the helm schema
# package, it renders ONE namespaced provider-helm Release that installs the
# upstream Forgejo chart into the XR's own namespace, so a tenant gets a whole
# git forge — web UI, REST API, SSH — from one namespaced XR.
#
# This is a PAID capability: every entry point takes the `Gate` that
# packages/platform/entitlement resolved for the XR's namespace, and refuses to
# shape anything the tenant's plan does not cover. main.k never calls in here
# until the gate is ready, so the asserts below only ever see a real record.
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as backend
import entitlement.lib as ent

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# provider-helm pulls an OCI chart as `<repository>/<name>:<version>`, so the
# registry PATH and the chart NAME stay split exactly as they are for a classic
# HTTP chart repo — folding the chart name into the repository URL yields
# `.../forgejo-helm/forgejo/forgejo` and a 404.
chart_repository = "oci://code.forgejo.org/forgejo-helm"
chart_name = "forgejo"

# Chart default, kept here so a spec that omits chartVersion (a locally
# rendered XR carries no XRD defaults) still pins instead of resolving
# "latest" at reconcile time.
default_chart_version = "17.1.5"

# The chart's web/API port (`service.http.port`), and the repository volume
# size a plan with no storageGb quota is allowed.
http_port = 3000
default_storage_gb = 10

# The chart names its web Service `<fullname>-http` (templates/gitea/http-svc.yaml),
# and `fullnameOverride` below pins <fullname> to the XR's name — hence the
# suffix. This string is a cross-capability contract: a Repository XR is
# configured by copying status.apiUrl verbatim, so it has to be the name that
# actually resolves. forge_test.k asserts the suffix, so an upstream rename
# breaks a test here instead of a tenant's Repository at reconcile time.
service_name = lambda name: str -> str {
    "${name}-http"
}

# The in-cluster API root a sibling Repository XR is pointed at.
api_url = lambda name: str, namespace: str -> str {
    "http://${service_name(name)}.${namespace}.svc:${http_port}/api/v1"
}

# The public web URL. One definition, because Forgejo's own ROOT_URL and the
# status the XR publishes must agree: a forge that writes clone URLs a browser
# cannot reach is broken in a way nothing reports. Only ingress TLS decides the
# scheme — the chart itself serves plain HTTP behind it.
web_url = lambda spec: any -> str {
    _scheme = "https" if spec?.ingress?.tlsSecretName else "http"
    "${_scheme}://${spec.hostname}"
}

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides. Both flavours of
# absence count: an unset key reads as Undefined, but `?.` over a spec block
# that is itself absent (or empty) yields None.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Deep, right-wins merge of two values dicts (Helm overlay semantics): nested
# maps merge, overlay scalars and lists replace.
#
# Written here rather than imported from packages/app (`app.mergeValues`, same
# body): that package is the workload library and drags k8s, external-secrets,
# keda and chaos-mesh in with it, and this module is published as an OCI
# artifact function-kcl resolves on every reconcile. Four packages of
# transitive dependencies is a steep price for one comprehension.
_merge = lambda base: {str:}, overlay: {str:} -> {str:} {
    {k: (_merge(base[k], overlay[k]) if (k in base and k in overlay and typeof(base[k]) == "dict" and typeof(overlay[k]) == "dict") else (overlay[k] if k in overlay else base[k])) for k in ([_kb for _kb in base] + [_ko for _ko in overlay if _ko not in base])}
}

# Everything the spec says about the chart, in one place: the whole mapping
# from XR fields to chart values, plus the plan checks that mapping depends on.
# Kept out of render() so that lambda stays a statement of the Release's shape
# — provider, chart, deletion policy — and nothing else.
chart_values = lambda oxr, gate: ent.Gate -> {str:} {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _hostname = _spec.hostname

    _db = _spec?.database or {}
    _db_mode = _db?.mode or "sqlite"
    _ha = _spec?.highAvailability or False
    _ing = _spec?.ingress or {}
    _tls = _ing?.tlsSecretName

    # Paid shape. A failed assert surfaces as one SEVERITY_FATAL function result
    # naming the field and the plan, which is the whole point of the gate: an
    # unentitled tenant gets an error on its XR, never a partial install.
    assert (not _ha) or ent.at_least(gate, "enterprise"), "spec.highAvailability requires the 'enterprise' plan; this namespace is on '${gate.plan}'. Upgrade the plan, or set spec.highAvailability to false."

    # Not a plan rule but a data-integrity one: replicas mount ONE repository
    # volume, and two Forgejo processes writing one sqlite file corrupt it.
    assert (not _ha) or _db_mode == "postgres", "spec.highAvailability requires spec.database.mode 'postgres': replicas share the repository volume, and concurrent writers on the sqlite file corrupt it."

    # within_quota asserts `used <= cap` and RETURNS THE CAP, so the volume is
    # sized by what the XR asked for — the cap is a ceiling, not a target, and
    # raising a plan's quota must not silently grow every existing forge.
    _requested = _spec?.storageGb or default_storage_gb
    _cap = ent.within_quota(gate, "storageGb", _requested, default_storage_gb)
    _storage = _requested if _requested <= _cap else _cap

    # ROOT_URL/DOMAIN are set explicitly rather than left to the chart's own
    # derivation, so the URL Forgejo writes into clone commands and webhooks is
    # the same string status.url publishes.
    _config: {str:} = {
        server = {
            ROOT_URL = web_url(_spec)
            DOMAIN = _hostname
        }
    }
    if _db_mode == "postgres":
        # Chart 17.x ships no bundled PostgreSQL subchart (dropped in chart
        # v14), so this points at a server that already exists; nothing here
        # composes one.
        assert _db?.host, "spec.database.mode 'postgres' needs spec.database.host: chart ${default_chart_version} bundles no PostgreSQL, so the server must already exist."
        _config = _config | {
            database = {
                DB_TYPE = "postgres"
                HOST = _db.host
                NAME = _db?.name or chart_name
                USER = _db?.user or chart_name
            }
        }

    if _ha:
        # The two things the chart's own multi-replica assertions and a shared
        # volume demand; a shared cache/queue (Valkey) is not modelled here and
        # is supplied through spec.values.
        _config = _config | {
            indexer = {ISSUE_INDEXER_TYPE = "db", REPO_INDEXER_ENABLED = False}
            session = {PROVIDER = "db"}
        }

    _gitea: {str:} = {config = _config}
    if _spec?.adminSecret:
        # An EXISTING Secret with `username`/`password` keys. Naming it here
        # keeps the admin credential out of this module, out of the Release and
        # out of the XR's composition history.
        _gitea = _gitea | {
            admin = {existingSecret = _spec.adminSecret}
        }

    if _db_mode == "postgres" and _db?.passwordSecret:
        # The password never appears in the Release: the chart mounts each
        # additionalConfigSources entry under /env-to-ini-mounts/additionals/,
        # where the FILE NAME is the app.ini section and the file body is its
        # `KEY=value` lines — hence the projection to path `database`, whose
        # content is the fragment `PASSWD=<password>`.
        _gitea = _gitea | {
            additionalConfigSources = [{
                secret = {
                    secretName = _db.passwordSecret.name
                    items = [{key = _db.passwordSecret?.key or "password", path = "database"}]
                }
            }]
        }

    _values: {str:} = {
        # Every chart resource name derives from this, including the Service
        # status.apiUrl is built from.
        fullnameOverride = _name
        persistence = {
            enabled = True
            size = "${_storage}Gi"
            if _ha:
                # Replicas mount ONE volume, so it has to be shareable; the
                # chart fails the render on ReadWriteOnce with replicaCount > 1.
                accessModes = ["ReadWriteMany"]
        }
        ingress = {
            enabled = _flag(_ing?.enabled, True)
            hosts = [{host = _hostname, paths = [{path = "/", pathType = "Prefix"}]}]
            if _ing?.className:
                className = _ing.className
            if _tls:
                tls = [{secretName = _tls, hosts = [_hostname]}]
        }
        if _spec?.imageTag:
            # Overrides the chart's appVersion (Forgejo 15.0.7 at chart 17.1.5).
            image = {tag = _spec.imageTag}
        if _ha:
            replicaCount = 2
        gitea = _gitea
    }

    # The escape hatch wins over everything computed above: it is the documented
    # way to reach a chart key this XRD does not model, and a spec that loses to
    # a computed default is not an escape hatch.
    _merge(_values, _spec?.values or {})
}

render = lambda oxr, gate: ent.Gate -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"

    # external-name pins the Helm release name to the XR name, which is what
    # makes the chart's resource names (and therefore the Service name
    # status.apiUrl publishes) predictable.
    [backend.Release {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if (_spec?.deletionPolicy or "Delete") == "Orphan":
            spec.managementPolicies = _orphan_policies
        # The helm provider runs with in-cluster identity, so one cluster-wide
        # config serves XRs in every namespace.
        spec.providerConfigRef = {kind = "ClusterProviderConfig", name = "default"}
        spec.forProvider.namespace = _ns
        spec.forProvider.chart = {
            name = chart_name
            repository = chart_repository
            version = _spec?.chartVersion or default_chart_version
        }
        # NOT `spec.forProvider.set`: provider-helm applies `set` AFTER
        # `values`, so anything listed there would silently outrank the values
        # computed from the spec. One source of truth for the chart input.
        spec.forProvider.values = chart_values(oxr, gate)
        spec.forProvider.wait = True
        spec.forProvider.waitTimeout = "10m"
    }]
}

# Build the desired composite carrying observed Release state back to the XR.
# The endpoints are deterministic from the XR's own name, so they are published
# before the chart is up; readiness is not. Every read of observed state is
# optional: on the first reconcile there is none, and that means "not ready",
# never an error.
status = lambda oxr, ocds, gate: ent.Gate -> any {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _observed = ocds or {}
    _obs = _observed["managed"]?.Resource if ("managed" in _observed) else Undefined
    _st = _obs?.status

    # Readiness comes from the Release's Ready CONDITION rather than
    # atProvider.state: `deployed` is Helm's verdict on the release, while
    # Ready also carries provider-helm's own `wait` result — which is what
    # spec.forProvider.wait was set for.
    _hit = [c for c in (_st?.conditions or []) if c?.type == "Ready"]
    _ready = ((_hit[0]?.status or "") if _hit else "") == "True"

    # provider-helm reports revision, state and the actually deployed chart
    # version, but not the release name — that is the external-name it pinned.
    _ann = _obs?.metadata?.annotations or {}

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Forge"
        metadata.name = _name
        status = {
            ready = _ready
            url = web_url(_spec)
            apiUrl = api_url(_name, _ns)
            service = service_name(_name)
            plan = gate.plan
            # The deployed version once known, so an operator can see a
            # late-initialized or spec.values-overridden chart for what it is.
            chartVersion = _st?.atProvider?.version or _spec?.chartVersion or default_chart_version
            release = _ann["crossplane.io/external-name"] if "crossplane.io/external-name" in _ann else ""
        }
    }
}
