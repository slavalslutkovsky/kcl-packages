# gitopsplatform — Crossplane Composition logic (function-kcl module).
#
# Installs a GitOps engine (FluxCD or Argo CD) only once the platform database
# is resolved. Resolution is a small state machine driven entirely by OBSERVED
# composed resources, so it survives restarts and never depends on the XR's
# own status being written back:
#
#   checking     spec.db.connection is set and the connection Job has not
#                reached a terminal condition. Compose the Job, nothing else.
#   existing     the Job completed: some attempt connected. Install the engine.
#   provisioned  the Job failed every attempt, there is no connection to check,
#                or a PostgresInstance child already exists. Compose the child
#                from spec.db.provision; install the engine once it is ready.
#
# Both outcomes that create state are STICKY. A composed PostgresInstance stays
# composed whatever a later check says, and an engine Release, once observed,
# is never dropped — Crossplane deletes whatever leaves the desired state, and
# either deletion would destroy a database or uninstall the engine under every
# workload it manages. The Job is dropped once a database is provisioned: its
# verdict has been acted on, and keeping it would only pin the decision.
#
# Composed objects carry no namespace: Crossplane places them in the XR's.
import crypto
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as release
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_provider_config as providerconfig
import k8s.api.batch.v1 as batchv1

_child_api = "cloud.example.org/v1alpha1"

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Key of the kubeconfig inside spec.kubeconfigSecret — the key every cluster
# backend in this repo publishes, so a cluster's connection Secret works as-is.
kubeconfig_key = "kubeconfig"

# Pinned charts. flux2 2.19.0 installs Flux v2.9.1 (the version the clusters in
# this repo run); argo-cd 10.9.6 installs Argo CD v3.5.3, the version the
# packages/providers/argocd schemas are generated from. The flux defaults
# switch off the controllers nothing here uses, as devkit.toml does.
engines = {
    flux = {
        chart = "flux2"
        release = "flux2"
        repository = "https://fluxcd-community.github.io/helm-charts"
        version = "2.19.0"
        namespace = "flux-system"
        values = {
            imageAutomationController = {create = False}
            imageReflectionController = {create = False}
            notificationController = {create = False}
        }
    }
    argocd = {
        chart = "argo-cd"
        release = "argocd"
        repository = "https://argoproj.github.io/argo-helm"
        version = "10.9.6"
        namespace = "argocd"
        values = {}
    }
}

# The check image ships pg_isready and psql; the client speaks to every
# supported server major. Its alpine variant's postgres user is uid 70.
check_image = "postgres:17-alpine"
check_uid = 70

# Composition-resource-name prefix of the connection Job; the suffix is a hash
# of everything the pod template is built from (see check_key).
check_prefix = "db-check-"

# A composed resource as function-kcl hands it over, or Undefined.
_observed = lambda ocds, name: str -> any {
    (ocds[name]?.Resource) if name in (ocds or {}) else Undefined
}

# True when the object carries condition `ctype` with status "True".
_condition = lambda res, ctype: str -> bool {
    _conds = res?.status?.conditions or []
    any c in _conds {
        c?.type == ctype and c?.status == "True"
    }
}

# Helm values over the engine defaults. KCL's `|` replaces a nested dict
# wholesale, so a user override of one key under imageAutomationController
# would silently re-enable the controller; merging one level down keeps every
# default the user did not touch. One level is exact for the defaults above,
# whose leaves are all at depth two.
merge_values = lambda defaults: {str:any}, overrides: {str:any} -> {str:any} {
    defaults | {k = (defaults[k] | v) if (k in defaults and typeof(v) == "dict" and typeof(defaults[k]) == "dict") else v for k, v in overrides}
}

# A Job's pod template is immutable, so a changed connection cannot update the
# old Job in place. Keying the composed resource on a hash of every template
# input makes any change a NEW composed resource — Crossplane deletes the old
# Job and runs a fresh check — instead of an update the API server rejects.
check_key = lambda db -> str {
    _c = db.connection
    _k = db?.check or {}
    _sec = _c?.passwordSecret
    _parts = [_c.host, _c?.port or 5432, _c?.database or "app", _c?.username or "app", _c?.sslMode or "prefer", _sec?.name or "", _sec?.key or "password", _k?.attempts or 3, _k?.timeoutSeconds or 5, _k?.deadlineSeconds or 300, _k?.image or check_image]
    _src = "|".join([str(p) for p in _parts])
    check_prefix + crypto.md5(_src)[:10:]
}

