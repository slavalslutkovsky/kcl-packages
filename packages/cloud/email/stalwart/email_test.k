import .email

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec, _ns: str = "default" {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "EmailDomain", metadata = {name = "demo", namespace = _ns}, spec = _spec}
}

# The single Helm Release forProvider block from a render().
_fp = lambda _spec {
    email.render(_build(_spec))[0].spec.forProvider
}

# The chart values the Release installs with.
_values = lambda _spec {
    _fp(_spec).values
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = email.render(_build({region = "in-cluster", domain = "mail.internal.example"}))
    assert len(items) == 1, "the in-cluster backend must emit exactly one Release"
    assert items[0].apiVersion == "helm.m.crossplane.io/v1beta1", "must use the namespaced helm CRD"
    assert items[0].kind == "Release", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].spec.providerConfigRef.kind == "ClusterProviderConfig", "must bind the cluster-wide helm config"
    fp = items[0].spec.forProvider
    assert fp.chart.name == "stalwart-mail", "chart must be stalwart-mail"
    assert fp.chart.repository == email.chart_repository, "chart repository must be the pinned one"
    assert fp.chart.version == email.chart_version, "chart version must be pinned, never floating"
    assert fp.wait == True, "the release must be waited on so auto-ready reflects reality"
    assert items[0].spec.rollbackLimit == 3, "failed installs must retry, or the release wedges in `failed`"
}

# The chart lands in the XR's own namespace, not a shared one.
test_namespace_follows_xr = lambda {
    assert _fp({region = "in-cluster", domain = "mail.internal.example"}).namespace == "default", "default namespace when the XR has none"
    items = email.render(_build({region = "in-cluster", domain = "mail.internal.example"}, "team-a"))
    assert items[0].spec.forProvider.namespace == "team-a", "release must follow the XR's namespace"
}

# ---- render: values ---------------------------------------------------------

# fullnameOverride is what makes the SMTP service name — and therefore
# status.smtpHost — deterministic.
test_fullname_override = lambda {
    assert _values({region = "in-cluster", domain = "mail.internal.example"}).fullnameOverride == "demo", "release name must pin the chart resource names"
}

test_persistence = lambda {
    _v = _values({region = "in-cluster", domain = "mail.internal.example"})
    assert _v.persistence.enabled == True, "the mail store must always persist"
    assert _v.persistence.size == "10Gi", "PVC size defaults to 10Gi"
    assert _values({region = "in-cluster", domain = "mail.internal.example", persistenceSizeGb = 20}).persistence.size == "20Gi", "persistenceSizeGb must size the PVC"
}

# The chart's cert-manager default points at a `letsencrypt-prod` ClusterIssuer
# that dev clusters don't have — left on, the pod hangs in ContainerCreating on
# the never-issued cert secret. It must always be off; a real cert rides in as
# an existing secret instead.
test_certificate = lambda {
    _v = _values({region = "in-cluster", domain = "mail.internal.example"})
    assert _v.certificate.certmanager.enabled == False, "chart cert-manager default must be disabled"
    assert _v.certificate?.secretName == Undefined, "no cert secret unless asked for -> self-signed"
    _tls = _values({region = "in-cluster", domain = "mail.internal.example", certificateSecret = "mail-tls"}).certificate
    assert _tls.secretName == "mail-tls", "certificateSecret must mount the existing secret"
    assert _tls.certmanager.enabled == False, "certmanager stays off even with a secret"
}

# The chart writes .Values.config verbatim to Stalwart's config.json, and its
# default `"@type": ""` crashes the server at startup. The embedded RocksDb
# store must be selected, and the external-store connection fields nulled so
# helm drops them from the merged values.
test_store_config = lambda {
    _c = _values({region = "in-cluster", domain = "mail.internal.example"}).config
    assert _c["@type"] == "RocksDb", "the data store must be the embedded RocksDb"
    assert _c.path == "/var/lib/stalwart/data", "RocksDb requires a path, on the chart's PVC mount"
    assert _c.host == None, "host must be nulled for helm to drop it"
    assert _c.database == None, "database must be nulled for helm to drop it"
    assert _c.authUsername == None, "authUsername must be nulled for helm to drop it"
    assert _c.authSecret == None, "authSecret must be nulled for helm to drop it"
}

