# landing (onprem) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend: no cloud account, no object storage, no CDN. The
# page is served from the very cluster the XR lives in by one namespaced
# provider-helm Release of the Bitnami nginx chart, whose document root is a
# ConfigMap carrying the content straight out of the XR.
#
# One Release and nothing else, deliberately: a Release has a Ready condition
# that tracks the whole chart, which is what lets function-auto-ready tell the
# truth about the page. Composing bare Deployment/Service/Ingress objects would
# report ready the moment the API server accepted them.
#
# Not installed here: cert-manager and an ingress controller. Both are cluster
# infrastructure shared by every XR; this XR only annotates its Ingress for
# them.
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as backend
import k8s.api.core.v1 as corev1

# Pinned so a re-render never silently upgrades a running site.
chart_repository = "oci://registry-1.docker.io/bitnamicharts"
chart_name = "nginx"
chart_version = "25.1.13"

# Chart internals, read from the rendered manifests of nginx 25.1.13
# (`helm template oci://registry-1.docker.io/bitnamicharts/nginx
#   --version 25.1.13 --set staticSiteConfigmap=demo-content`):
# the `staticsite` volume is mounted at /app, and the http container port is
# 8080 (the chart runs unprivileged). Both are pinned beside the chart version
# they were read from, because `serverBlock` replaces the chart's own server
# config and has to name them itself.
static_site_root = "/app"
container_port = 8080

# What the chart's ClusterIP Service publishes — the port status.url omits.
service_port = 80

# Chart resource names, given `fullnameOverride = <xr name>`.
service_host = lambda name: str, namespace: str -> str {
    "${name}.${namespace}.svc.cluster.local"
}

# The store holding the content, reported as status.bucketName.
content_configmap = lambda name: str -> str {
    "${name}-content"
}

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# The nginx server config that makes the page behave. It replaces the chart's
# default block entirely, hence the explicit listen/root.
server_block = lambda index: str, error_document: str, ttl: int -> str {
    """server {
    listen ${container_port};
    server_name _;
    root ${static_site_root};
    index ${index};
    error_page 404 /${error_document};
    add_header Cache-Control "public, max-age=${ttl}";
}
"""
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"

    _content = _spec.content
    _index = _content?.index or "index.html"
    _error_document = _content?.errorDocument or "404.html"
    _files = _content?.files or []
    _ttl = _spec?.cdn?.ttlSeconds
    if _ttl in [None, Undefined]:
        _ttl = 3600

    _domain = _spec?.domain
    _tls = _flag(_spec?.tls?.enabled, True)
    _issuer = _spec?.tls?.issuer or "letsencrypt-prod"

    _cm_name = content_configmap(_name)

    # The content is mounted as one ConfigMap, and a ConfigMap key is a file
    # name: it cannot hold a path separator. A failed assert surfaces as a
    # fatal function result, which is the only honest answer — the alternative
    # is mangling the key and serving the asset from somewhere the HTML does
    # not reference.
    assert all _f in _files {
        "/" not in _f.path
    }, "landing-onprem: content.files[].path must not contain '/' — the content is served from a ConfigMap and a ConfigMap key cannot hold a path separator; flatten the path (assets/logo.svg -> assets-logo.svg) or put the asset behind a Bucket XR and link it by URL"
    assert "/" not in _index, "landing-onprem: content.index must not contain '/' — it is a ConfigMap key; use a bare file name (index.html)"

    # content.html is the index document and is written last, so it wins over a
    # files[] entry that claims the same key.
    _data: {str:str} = {_f.path: _f.content for _f in _files} | {"${_index}" = _content.html}

    # content.files[].contentType is IGNORED here (documented, not silently
    # dropped): nginx answers with the type its own mime.types maps the key's
    # extension to — the same extension table the cloud backends derive their
    # object contentType from — and a per-file override would need one nginx
    # location block per file.
    _configmap = corev1.ConfigMap {
        metadata = {
            name = _cm_name
            namespace = _ns
        }
        data = _data
    }

    _values = {
        fullnameOverride = _name
        replicaCount = _spec?.replicas or 2
        service = {$type = "ClusterIP", ports = {http = service_port}}
        # The chart mounts this ConfigMap as the document root; extraDeploy is
        # what creates it, so content and server ship as one release.
        extraDeploy = [_configmap]
        staticSiteConfigmap = _cm_name
        serverBlock = server_block(_index, _error_document, _ttl)
        if _spec?.tags:
            podLabels = _spec.tags
        # Without a domain the chart publishes the ClusterIP Service only: an
        # Ingress with no host would grab every unmatched request reaching the
        # controller. spec.cdn is ignored throughout — the Ingress is the only
        # edge this backend has, which is why status.cdn is false.
        if _domain:
            ingress = {
                enabled = True
                hostname = _domain
                ingressClassName = _spec?.ingressClassName or "nginx"
                path = "/"
                pathType = "Prefix"
                tls = _tls
                if _tls:
                    annotations = {"cert-manager.io/cluster-issuer" = _issuer}
            }
    }

    # spec.deletionPolicy is IGNORED: there are no cloud resources to orphan,
    # and the Release (with the ConfigMap it deploys) lives and dies with the
    # XR. Emitting managementPolicies for Orphan would leave a running nginx
    # nobody owns, which is not what the field promises.
    #
    # external-name pins the Helm release name to the XR name, so the chart's
    # resource names match `fullnameOverride` (and the Service host status()
    # reports).
    [backend.Release {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
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
        spec.forProvider.wait = True
        spec.forProvider.waitTimeout = "10m"
        # A landing page that fails to upgrade must keep serving the previous
        # content rather than sit half-applied.
        spec.rollbackLimit = 3
    }]
}

# Build the desired composite carrying observed status back to the XR.
# In-cluster addresses are deterministic from the release name, so they are
# reported before the chart is deployed; readiness is not.
#
# status.dnsTarget is deliberately NOT emitted. The address a record for
# spec.domain must point at is the ingress controller's — a LoadBalancer this
# XR neither composes nor observes. Echoing the domain back would be a CNAME
# loop dressed up as an answer.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _domain = _spec?.domain
    _tls = _flag(_spec?.tls?.enabled, True)
    _svc = service_host(_name, _ns)
    _host = _domain or _svc

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "LandingPage"
        metadata.name = _name
        status = {
            provider = "onprem"
            ready = (_at?.state or "") == "deployed"
            host = _host
            url = ("https://${_domain}" if _tls else "http://${_domain}") if _domain else "http://${_svc}"
            # The ConfigMap is this backend's content store.
            bucketName = content_configmap(_name)
            # The Ingress is the only edge: there is no cache in front of it.
            cdn = False
            if _domain:
                dnsRecordType = "CNAME"
            "cloud-url" = "kubernetes://${_ns}/deployment/${_name}"
            if _at?.revision:
                id = "${_ns}/${_name}@${_at.revision}"
        }
    }
}
