# email (stalwart) — Crossplane Composition logic (function-kcl module).
# The in-cluster backend: no cloud account, no SES sandbox. Typed against the
# helm schema package, it renders one namespaced provider-helm Release that
# installs the Stalwart all-in-one mail server into the XR's own namespace.
# Domain and DKIM provisioning happen inside Stalwart at runtime (admin UI /
# stalwart-cli), not through chart values — the XR provisions the server,
# deterministic endpoints, and storage.
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Pinned so a re-render never silently upgrades a running mail store. The chart
# lives in an OCI registry, so `repository` is the oci:// path and `name` is
# the last path segment — helm resolves them as <repository>/<name>.
chart_repository = "oci://codeberg.org/wrenix/helm-charts"
chart_name = "stalwart-mail"
# app 0.16.19
chart_version = "2.0.9"

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"

    # Ignored in-cluster: region (the server runs where the XR lives),
    # mailFromSubdomain (the envelope domain is the domain itself),
    # dkimKeyLength (Stalwart generates and manages its own DKIM keys),
    # tlsRequired (STARTTLS is always offered), and the SES ConfigurationSet
    # knobs sendingEnabled, reputationMetrics and suppressedReasons, which
    # have no chart-level equivalent.
    _values = {
        # Deterministic service names: status() derives the SMTP endpoint from
        # the release name instead of reading it back from the chart.
        fullnameOverride = _name
        persistence = {enabled = True, size = "${_spec?.persistenceSizeGb or 10}Gi"}
        # The chart writes .Values.config verbatim to Stalwart's config.json,
        # and its default `"@type": ""` is not a valid data store — the server
        # exits at startup ("unknown variant ``, expected one of RocksDb, …").
        # Single-node on the PVC means the embedded RocksDb store; `path` is
        # required (serde errors "mkdir if missing" without it) and lives on
        # the chart's /var/lib/stalwart PVC mount. The connection fields only
        # apply to external stores, so null them out (helm drops null keys
        # when coalescing over the chart defaults).
        config = {
            "@type" = "RocksDb"
            path = "/var/lib/stalwart/data"
            host = None
            database = None
            authUsername = None
            authSecret = None
        }
        # The chart defaults to a cert-manager Certificate against a
        # `letsencrypt-prod` ClusterIssuer — on a cluster that has cert-manager
        # but not that issuer, the secret never appears and the pod hangs in
        # ContainerCreating on the missing mount. Disable it; Stalwart falls
        # back to its own self-signed certificate for STARTTLS. A real cert
        # rides in via certificateSecret (mounted, certmanager stays off).
        certificate = {
            certmanager = {enabled = False}
            if _spec?.certificateSecret:
                secretName = _spec.certificateSecret
        }
        # The chart probes /healthz on its `http` port, which defaults to 80 —
        # a port Stalwart never opens: first boot comes up in recovery mode
        # (the chart's own env defaults) listening only on 8080, and even a
        # configured server serves HTTP there. Left at 80 the pod restart-loops
        # forever and the release never deploys. 8080 answers /healthz in both
        # states (verified live=200/ready=200 in recovery mode).
        service = {
            ports = {http = 8080}
        }
        if _spec?.tags:
            # the chart has no commonLabels
            podLabels = _spec.tags
    }

    [backend.Release {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if (_spec?.deletionPolicy or "Delete") == "Orphan":
            spec.managementPolicies = _orphan_policies
        # The helm provider runs with in-cluster identity, so one cluster-wide
        # config serves XRs in every namespace.
        spec.providerConfigRef = {kind = "ClusterProviderConfig", name = "default"}
        spec.forProvider.namespace = _ns
        spec.forProvider.chart = {
            name = chart_name
            repository = chart_repository
            version = chart_version
        }
        spec.forProvider.values = _values
        # The fallback admin password rides a `set` override with valueFrom so
        # it never lands in the persisted values blob; the Secret is resolved
        # in the Release's namespace, which is the XR's.
        if _spec?.adminPasswordSecret:
            spec.forProvider.set = [{
                name = "secrets.env.FALLBACK_ADMIN_SECRET"
                valueFrom.secretKeyRef = {
                    name = _spec.adminPasswordSecret.name
                    key = _spec.adminPasswordSecret?.key or "password"
                }
            }]
        spec.forProvider.wait = True
        spec.forProvider.waitTimeout = "10m"
        # Without a rollback limit provider-helm never retries a release whose
        # first install failed (e.g. the wait timed out) — the Release sits in
        # `failed` forever even after the desired values change.
        spec.rollbackLimit = 3
    }]
}

# Build the desired composite carrying observed status back to the XR.
# In-cluster endpoints are deterministic from the release name (thanks to
# fullnameOverride), so they are reported as soon as the chart is deployed
# rather than read back from a cloud API.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _ready = (_at?.state or "") == "deployed"
    _host = "${_name}.${_ns}.svc.cluster.local"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "EmailDomain"
        metadata.name = _name
        status = {
            provider = "stalwart"
            ready = _ready
            # No external verification gate in-cluster: the server accepts and
            # signs mail for the domain as soon as it is deployed, so verified
            # tracks ready. dkimTokens/dnsRecords are intentionally absent —
            # Stalwart manages DKIM internally; fetch the records from its
            # admin UI or `stalwart-cli dns records`.
            verified = _ready
            smtpHost = _host
            smtpPort = 587
            smtpEndpoint = "${_host}:587"
            "cloud-url" = "kubernetes://${_ns}/deployment/${_name}"
            if _at?.revision:
                id = "${_ns}/${_name}@${_at.revision}"
        }
    }
}