# The chart's probes hit its `http` port; Stalwart never listens on the
# default 80 (recovery mode and configured servers both use 8080), so the
# override is what lets the pod pass its probes and the release deploy.
test_http_port = lambda {
    assert _values({region = "in-cluster", domain = "mail.internal.example"}).service.ports.http == 8080, "http port must be 8080 or the probes never pass"
}

test_labels = lambda {
    assert _values({region = "in-cluster", domain = "mail.internal.example", tags = {team = "platform"}}).podLabels == {team = "platform"}, "tags -> podLabels"
    assert _values({region = "in-cluster", domain = "mail.internal.example"})?.podLabels == Undefined, "no labels unless asked for"
}

# ---- render: admin password -------------------------------------------------

# The password rides a `set` override with valueFrom so it never appears in
# the persisted values blob.
test_admin_password_secret = lambda {
    _set = _fp({region = "in-cluster", domain = "mail.internal.example", adminPasswordSecret = {name = "stalwart-admin", key = "pw"}}).set
    assert len(_set) == 1, "exactly one set override for the admin password"
    assert _set[0].name == "secrets.env.FALLBACK_ADMIN_SECRET", "must target the chart's fallback admin env var"
    assert _set[0].valueFrom.secretKeyRef.name == "stalwart-admin", "secret name must be carried"
    assert _set[0].valueFrom.secretKeyRef.key == "pw", "secret key must be carried"
    assert _set[0]?.value == Undefined, "the password must never be inlined"
    _defaulted = _fp({region = "in-cluster", domain = "mail.internal.example", adminPasswordSecret = {name = "stalwart-admin"}}).set
    assert _defaulted[0].valueFrom.secretKeyRef.key == "password", "secret key defaults to password"
    assert _fp({region = "in-cluster", domain = "mail.internal.example"})?.set == Undefined, "no set overrides without a secret"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = email.render(_build({region = "in-cluster", domain = "mail.internal.example", deletionPolicy = "Orphan"}))[0].spec.managementPolicies
    assert _orphaned == _orphan, "Orphan must set the non-delete policies"
    _deleted = email.render(_build({region = "in-cluster", domain = "mail.internal.example"}))[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------

# In-cluster endpoints are derived from the release name, so they are known
# before the chart is deployed — but readiness is not.
test_status_pre_creation = lambda {
    dxr = email.status(_build({region = "in-cluster", domain = "mail.internal.example"}, "team-a"), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "EmailDomain", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "an undeployed release must not be ready"
    assert dxr.status.verified == False, "verified tracks ready in-cluster"
    assert dxr.status.provider == "stalwart", "provider must be stalwart"
    assert dxr.status.smtpHost == "demo.team-a.svc.cluster.local", "host is the chart's fullnameOverride service"
    assert dxr.status.smtpPort == 587, "submission port"
    assert dxr.status.smtpEndpoint == "demo.team-a.svc.cluster.local:587", "endpoint must be host:port"
    assert dxr.status["cloud-url"] == "kubernetes://team-a/deployment/demo", "cloud-url points at the workload"
    assert dxr.status?.dnsRecords == Undefined, "DKIM records come from stalwart-cli, not the XR"
    assert dxr.status?.id == Undefined, "no id before a revision exists"
}

test_status_deployed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {state = "deployed", revision = 3}
                }
            }
        }
    }
    dxr = email.status(_build({region = "in-cluster", domain = "mail.internal.example"}, "team-a"), ocds)
    assert dxr.status.ready == True, "a deployed release must be ready"
    assert dxr.status.verified == True, "no external verification gate in-cluster"
    assert dxr.status.smtpEndpoint == "demo.team-a.svc.cluster.local:587", "endpoint stays deterministic"
    assert dxr.status.id == "team-a/demo@3", "id must identify the release revision"
}

# A failed or pending release must not report ready.
test_status_failed_release = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {state = "failed", revision = 1}
                }
            }
        }
    }
    dxr = email.status(_build({region = "in-cluster", domain = "mail.internal.example"}), ocds)
    assert dxr.status.ready == False, "a failed release must not be ready"
    assert dxr.status.verified == False, "verified must not outrun readiness"
}
