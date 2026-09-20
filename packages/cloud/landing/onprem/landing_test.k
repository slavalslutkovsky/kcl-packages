# Unit tests for the landing (onprem) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (one provider-helm Release, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# The page itself lives inside the Release's chart values — a ConfigMap in
# extraDeploy plus the nginx serverBlock that serves it — so most assertions
# read the values rather than composed Kubernetes objects.
import .landing

_html = "<!doctype html><title>demo</title><h1>demo</h1>"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`. `|`
# replaces a whole top-level key, so `content` is merged explicitly: a test
# that adds files still gets the base HTML.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "LandingPage", metadata = {name = "demo", namespace = "apps"}, spec = {region = "us-east-1"} | extra | {content = {html = _html} | (extra?.content or {})}}
}

# The composed resource carrying the given composition-resource-name.
_res = lambda extra: any, name: str -> any {
    [_r for _r in landing.render(_build(extra)) if _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] == name][0]
}

# The Release's chart values for the given spec.
_values = lambda extra: any -> any {
    _res(extra, "managed").spec.forProvider.values
}

# The ConfigMap the chart deploys alongside nginx and mounts as the doc root.
_configmap = lambda extra: any -> any {
    _values(extra).extraDeploy[0]
}

# 1) Minimal spec: one namespaced Release of the pinned chart, named `managed`,
#    waiting for the chart before it reports ready.
test_render_minimal = lambda {
    items = landing.render(_build({}))
    assert len(items) == 1, "the onprem backend is a single Release — a Release has a Ready condition covering the whole chart, individual Deployments do not"
    _r = items[0]
    assert _r.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "the content store must be named `managed` so status() can find it"
    assert _r.apiVersion == "helm.m.crossplane.io/v1beta1", "wrong Release apiVersion"
    assert _r.kind == "Release", "the composed MR must be a helm Release"
    assert _r.metadata?.namespace == Undefined, "composed objects carry no namespace — Crossplane places them"
    assert _r.metadata.annotations["crossplane.io/external-name"] == "demo", "the Helm release name must be pinned to the XR name so it matches fullnameOverride"
    assert _r.spec.providerConfigRef.kind == "ClusterProviderConfig" and _r.spec.providerConfigRef.name == "default", "provider-helm runs with in-cluster identity: one cluster-wide config serves every namespace"
    assert _r.spec.rollbackLimit == 3, "a failed upgrade must roll back to the content that was being served"
    _fp = _r.spec.forProvider
    assert _fp.namespace == "apps", "the chart must land in the XR's namespace"
    assert _fp.wait == True, "the Release must report ready only once the chart is up"
    assert _fp.waitTimeout == "10m", "the Release must not wait forever"
}

# 2) Chart coordinates stay pinned: a floating version would silently upgrade a
#    running site on the next reconcile.
test_chart_pinned = lambda {
    _chart = _res({}, "managed").spec.forProvider.chart
    assert _chart.name == "nginx", "the page is served by nginx"
    assert _chart.repository == "oci://registry-1.docker.io/bitnamicharts", "the nginx chart comes from the Bitnami OCI registry"
    assert _chart.version == "25.1.13", "the chart version must stay pinned"
}

# 3) The content: one ConfigMap deployed with the chart, holding the index
#    document under content.index plus one key per companion file, and named by
#    staticSiteConfigmap so the chart mounts it as the document root.
test_content_configmap = lambda {
    _v = _values({
        content = {files = [
            {path = "styles.css", content = "body{}"}
            {path = "404.html", content = "<h1>gone</h1>"}
        ]}
    })
    _cm = _v.extraDeploy[0]
    assert _cm.apiVersion == "v1" and _cm.kind == "ConfigMap", "the content must be a plain ConfigMap, not a managed resource"
    assert _cm.metadata.name == "demo-content", "the ConfigMap is named after the XR"
    assert _cm.metadata.namespace == "apps", "the ConfigMap must live where the release does"
    assert _v.staticSiteConfigmap == "demo-content", "the chart must be told which ConfigMap to serve"
    assert _cm.data["index.html"] == _html, "content.html must be served under content.index"
    assert _cm.data["styles.css"] == "body{}", "every content.files[] entry must become a key"
    assert _cm.data["404.html"] == "<h1>gone</h1>", "the error document is just another file"
    assert len(_cm.data) == 3, "the ConfigMap must hold the index plus each file and nothing else"
}

# 4) content.index renames the key the HTML is written to, and the key nginx
#    serves for a directory request.
test_content_index_renamed = lambda {
    _v = _values({
        content = {index = "home.html"}
    })
    assert _v.extraDeploy[0].data == {"home.html" = _html}, "content.html must follow content.index"
    assert "index home.html;" in _v.serverBlock, "nginx must serve the renamed index for a directory request"
}

# 5) content.files[].contentType is documented as ignored here: nginx answers
#    from its own mime.types, keyed by the same extension the cloud backends
#    derive from. It must not leak into the ConfigMap as a key or a value.
test_content_type_ignored = lambda {
    _data = _configmap({
        content = {files = [{path = "logo.svg", content = "<svg/>", contentType = "image/svg+xml"}]}
    }).data
    assert _data == {"index.html" = _html, "logo.svg" = "<svg/>"}, "an explicit contentType has nowhere to go in a ConfigMap and must not distort the content"
}

# 6) A path with a slash is REJECTED by an assert in render() (a ConfigMap key
#    cannot hold a separator). KCL cannot assert that an assert fails, so this
#    pins the accepted shape instead: the same asset flattened renders, which
#    is exactly the fix the rejection message names.
test_flattened_path_accepted = lambda {
    assert _configmap({
        content = {files = [{path = "assets-logo.svg", content = "<svg/>"}]}
    }).data["assets-logo.svg"] == "<svg/>", "a flattened path is a valid ConfigMap key and must render"
}

# 7) The server config: the chart's own block is replaced, so listen/root are
#    the chart's verified internals and index/error_page/Cache-Control are the
#    XR's.
test_server_block_defaults = lambda {
    _sb = _values({}).serverBlock
    assert "listen 8080;" in _sb, "the chart's nginx runs unprivileged on 8080"
    assert "root /app;" in _sb, "the static-site ConfigMap is mounted at /app"
    assert "index index.html;" in _sb, "content.index must default to index.html"
    assert "error_page 404 /404.html;" in _sb, "content.errorDocument must default to 404.html"
    assert 'add_header Cache-Control "public, max-age=3600";' in _sb, "cdn.ttlSeconds must default to 3600"
}
test_server_block_from_spec = lambda {
    _sb = _values({content = {errorDocument = "oops.html"}, cdn = {ttlSeconds = 60}}).serverBlock
    assert "error_page 404 /oops.html;" in _sb, "content.errorDocument must drive nginx's error_page"
    assert 'add_header Cache-Control "public, max-age=60";' in _sb, "cdn.ttlSeconds must drive the served max-age"
}
test_server_block_zero_ttl = lambda {
    assert 'max-age=0";' in _values({
        cdn = {ttlSeconds = 0}
    }).serverBlock, "ttlSeconds=0 means do not cache, not fall back to the default"
}

# 8) No domain: the ClusterIP Service is the only address, so no Ingress is
#    published (one with an empty host would answer for every unmatched request
#    the controller receives).
test_no_domain_no_ingress = lambda {
    _v = _values({})
    assert _v?.ingress == Undefined, "without spec.domain there is no Ingress to publish"
    assert _v.service == {"type" = "ClusterIP", ports = {http = 80}}, "the page is published in-cluster on port 80"
}

# 9) A domain publishes an Ingress; TLS defaults on and asks cert-manager for
#    the certificate.
test_ingress_tls_default = lambda {
    _ing = _values({domain = "www.example.com"}).ingress
    assert _ing.enabled == True, "spec.domain must publish an Ingress"
    assert _ing.hostname == "www.example.com", "the Ingress must answer on spec.domain"
    assert _ing.ingressClassName == "nginx", "ingressClassName must default to nginx"
    assert _ing.path == "/" and _ing.pathType == "Prefix", "the whole site is served from the root"
    assert _ing.tls == True, "tls.enabled must default to true"
    assert _ing.annotations == {"cert-manager.io/cluster-issuer" = "letsencrypt-prod"}, "tls.issuer must default to letsencrypt-prod"
}
test_ingress_class_and_issuer = lambda {
    _ing = _values({domain = "www.example.com", ingressClassName = "traefik", tls = {issuer = "letsencrypt-staging"}}).ingress
    assert _ing.ingressClassName == "traefik", "ingressClassName must select the controller"
    assert _ing.annotations["cert-manager.io/cluster-issuer"] == "letsencrypt-staging", "tls.issuer must name the ClusterIssuer"
}
test_ingress_tls_disabled = lambda {
    _ing = _values({domain = "www.example.com", tls = {enabled = False}}).ingress
    assert _ing.tls == False, "tls.enabled=false must serve plain HTTP on the domain"
    assert _ing?.annotations == Undefined, "no TLS means nothing for cert-manager to issue"
}

# 10) cdn is ignored: the Ingress is this backend's only edge. Unlike the cloud
#     backends — which reject spec.domain when cdn.enabled=false because a raw
#     bucket endpoint carries neither domain nor TLS — onprem serves the domain
#     either way, so the two renders are identical.
test_cdn_ignored = lambda {
    assert _values({domain = "www.example.com", cdn = {enabled = False}}) == _values({domain = "www.example.com"}), "cdn.enabled must not change what the cluster serves"
}

# 11) replicas scale nginx; tags become pod labels.
test_replicas_and_tags = lambda {
    assert _values({}).replicaCount == 2, "replicas must default to 2"
    assert _values({})?.podLabels == Undefined, "no tags means no pod labels"
    _v = _values({replicas = 5, tags = {team = "platform"}})
    assert _v.replicaCount == 5, "spec.replicas must size the deployment"
    assert _v.podLabels == {team = "platform"}, "tags must become pod labels"
}

# 12) deletionPolicy is ignored: the Release (and the content it deploys) lives
#     and dies with the XR, so Orphan renders exactly like the default rather
#     than leaving an nginx nobody owns.
test_deletion_policy_ignored = lambda {
    assert _res({deletionPolicy = "Orphan"}, "managed").spec.managementPolicies == _res({}, "managed").spec.managementPolicies, "Orphan must not change the Release's management policies"
    assert _res({}, "managed").spec.managementPolicies == ["*"], "the provider default must be left alone"
}

# 13) status before the chart is deployed: the in-cluster address is
#     deterministic and reported straight away; readiness is not.
test_status_pre_deploy = lambda {
    dxr = landing.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "LandingPage", "dxr kind must echo the composite"
    assert dxr.metadata.name == "demo", "dxr must name the composite"
    assert dxr.status.provider == "onprem", "provider must be onprem"
    assert dxr.status.ready == False, "an undeployed Release is not ready"
    assert dxr.status.host == "demo.apps.svc.cluster.local", "without a domain the Service is the address"
    assert dxr.status.url == "http://demo.apps.svc.cluster.local", "the in-cluster Service serves plain HTTP on port 80"
    assert dxr.status.bucketName == "demo-content", "the ConfigMap is the store holding the content"
    assert dxr.status.cdn == False, "there is no edge cache in front of an Ingress"
    assert dxr.status["cloud-url"] == "kubernetes://apps/deployment/demo", "the in-cluster reference is the nginx Deployment"
    assert dxr.status?.id == Undefined, "nothing observed yet, so there is no release id"
    assert dxr.status?.dnsRecordType == Undefined, "no domain means no DNS record to create"
}

# 14) status once the Release is observed.
test_status_deployed = lambda {
    ocds = {
        managed.Resource.status.atProvider = {state = "deployed", revision = 4}
    }
    dxr = landing.status(_build({}), ocds)
    assert dxr.status.ready == True, "a deployed Release is serving the page"
    assert dxr.status.id == "apps/demo@4", "id must carry the release revision"
}
test_status_not_deployed_yet = lambda {
    ocds = {
        managed.Resource.status.atProvider = {state = "pending-install", revision = 1}
    }
    assert landing.status(_build({}), ocds).status.ready == False, "only a deployed Release is ready"
}

# 15) status with a custom domain: the record to create is a CNAME, but its
#     target belongs to the ingress controller, which this XR does not compose
#     and cannot observe — so dnsTarget is never reported. Nor is a certificate
#     status: cert-manager's issuance is invisible from the Release.
test_status_domain_tls = lambda {
    dxr = landing.status(_build({domain = "www.example.com"}), {})
    assert dxr.status.host == "www.example.com", "the custom domain is the host"
    assert dxr.status.url == "https://www.example.com", "TLS on the domain means https"
    assert dxr.status.dnsRecordType == "CNAME", "the Ingress is reached by name"
    assert dxr.status?.dnsTarget == Undefined, "the ingress controller's address is not observable from here"
    assert dxr.status?.certificateStatus == Undefined, "cert-manager issuance is not reported by the Release"
    assert dxr.status?.validationRecords == Undefined, "cert-manager needs no ownership records from the user"
    assert dxr.status?.arn == Undefined, "arn is AWS-only"
}
test_status_domain_without_tls = lambda {
    dxr = landing.status(_build({domain = "www.example.com", tls = {enabled = False}}), {})
    assert dxr.status.url == "http://www.example.com", "tls.enabled=false must be reported as plain HTTP"
    assert dxr.status.dnsRecordType == "CNAME", "the record is still a CNAME to the controller"
}

test_render_minimal()
test_chart_pinned()
test_content_configmap()
test_content_index_renamed()
test_content_type_ignored()
test_flattened_path_accepted()
test_server_block_defaults()
test_server_block_from_spec()
test_server_block_zero_ttl()
test_no_domain_no_ingress()
test_ingress_tls_default()
test_ingress_class_and_issuer()
test_ingress_tls_disabled()
test_cdn_ignored()
test_replicas_and_tags()
test_deletion_policy_ignored()
test_status_pre_deploy()
test_status_deployed()
test_status_not_deployed_yet()
test_status_domain_tls()
test_status_domain_without_tls()
