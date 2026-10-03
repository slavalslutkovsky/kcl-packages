import .gitopsplatform as gp

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_conn = {host = "pg.internal", passwordSecret.name = "pg-cred"}

_build = lambda _spec {
    {apiVersion = "platform.example.org/v1alpha1", kind = "GitOpsPlatform", metadata = {name = "demo", namespace = "team-a"}, spec = {engine = "flux", db = {connection = _conn, provision.backend = "cnpg"}} | _spec}
}

_key = lambda _x {
    gp.check_key(_x.spec.db)
}

# An observed check Job carrying one terminal condition.
_job = lambda _x, _type, _succeeded, _failed {
    {
        "${_key(_x)}" = {
            Resource.status = {succeeded = _succeeded, failed = _failed, conditions = [{type = _type, status = "True"}]}
        }
    }
}

_db_child = lambda _ready {
    {
        database.Resource.status = {ready = _ready, provider = "cnpg", host = "demo-db-rw.team-a.svc.cluster.local", port = 5432, endpoint = "demo-db-rw.team-a.svc.cluster.local:5432", url = "postgresql://demo-db-rw.team-a.svc.cluster.local:5432/app", database = "app", username = "app", authSecret = "demo-db-app", authSecretKey = "password"}
    }
}

_engine = {engine.Resource.status.atProvider.state = "deployed"}

_names = lambda items {
    [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in items]
}

# ---- the state machine ------------------------------------------------------

# Nothing but the check while the verdict is out: no database to replace yet,
# and no engine before the database is known.
test_checking = lambda {
    x = _build({})
    assert _names(gp.render(x, {})) == [_key(x)], "only the connection Job while checking"
    st = gp.status(x, {}).status
    assert st.db.source == "checking" and st.db.check == "Running" and st.ready == False, "checking is not ready"
}

# A passing check installs the engine on the existing database and composes no
# replacement. The Job stays, so the next reconcile still sees the verdict.
test_existing = lambda {
    x = _build({})
    ocds = _job(x, "Complete", 1, 1)
    items = gp.render(x, ocds)
    assert _names(items) == [_key(x), "engine"], "Job kept + engine, no database: ${_names(items)}"
    assert items[0].metadata.annotations["krm.kcl.dev/ready"] == "True", "a terminal Job must be declared ready"
    db = gp.status(x, ocds | _engine).status.db
    assert db.source == "existing" and db.backend == "existing" and db.ready == True, "the existing database is resolved"
    assert db.attempts == 2, "a pass on the second attempt reports both"
    assert db.endpoint == "pg.internal:5432" and db.url == "postgresql://pg.internal:5432/app", "coordinates come from the connection"
    assert db.authSecret == "pg-cred" and db.authSecretKey == "password", "the caller's Secret is the auth secret"
    assert gp.status(x, ocds | _engine).status.ready == True, "deployed engine on a resolved database is ready"
}

# Every attempt failed: provision, and hold the engine until the new database
# reports ready.
test_failed_check_provisions = lambda {
    x = _build({})
    ocds = _job(x, "Failed", 0, 3)
    assert _names(gp.render(x, ocds)) == ["database"], "a failed check composes the fallback and nothing else"
    st = gp.status(x, ocds).status
    assert st.db.source == "provisioned" and st.db.check == "Failed" and st.db.attempts == 3, "the verdict is reported"
    assert st.db.ready == False, "provisioned but not up yet"
}

test_provisioned_database_ready_installs_engine = lambda {
    x = _build({})
    assert _names(gp.render(x, _db_child(False))) == ["database"], "no engine on a database that is not ready"
    assert _names(gp.render(x, _db_child(True))) == ["database", "engine"], "engine once the database is ready"
    db = gp.status(x, _db_child(True) | _engine).status.db
    assert db.backend == "cnpg" and db.endpoint == "demo-db-rw.team-a.svc.cluster.local:5432", "coordinates are copied from the child"
    assert db.authSecret == "demo-db-app", "auth Secret is the child's"
}

# No connection means nothing to validate.
test_no_connection_provisions_directly = lambda {
    x = _build({
        db = {provision.backend = "cnpg"}
    })
    assert _names(gp.render(x, {})) == ["database"], "no Job without a connection"
    assert gp.status(x, {}).status.db.check == "Skipped", "the check is reported as skipped"
}

# Once the Job is dropped the verdict survives through the XR's own status.
test_verdict_carried_forward = lambda {
    x = _build({}) | {
        status.db = {check = "Failed", attempts = 3}
    }
    db = gp.status(x, _db_child(False)).status.db
    assert db.check == "Failed" and db.attempts == 3, "the last verdict must not regress to Running"
}

# ---- stickiness: never delete state because a later check disagrees ---------
test_provisioned_is_sticky = lambda {
    x = _build({})

    # A database exists and some check now passes (e.g. the connection was
    # repaired): the database must stay composed and the Job must not return.
    items = gp.render(x, _db_child(True) | _job(x, "Complete", 1, 0))
    assert "database" in _names(items), "a provisioned database must never be dropped"
    assert _key(x) not in _names(items), "the check is over once a database is provisioned"
}

test_engine_is_sticky = lambda {
    x = _build({
        db = {connection = _conn | {host = "pg2.internal"}, provision.backend = "cnpg"}
    })

    # The connection changed, so a fresh check is running; the installed engine
    # must survive it.
    items = gp.render(x, _engine)
    assert _names(items) == [_key(x), "engine"], "an installed engine is never uninstalled by a re-check"
}

