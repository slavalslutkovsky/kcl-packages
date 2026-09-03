# Unit tests for the forge (forgejo) function-kcl module.
# Contract under test:
#   render(oxr, gate)        -> [resource]   (one provider-helm Release, no composite)
#   status(oxr, ocds, gate)  -> dxr          (single desired-composite carrying .status)
# The interesting behaviour is the chart VALUES the spec computes into, so most
# assertions read spec.forProvider.values rather than the Release itself.
import .forge
import entitlement.lib as ent

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with the module's lambda parameters
# (`oxr`, `ocds`, `gate`) — KCL normalizes the leading underscore, so a helper
# named `_gate` shadows the parameter. Hence the `_t` prefix throughout.

# The gate a paying tenant arrives with. Tests never exercise a denied gate:
# `resolve` asserts, and `kcl test` cannot catch an assert.
_tteam = ent.Gate {ready = True, pending = False, feature = "forgejo", plan = "team", features = ["forgejo"]}
_tenterprise = ent.Gate {ready = True, pending = False, feature = "forgejo", plan = "enterprise", features = ["forgejo"]}

# An observed composite XR carrying the base spec merged with `extra`.
_tbuild = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Forge", metadata = {name = "git", namespace = "apps"}, spec = {hostname = "git.example.org"} | extra}
}

# The Release's chart values for the given spec, on a `team` gate.
_tvalues = lambda extra: any -> any {
    forge.render(_tbuild(extra), _tteam)[0].spec.forProvider.values
}

# 1) Minimal spec: one namespaced Release of the pinned chart, sqlite on a
#    default-sized volume, ingress on.
test_render_minimal = lambda {
    items = forge.render(_tbuild({}), _tteam)
    assert len(items) == 1, "the forge is a single Release: nothing else is composed"
    assert items[0].apiVersion == "helm.m.crossplane.io/v1beta1", "wrong Release apiVersion"
    assert items[0].kind == "Release", "the composed MR must be a helm Release"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "status() reads the observed Release under `managed`"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "git", "the Helm release name must be pinned to the XR name"
    _fp = items[0].spec.forProvider
    assert _fp.namespace == "apps", "the chart must land in the XR's namespace"
    assert _fp.chart.name == "forgejo", "chart must be forgejo"
    assert _fp.chart.repository == "oci://code.forgejo.org/forgejo-helm", "the OCI repository must stay the registry path, without the chart name"
    assert _fp.chart.version == "17.1.5", "chart version must stay pinned so a re-render never upgrades a running forge"
    assert _fp.wait == True, "the Release must report ready only once the chart is up"
    assert _fp?.set == Undefined, "provider-helm applies `set` after `values`: using it would let it outrank the spec"
    assert items[0].spec.providerConfigRef.kind == "ClusterProviderConfig", "provider-helm runs with in-cluster identity"
    _v = _fp.values
    assert _v.fullnameOverride == "git", "chart resource names (and therefore status.apiUrl) derive from the XR name"
    assert _v.gitea.config?.database == Undefined, "sqlite is the chart default: no database section means no external server"
    assert _v.gitea?.admin == Undefined, "without adminSecret the chart keeps its generated admin"
    assert _v.gitea?.additionalConfigSources == Undefined, "nothing to source from a Secret without an external database password"
    assert _v.persistence.enabled == True, "a forge that loses its repositories on restart is not a forge"
    assert _v.persistence.size == "10Gi", "storageGb must default to 10"
    assert _v.persistence?.accessModes == Undefined, "a single replica needs no shared volume"
    assert _v.ingress.enabled == True, "ingress must default to on: a forge nobody can reach is useless"
    assert _v?.replicaCount == Undefined, "highAvailability defaults to off"
}

