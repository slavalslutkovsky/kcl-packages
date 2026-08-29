# Unit tests for the registry (zot) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (one provider-helm Release, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# zot's own configuration is a JSON document inside the Release values, so the
# assertions decode it rather than reading chart fields.
import json
import .registry

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Registry", metadata = {name = "demo", namespace = "apps"}, spec = {region = "us-east-1"} | extra}
}

# The Release's chart values for the given spec.
_values = lambda extra: any -> any {
    registry.render(_build(extra))[0].spec.forProvider.values
}

# zot's decoded config.json for the given spec.
_config = lambda extra: any -> any {
    json.decode(_values(extra)["configFiles"]["config.json"])
}

# 1) Minimal spec: one namespaced Release of the pinned chart into the XR's
#    namespace, persistent, config mounted.
test_render_minimal = lambda {
    items = registry.render(_build({}))
    assert len(items) == 1, "the in-cluster backend is a single Release"
    assert items[0].apiVersion == "helm.m.crossplane.io/v1beta1", "wrong Release apiVersion"
    assert items[0].kind == "Release", "the composed MR must be a helm Release"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the Helm release name must be pinned to the XR name"
    _fp = items[0].spec.forProvider
    assert _fp.namespace == "apps", "the chart must land in the XR's namespace"
    assert _fp.chart.name == "zot", "chart must be zot"
    assert _fp.chart.repository == "https://zotregistry.dev/helm-charts", "chart must come from the zot chart repo"
    assert _fp.chart.version == "0.1.122", "chart version must stay pinned"
    assert _fp.wait == True, "the Release must report ready only once the chart is up"
    assert items[0].spec.providerConfigRef.kind == "ClusterProviderConfig", "provider-helm runs with in-cluster identity"
    _v = _fp.values
    assert _v.fullnameOverride == "demo", "resource names must be derived from the XR name"
    assert _v.service["type"] == "ClusterIP", "the registry must not be exposed outside the cluster"
    assert _v.service.port == 5000, "zot serves on 5000"
    assert _v.persistence == True, "a registry that loses images on restart is not a registry"
    assert _v.pvc.storage == "8Gi", "storageGb must default to 8"
    assert _v.mountConfig == True, "the rendered config.json must be mounted"
    assert _v?.externalSecrets == Undefined, "no htpasswdSecret means no mounted secret"
}

# 2) storageGb sizes the volume; tags become pod labels.
test_storage_and_tags = lambda {
    _v = _values({storageGb = 50, tags = {team = "platform"}})
    assert _v.pvc.storage == "50Gi", "storageGb must size the PVC"
    assert _v.pvc.create == True, "the chart must provision the volume"
    assert _v.podLabels == {team = "platform"}, "tags must become pod labels"
}

# 3) The default config: garbage collection on, no auth, CVE search enabled.
test_config_defaults = lambda {
    _c = _config({})
    assert _c["storage"]["rootDirectory"] == "/var/lib/registry", "images must be stored on the volume"
    assert _c["storage"]["gc"] == True, "gc must be on for retention to ever act"
    assert _c["storage"]?["retention"] == Undefined, "no retention asked for"
    assert _c["http"]["port"] == "5000", "zot must listen on the service port"
    assert _c["http"]?["auth"] == Undefined, "no htpasswdSecret means anonymous access"
    assert _c["extensions"]["search"]["cve"]["updateInterval"] == "2h", "scanOnPush must default to the CVE extension"
}

# 4) scanOnPush=false drops the CVE search extension entirely.
test_scanning_disabled = lambda {
    assert _config({scanOnPush = False})?["extensions"] == Undefined, "scanOnPush=false must not enable extensions"
}