# ---- the check Job ----------------------------------------------------------
test_check_job = lambda {
    x = _build({
        db = {connection = _conn, check = {attempts = 5, timeoutSeconds = 7}, provision.backend = "cnpg"}
    })
    j = gp.render(x, {})[0]
    assert j.spec.backoffLimit == 4, "attempts = 1 + backoffLimit retries"
    c = j.spec.template.spec.containers[0]
    assert c.command == ["psql", "--no-psqlrc", "-tAc", "SELECT 1"], "with a password the check logs in"
    assert [[e.valueFrom.secretKeyRef.name, e.valueFrom.secretKeyRef.key] for e in c.env if e.name == "PGPASSWORD"] == [["pg-cred", "password"]], "password from the Secret"
    assert [e.value for e in c.env if e.name == "PGCONNECT_TIMEOUT"] == ["7"], "timeout per attempt"
    nopw = gp.render(_build({
        db = {connection.host = "pg.internal", provision.backend = "cnpg"}
    }), {})[0].spec.template.spec.containers[0]
    assert nopw.command == ["pg_isready", "-t", "5"], "without a password only reachability is checked"
    assert not any e in nopw.env {
        e.name == "PGPASSWORD"
    }, "no password env without a Secret"
}

# A pod template is immutable; any input change must be a new composed Job.
test_check_key = lambda {
    a = _key(_build({}))
    assert a.startswith(gp.check_prefix), "prefixed key"
    assert a == _key(_build({})), "stable across renders"
    assert a != _key(_build({
        db = {connection = _conn | {host = "other"}, provision.backend = "cnpg"}
    })), "host change -> new Job"
    assert a != _key(_build({
        db = {connection = _conn, check.attempts = 4, provision.backend = "cnpg"}
    })), "check change -> new Job"
}

# ---- the fallback database --------------------------------------------------
test_database_child = lambda {
    x = _build({
        db = {connection = _conn | {database = "orders", username = "svc"}, provision = {backend = "aws", spec = {region = "eu-west-1", memoryGb = 4}}}
    })
    d = gp.database_child(x)
    assert d.kind == "PostgresInstance" and d.metadata.name == "demo-db", "child PostgresInstance"
    assert d.spec.crossplane.compositionSelector.matchLabels.provider == "aws", "backend selects the Composition"
    assert d.spec.region == "eu-west-1" and d.spec.memoryGb == 4, "provision.spec passes through"
    assert d.spec.database == "orders" and d.spec.username == "svc", "the replacement serves the connection's names"
    assert gp.database_child(_build({})).spec.region == "in-cluster", "cnpg needs no region"
    own = gp.database_child(_build({deletionPolicy = "Orphan", db = {
        provision = {backend = "cnpg", spec.database = "x"}
    }})).spec
    assert own.deletionPolicy == "Orphan" and own.database == "x", "XR deletionPolicy is the default; explicit names win"
}

# ---- the engine -------------------------------------------------------------
_release = lambda _x {
    [i for i in gp.render(_x, _engine) if i.kind == "Release"][0]
}

test_flux_release = lambda {
    r = _release(_build({}))
    assert r.spec.forProvider.chart.name == "flux2" and r.spec.forProvider.chart.version == "2.19.0", "pinned flux2 chart"
    assert r.spec.forProvider.namespace == "flux-system", "default namespace"
    assert r.spec.providerConfigRef.kind == "ClusterProviderConfig" and r.spec.providerConfigRef.name == "default", "in-cluster by default"
    v = _release(_build({
        values = {imageAutomationController.resources.limits.cpu = "1", sourceController.create = False}
    })).spec.forProvider.values
    assert v.imageAutomationController.create == False, "an override under a defaulted key keeps the default"
    assert v.imageAutomationController.resources.limits.cpu == "1", "the override applies"
    assert v.notificationController.create == False and v.sourceController.create == False, "untouched defaults and new keys both survive"
}

test_argocd_release = lambda {
    r = _release(_build({engine = "argocd", version = "10.9.7"}))
    assert r.spec.forProvider.chart.name == "argo-cd" and r.spec.forProvider.chart.repository == "https://argoproj.github.io/argo-helm", "argo-helm chart"
    assert r.spec.forProvider.chart.version == "10.9.7", "version override"
    assert r.spec.forProvider.namespace == "argocd", "default namespace"
    assert r.metadata.annotations["crossplane.io/external-name"] == "argocd", "Helm release name"
}

test_remote_cluster = lambda {
    x = _build({kubeconfigSecret = "edge-kubeconfig", deletionPolicy = "Orphan"})
    items = gp.render(x, _engine)
    pc = [i for i in items if i.kind == "ProviderConfig"][0]
    assert pc.spec.credentials.secretRef.name == "edge-kubeconfig" and pc.spec.credentials.secretRef.namespace == "team-a", "kubeconfig from the XR's namespace"
    r = [i for i in items if i.kind == "Release"][0]
    assert r.spec.providerConfigRef.kind == "ProviderConfig" and r.spec.providerConfigRef.name == "demo", "Release targets the per-XR ProviderConfig"
    assert r.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"], "Orphan keeps the release"
}