# 2) An external Postgres is wired by reference only: the password reaches
#    Forgejo through a mounted Secret, never through the Release.
test_database_postgres = lambda {
    _v = _tvalues({
        database = {
            mode = "postgres"
            host = "pg.data.svc:5432"
            name = "forge_git"
            user = "forge"
            passwordSecret = {name = "forge-db", key = "pgpass"}
        }
    })
    _db = _v.gitea.config.database
    assert _db.DB_TYPE == "postgres", "DB_TYPE must select the external server"
    assert _db.HOST == "pg.data.svc:5432", "HOST must be carried through verbatim"
    assert _db.NAME == "forge_git", "NAME must be carried through"
    assert _db.USER == "forge", "USER must be carried through"

    # The strongest form of "no plaintext password": the section has exactly
    # these four keys, so there is nowhere for one to hide.
    assert sorted([k for k in _db]) == ["DB_TYPE", "HOST", "NAME", "USER"], "the database section must carry no credential key: got ${_db}"
    _src = _v.gitea.additionalConfigSources
    assert len(_src) == 1, "one mounted config source: the database password"
    assert _src[0].secret.items == [{key = "pgpass", path = "database"}], "the projected file name is the app.ini section the fragment belongs to"
    assert "PASSWD" not in str(_v), "the password fragment lives in the Secret, so PASSWD must not appear anywhere in the Release values"
}
test_database_defaults_names = lambda {
    _db = _tvalues({
        database = {mode = "postgres", host = "pg.data.svc:5432"}
    }).gitea.config.database
    assert _db.NAME == "forgejo" and _db.USER == "forgejo", "an unnamed database and user default to the chart name"
}

# 3) adminSecret names an EXISTING Secret; no credential is generated here.
test_admin_secret = lambda {
    _v = _tvalues({adminSecret = "git-admin"})
    assert _v.gitea.admin.existingSecret == "git-admin", "the admin credential must be sourced from the user's Secret"
    assert "password" not in str(_v.gitea.admin), "the admin password must never appear in the Release values"
}

# 4) hostname is the one input three chart keys derive from; TLS flips the
#    scheme Forgejo advertises.
test_hostname_drives_urls = lambda {
    _v = _tvalues({})
    assert _v.gitea.config.server.ROOT_URL == "http://git.example.org", "ROOT_URL must be built from hostname"
    assert _v.gitea.config.server.DOMAIN == "git.example.org", "DOMAIN must be the hostname"
    assert _v.ingress.hosts[0].host == "git.example.org", "the ingress must serve the hostname"
    assert _v.ingress.hosts[0].paths[0].pathType == "Prefix", "the whole forge is served under /"
    assert _v.ingress?.tls == Undefined, "no tlsSecretName means no TLS block"
}
test_ingress_tls_and_class = lambda {
    _v = _tvalues({
        ingress = {className = "nginx", tlsSecretName = "git-tls"}
    })
    assert _v.ingress.className == "nginx", "className must be forwarded"
    assert _v.ingress.tls == [{secretName = "git-tls", hosts = ["git.example.org"]}], "the TLS secret must cover the hostname"
    assert _v.gitea.config.server.ROOT_URL == "https://git.example.org", "TLS at the ingress makes the public URL https"
}
test_ingress_disabled = lambda {
    assert _tvalues({
        ingress = {enabled = False}
    }).ingress.enabled == False, "ingress.enabled=false must survive: `or` would swallow it"
}

# 5) deletionPolicy=Orphan leaves the release (and the repositories) installed.
test_deletion_policy_orphan = lambda {
    assert forge.render(_tbuild({deletionPolicy = "Orphan"}), _tteam)[0].spec.managementPolicies == _orphan, "Orphan must set the orphan policies"
}
test_deletion_policy_delete_default = lambda {
    assert forge.render(_tbuild({}), _tteam)[0].spec.managementPolicies == ["*"], "Delete must leave the provider-default managementPolicies"
}