# Where the database decision stands. See the header for the states.
resolve = lambda oxr, ocds -> {str:any} {
    _db = oxr.spec.db
    _conn = _db?.connection
    _key = check_key(_db) if _conn else ""
    _job = _observed(ocds, _key) if _conn else Undefined
    _passed = _condition(_job, "Complete")
    _failed = _condition(_job, "Failed")
    _provisioned = "database" in (ocds or {})

    # The Job is gone once a database is provisioned, so the verdict that
    # led there is carried forward from the XR's own last status.
    _prev = oxr?.status?.db or {}
    {
        source = "provisioned" if (_provisioned or not _conn or _failed) else ("existing" if _passed else "checking")
        key = _key
        terminal = _passed or _failed
        check = "Skipped" if not _conn else "Passed" if _passed else "Failed" if _failed else (_prev?.check or "Failed") if _provisioned else "Running"
        attempts = (_job?.status?.succeeded or 0) + (_job?.status?.failed or 0) if _job else (_prev?.attempts or 0)
    }
}

# The connection check: one Job, `attempts` pods. Kubernetes retries a failed
# pod with exponential backoff, so backoffLimit IS the reconnect loop, and the
# Job's terminal condition is the verdict. activeDeadlineSeconds turns a pod
# that can never run (missing Secret, unpullable image) into a failure rather
# than a check that hangs forever.
#
# With a password the check logs in (`SELECT 1`), validating credentials as
# well as reachability; without one it can only ask pg_isready whether the
# server accepts connections.
#
# A Job has no Ready condition, so readiness is declared once it is terminal —
# a failed check is an answer, not a stuck resource.
check_job = lambda oxr, state -> any {
    _conn = oxr.spec.db.connection
    _k = oxr.spec.db?.check or {}
    _timeout = _k?.timeoutSeconds or 5
    _sec = _conn?.passwordSecret
    batchv1.Job {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = state.key
            if state.terminal:
                "krm.kcl.dev/ready" = "True"
        }
        spec = {
            backoffLimit = (_k?.attempts or 3) - 1
            activeDeadlineSeconds = _k?.deadlineSeconds or 300
            template.spec = {
                restartPolicy = "Never"
                securityContext = {
                    runAsNonRoot = True
                    runAsUser = check_uid
                    runAsGroup = check_uid
                    seccompProfile.type = "RuntimeDefault"
                }
                containers = [{
                    name = "check"
                    image = _k?.image or check_image
                    command = ["psql", "--no-psqlrc", "-tAc", "SELECT 1"] if _sec else ["pg_isready", "-t", str(_timeout)]
                    env = [
                        {name = "PGHOST", value = _conn.host}
                        {name = "PGPORT", value = str(_conn?.port or 5432)}
                        {name = "PGDATABASE", value = _conn?.database or "app"}
                        {name = "PGUSER", value = _conn?.username or "app"}
                        {name = "PGSSLMODE", value = _conn?.sslMode or "prefer"}
                        {name = "PGCONNECT_TIMEOUT", value = str(_timeout)}
                    ] + ([{name = "PGPASSWORD", valueFrom.secretKeyRef = {name = _sec.name, key = _sec?.key or "password"}}] if _sec else [])
                    securityContext = {
                        allowPrivilegeEscalation = False
                        readOnlyRootFilesystem = True
                        capabilities.drop = ["ALL"]
                    }
                    resources = {
                        requests = {cpu = "10m", memory = "32Mi"}
                        limits = {memory = "64Mi"}
                    }
                }]
            }
        }
    }
}

# The fallback database: spec.db.provision.spec verbatim, plus the backend
# selector and the defaults that make it a drop-in for the unreachable one.
# spec.crossplane is owned here — the backend field is the selector.
database_child = lambda oxr -> any {
    _db = oxr.spec.db
    _p = _db.provision
    _conn = _db?.connection or {}
    _spec = _p?.spec or {}
    _region = _spec?.region or ("in-cluster" if _p.backend == "cnpg" else "")
    assert _region, "gitopsplatform: spec.db.provision.spec.region is required for backend '${_p.backend}' — only the in-cluster cnpg backend has no region"
    {
        apiVersion = _child_api
        kind = "PostgresInstance"
        metadata = {
            name = "${oxr.metadata.name}-db"
            annotations = {"krm.kcl.dev/composition-resource-name" = "database"}
        }
        spec = _spec | {
            region = _region
            database = _spec?.database or _conn?.database or "app"
            username = _spec?.username or _conn?.username or "app"
            deletionPolicy = _spec?.deletionPolicy or oxr.spec?.deletionPolicy or "Delete"
            crossplane = {compositionSelector.matchLabels.provider = _p.backend}
        }
    }
}