# 5) Retention: untagged deletion is delayed by the retention age, and
#    keepLastImages pins the most recent pushes.
test_retention_untagged = lambda {
    _r = _config({untaggedRetentionDays = 3})["storage"]["retention"]
    assert _r["dryRun"] == False, "retention must actually delete"
    assert _r["delay"] == "72h", "3 days must be expressed in hours"
    assert _r["policies"][0]["deleteUntagged"] == True, "untagged retention must delete untagged images"
    assert _r["policies"][0]?["keepTags"] == Undefined, "no image-count retention asked for"
}
test_retention_keep_last = lambda {
    _r = _config({keepLastImages = 10})["storage"]["retention"]
    assert _r?["delay"] == Undefined, "no age limit means no deletion delay"
    assert _r["policies"][0]["deleteUntagged"] == False, "keepLastImages alone must not delete untagged images"
    assert _r["policies"][0]["keepTags"][0]["patterns"] == [".*"], "keepTags patterns are Go regexes, not globs"
    assert _r["policies"][0]["keepTags"][0]["mostRecentlyPushedCount"] == 10, "keepLastImages must be carried through"
}
test_retention_both = lambda {
    _p = _config({untaggedRetentionDays = 1, keepLastImages = 4})["storage"]["retention"]["policies"][0]
    assert _p["deleteUntagged"] == True and _p["keepTags"][0]["mostRecentlyPushedCount"] == 4, "both retention rules in one policy"
}

# 6) htpasswdSecret turns on authentication and mounts the user's Secret; the
#    anonymous policy then follows publicAccess.
test_auth_private = lambda {
    _v = _values({htpasswdSecret = "registry-creds"})
    assert _v.externalSecrets == [{secretName = "registry-creds", mountPath = "/secret"}], "the Secret must be mounted where zot reads it"
    _http = _config({htpasswdSecret = "registry-creds"})["http"]
    assert _http["auth"]["htpasswd"]["path"] == "/secret/htpasswd", "zot must read the mounted htpasswd file"
    _repo = _http["accessControl"]["repositories"]["**"]
    assert _repo["anonymousPolicy"] == [], "a private registry must not serve anonymous clients"
    assert "create" in _repo["defaultPolicy"], "authenticated clients must be able to push"
}
test_auth_public_pull = lambda {
    _repo = _config({htpasswdSecret = "registry-creds", publicAccess = True})["http"]["accessControl"]["repositories"]["**"]
    assert _repo["anonymousPolicy"] == ["read"], "publicAccess must grant anonymous pull only"
}
test_public_access_without_auth = lambda {
    assert _config({publicAccess = True})["http"]?["accessControl"] == Undefined, "without htpasswd there is nothing to make public: zot is already open"
}

# 7) deletionPolicy=Orphan keeps the Release (and its images) behind.
test_deletion_policy_orphan = lambda {
    assert registry.render(_build({deletionPolicy = "Orphan"}))[0].spec.managementPolicies == _orphan, "Orphan must set the orphan policies"
}
test_deletion_policy_delete_default = lambda {
    assert registry.render(_build({}))[0].spec.managementPolicies == ["*"], "Delete must leave the provider-default managementPolicies"
}

# 8) status: in-cluster endpoints are deterministic, so they are reported
#    before the chart is deployed; readiness is not.
test_status_pre_deploy = lambda {
    dxr = registry.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Registry", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "an undeployed Release is not ready"
    assert dxr.status.provider == "zot", "provider must be zot"
    assert dxr.status.endpoint == "demo.apps.svc.cluster.local:5000", "endpoint is the chart's service"
    assert dxr.status.repository == "demo.apps.svc.cluster.local:5000/demo", "repository is the service plus the XR name"
    assert dxr.status.url == "oci://demo.apps.svc.cluster.local:5000/demo", "url must be the oci:// form"
    assert dxr.status["cloud-url"] == "kubernetes://apps/statefulset/demo", "persistence makes the workload a StatefulSet"
    assert dxr.status?.authSecret == Undefined, "no htpasswdSecret means no credentials to report"
}
test_status_deployed = lambda {
    ocds = {
        managed.Resource.status.atProvider = {state = "deployed", revision = 1}
    }
    dxr = registry.status(_build({htpasswdSecret = "registry-creds"}), ocds)
    assert dxr.status.ready == True, "a deployed Release is ready"
    assert dxr.status.id == "apps/demo@1", "id must carry the release revision"
    assert dxr.status.authSecret == "registry-creds", "the credential Secret must be reported"
}

test_render_minimal()
test_storage_and_tags()
test_config_defaults()
test_scanning_disabled()
test_retention_untagged()
test_retention_keep_last()
test_retention_both()
test_auth_private()
test_auth_public_pull()
test_public_access_without_auth()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_deploy()
test_status_deployed()