# 6) spec.values is the escape hatch: merged LAST, deep, and it wins.
test_values_escape_hatch = lambda {
    _v = _tvalues({
        values = {persistence = {size = "500Gi"}, podAnnotations = {"prometheus.io/scrape" = "true"}}
    })
    assert _v.persistence.size == "500Gi", "spec.values must override a computed key"
    assert _v.persistence.enabled == True, "the merge must be deep: a sibling key must survive an override"
    assert _v.podAnnotations == {"prometheus.io/scrape" = "true"}, "spec.values must be able to add a key this XRD does not model"
    assert _v.fullnameOverride == "git", "untouched computed keys must remain"
}

# 7) highAvailability is enterprise-only and needs an external database; a KCL
#    test cannot catch an assert, so only the entitled shape is covered here.
test_high_availability_enterprise = lambda {
    _v = forge.render(_tbuild({
        highAvailability = True
        database = {mode = "postgres", host = "pg.data.svc:5432"}
    }), _tenterprise)[0].spec.forProvider.values
    assert _v.replicaCount == 2, "HA must run more than one replica"
    assert _v.persistence.accessModes == ["ReadWriteMany"], "replicas share one repository volume, so it must be RWX"
    assert _v.gitea.config.indexer.ISSUE_INDEXER_TYPE == "db", "the per-pod bleve indexer cannot back multiple replicas"
    assert _v.gitea.config.session.PROVIDER == "db", "in-memory sessions would log users out on every reschedule"
}

# 8) status: the endpoints are deterministic from the XR's name, so they are
#    published before the chart is up; readiness and the deployed version are
#    read back from the Release.
test_status_pre_deploy = lambda {
    dxr = forge.status(_tbuild({}), {}, _tteam)
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Forge", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "an unobserved Release is not ready"

    # The cross-capability contract a Repository XR is configured from. The
    # `-http` suffix is the chart's own Service name: if upstream renames it,
    # this assertion fails here instead of every tenant's Repository.
    assert dxr.status.apiUrl == "http://git-http.apps.svc:3000/api/v1", "apiUrl must be the in-cluster API root of the chart's web Service"
    assert dxr.status.service == "git-http", "the chart names its web Service <fullname>-http"
    assert dxr.status.url == "http://git.example.org", "url must be the public web UI"
    assert dxr.status.plan == "team", "the plan must be reported from the gate"
    assert dxr.status.chartVersion == "17.1.5", "the pinned chart version must be reported before the release exists"
    assert dxr.status.release == "", "no observed Release means no release name yet"
}
test_status_deployed = lambda {
    ocds = {
        managed.Resource = {
            metadata.annotations = {"crossplane.io/external-name" = "git"}
            status = {
                conditions = [{type = "Synced", status = "True"}, {type = "Ready", status = "True"}]
                atProvider = {state = "deployed", revision = 1, version = "17.1.5"}
            }
        }
    }
    dxr = forge.status(_tbuild({
        ingress = {tlsSecretName = "git-tls"}
    }), ocds, _tenterprise)
    assert dxr.status.ready == True, "a Release whose Ready condition is True is ready"
    assert dxr.status.plan == "enterprise", "the plan must be copied off the gate"
    assert dxr.status.release == "git", "the release name is the external-name provider-helm pinned"
    assert dxr.status.url == "https://git.example.org", "a TLS ingress makes the reported URL https"
    assert dxr.status.apiUrl == "http://git-http.apps.svc:3000/api/v1", "the API root must not change once deployed"
}
test_status_not_ready = lambda {
    ocds = {managed.Resource.status.conditions = [{type = "Ready", status = "False", message = "release failed"}]}
    assert forge.status(_tbuild({}), ocds, _tteam).status.ready == False, "a Release whose Ready condition is False is not ready"
}

test_render_minimal()
test_database_postgres()
test_database_defaults_names()
test_admin_secret()
test_hostname_drives_urls()
test_ingress_tls_and_class()
test_ingress_disabled()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_values_escape_hatch()
test_high_availability_enterprise()
test_status_pre_deploy()
test_status_deployed()
test_status_not_ready()