render = lambda oxr, ocds -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _e = engines[_spec.engine]
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _state = resolve(oxr, ocds)

    _db_ready = _observed(ocds, "database")?.status?.ready or False
    _install = "engine" in (ocds or {}) or _state.source == "existing" or (_state.source == "provisioned" and _db_ready)

    _items: [any] = []

    # The Job stays composed after it passes: dropping it would make the next
    # reconcile see no verdict and run the check all over again.
    if _state.source in ["checking", "existing"]:
        _items += [check_job(oxr, _state)]

    if _state.source == "provisioned":
        _items += [database_child(oxr)]

    # A remote cluster's credentials, scoped to this XR — the helm provider
    # resolves a namespaced ProviderConfig in the Release's namespace, which is
    # the XR's. No Ready condition, so declared ready outright.
    if _spec?.kubeconfigSecret:
        _items += [providerconfig.ProviderConfig {
            metadata.name = _name
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "providerconfig"
                "krm.kcl.dev/ready" = "True"
            }
            spec.credentials = {
                source = "Secret"
                secretRef = {namespace = _ns, name = _spec.kubeconfigSecret, key = kubeconfig_key}
            }
        }]

    if _install:
        _values = merge_values(_e.values, _spec?.values or {})
        _items += [release.Release {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "engine"
                # The Helm release name in the target cluster.
                "crossplane.io/external-name" = _e.release
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.providerConfigRef = {kind = "ProviderConfig", name = _name} if _spec?.kubeconfigSecret else {kind = "ClusterProviderConfig", name = "default"}
            spec.forProvider.namespace = _spec?.namespace or _e.namespace
            spec.forProvider.chart = {
                name = _e.chart
                repository = _e.repository
                version = _spec?.version or _e.version
            }
            if _values:
                spec.forProvider.values = _values
            spec.forProvider.wait = True
            spec.forProvider.waitTimeout = "10m"
        }]

    _items
}

# The resolved database's coordinates. Existing: straight from the connection
# that passed. Provisioned: copied from the child's status, never recomputed —
# each backend already decided what its endpoint and auth Secret look like.
db_status = lambda oxr, ocds, state -> {str:any} {
    _db = oxr.spec.db
    _conn = _db?.connection or {}
    _child = _observed(ocds, "database")?.status or {}
    _host = _conn?.host
    _port = _conn?.port or 5432
    _name = _conn?.database or "app"
    {
        source = state.source
        check = state.check
        attempts = state.attempts
        if state.source == "existing":
            backend = "existing"
            ready = True
            host = _host
            port = _port
            endpoint = "${_host}:${_port}"
            url = "postgresql://${_host}:${_port}/${_name}"
            database = _name
            username = _conn?.username or "app"
            if _conn?.passwordSecret:
                authSecret = _conn.passwordSecret.name
                authSecretKey = _conn.passwordSecret?.key or "password"
        elif state.source == "provisioned":
            backend = _db.provision.backend
            ready = _child?.ready or False
            if _child?.host:
                host = _child.host
            if _child?.port:
                port = _child.port
            if _child?.endpoint:
                endpoint = _child.endpoint
            if _child?.url:
                url = _child.url
            if _child?.database:
                database = _child.database
            if _child?.username:
                username = _child.username
            if _child?.authSecret:
                authSecret = _child.authSecret
            if _child?.authSecretKey:
                authSecretKey = _child.authSecretKey
        else:
            ready = False
    }
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds -> any {
    _spec = oxr.spec
    _e = engines[_spec.engine]
    _engine_state = _observed(ocds, "engine")?.status?.atProvider?.state or ""
    _db = db_status(oxr, ocds, resolve(oxr, ocds))
    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "GitOpsPlatform"
        metadata.name = oxr.metadata.name
        status = {
            ready = _engine_state == "deployed" and _db.ready
            engine = _spec.engine
            chartVersion = _spec?.version or _e.version
            namespace = _spec?.namespace or _e.namespace
            engineState = _engine_state
            db = _db
        }
    }
}
