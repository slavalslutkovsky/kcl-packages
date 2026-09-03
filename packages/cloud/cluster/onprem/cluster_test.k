import .cluster

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "KubernetesCluster"
        metadata = {name = "demo", namespace = "team-a"}
        spec = {region = "dc1", kubeconfigSecret = "demo-kubeconfig"} | _spec
    }
}

_render = lambda _spec, _ocds {
    cluster.render(_build(_spec), _ocds)
}

# What provider-helm reports once a chart is up.
_deployed = lambda _res: str {
    {
        "${_res}" = {
            Resource = {status.atProvider.state = "deployed"}
        }
    }
}

_by_res = lambda items, _res: str {
    _hit = [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _res]
    _hit[0] if _hit else Undefined
}

_sync = {url = "https://github.com/acme/fleet", path = "./clusters/demo"}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = _render({}, {})
    assert len(items) == 3, "ProviderConfig + flux2 + crossplane by default"
    assert items[0].kind == "ProviderConfig" and items[0].apiVersion == "helm.m.crossplane.io/v1beta1", "wrong provider config GVK"
    assert _by_res(items, "flux2").kind == "Release", "flux installed as a helm Release"
    assert _by_res(items, "crossplane").kind == "Release", "crossplane installed as a helm Release"
    assert _by_res(items, "flux2-sync") == Undefined, "no sync entrypoint unless asked for"
}

# ---- render: provider config ------------------------------------------------
test_provider_config = lambda {
    pc = _render({}, {})[0]
    assert pc.metadata.name == "demo", "provider config named after the XR"
    assert pc.metadata.annotations["krm.kcl.dev/ready"] == "True", "a ProviderConfig has no Ready condition and must be declared ready"
    assert pc.spec.credentials.source == "Secret", "kubeconfig comes from a Secret"
    ref = pc.spec.credentials.secretRef
    assert ref.namespace == "team-a" and ref.name == "demo-kubeconfig" and ref.key == "kubeconfig", "secret ref pinned to the XR namespace, the spec'd name and the shared kubeconfig key"
}

test_releases_bind_own_provider_config = lambda {
    items = _render({}, {})
    assert all _r in items[1::] {
        _r.spec.providerConfigRef.kind == "ProviderConfig" and _r.spec.providerConfigRef.name == "demo"
    }, "every Release must reach the adopted cluster through the XR's own ProviderConfig"
}

# ---- render: releases -------------------------------------------------------
test_flux_release = lambda {
    fp = _by_res(_render({}, {}), "flux2").spec.forProvider
    assert fp.namespace == "flux-system", "flux lives in flux-system"
    assert fp.chart.name == "flux2" and fp.chart.repository == cluster.flux_chart_repository and fp.chart.version == cluster.flux_chart_version, "pinned flux2 chart"
    assert fp.wait == True and fp.waitTimeout == "10m", "the Release must report ready only once the chart is up"
}

test_crossplane_release = lambda {
    fp = _by_res(_render({}, {}), "crossplane").spec.forProvider
    assert fp.namespace == "crossplane-system", "crossplane lives in crossplane-system"
    assert fp.chart.name == "crossplane" and fp.chart.repository == cluster.crossplane_chart_repository and fp.chart.version == cluster.crossplane_chart_version, "pinned crossplane chart"
}

test_release_names = lambda {
    items = _render({}, {})
    assert _by_res(items, "flux2").metadata.annotations["crossplane.io/external-name"] == "flux2", "helm release name pinned"
    assert _by_res(items, "crossplane").metadata.annotations["crossplane.io/external-name"] == "crossplane", "helm release name pinned"
}

test_version_override = lambda {
    items = _render({
        bootstrap = {flux.version = "2.20.0", crossplane.version = "2.4.0"}
    }, {})
    assert _by_res(items, "flux2").spec.forProvider.chart.version == "2.20.0", "flux chart version overridable"
    assert _by_res(items, "crossplane").spec.forProvider.chart.version == "2.4.0", "crossplane chart version overridable"
}

test_opt_out = lambda {
    no_flux = _render({bootstrap.flux.enabled = False}, {})
    assert _by_res(no_flux, "flux2") == Undefined and _by_res(no_flux, "crossplane") != Undefined, "flux can be left out"
    no_xp = _render({bootstrap.crossplane.enabled = False}, {})
    assert _by_res(no_xp, "crossplane") == Undefined and _by_res(no_xp, "flux2") != Undefined, "crossplane can be left out"
    bare = _render({
        bootstrap = {flux.enabled = False, crossplane.enabled = False}
    }, {})
    assert len(bare) == 1 and bare[0].kind == "ProviderConfig", "adopting alone installs nothing"
}

# ---- render: sync entrypoint ------------------------------------------------
test_sync_waits_for_flux = lambda {
    before = _render({bootstrap.sync = _sync}, {})
    assert _by_res(before, "flux2-sync") == Undefined, "the sync chart needs Flux CRDs: not rendered before flux2 is deployed"
    after = _render({bootstrap.sync = _sync}, _deployed("flux2"))
    assert _by_res(after, "flux2-sync") != Undefined, "rendered once flux2 is observed deployed"
}

test_sync_release = lambda {
    fp = _by_res(_render({bootstrap.sync = _sync}, _deployed("flux2")), "flux2-sync").spec.forProvider
    assert fp.namespace == "flux-system", "entrypoint lives next to flux"
    assert fp.chart.name == "flux2-sync" and fp.chart.repository == cluster.flux_chart_repository and fp.chart.version == cluster.flux_sync_chart_version, "pinned flux2-sync chart"
    git = fp.values.gitRepository.spec
    assert git.url == "https://github.com/acme/fleet", "repo url carried"
    assert git.ref == {branch = "main"}, "branch defaults to main, not the chart's master"
    assert git.interval == "5m", "default source interval"
    assert not git?.secretRef, "public repo needs no secret"
    ks = fp.values.kustomization.spec
    assert ks.path == "./clusters/demo", "path carried"
    assert ks.prune == True and ks.wait == True, "the entrypoint prunes and waits for health"
}

test_sync_tag_and_secret = lambda {
    git = _by_res(_render({bootstrap.sync = _sync | {tag = "v1.2.0", secretRef = "fleet-auth", interval = "1m", branch = "ignored"}}, _deployed("flux2")), "flux2-sync").spec.forProvider.values.gitRepository.spec
    assert git.ref == {tag = "v1.2.0"}, "a tag wins over the branch"
    assert git.secretRef.name == "fleet-auth", "secretRef carried"
    assert git.interval == "1m", "interval carried"
}

test_sync_path_default = lambda {
    ks = _by_res(_render({
        bootstrap.sync = {url = "https://github.com/acme/fleet"}
    }, _deployed("flux2")), "flux2-sync").spec.forProvider.values.kustomization.spec
    assert ks.path == "./", "path defaults to the repo root"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = _render({deletionPolicy = "Orphan", bootstrap.sync = _sync}, _deployed("flux2"))
    assert all _i in _orphaned[1::] {
        _i.spec.managementPolicies == _orphan
    }, "Orphan must set the non-delete policies on every Release"
    _deleted = _render({}, {})[1].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = cluster.status(_build({}), {})
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "onprem", "provider must be onprem"
    assert dxr.status.kubeconfigSecret == "demo-kubeconfig", "the supplied secret is reported back"
    assert dxr.status.id == "dc1/demo", "id is site/name"
    assert dxr.status?.endpoint == Undefined and dxr.status?.version == Undefined, "nothing is read back from an adopted cluster"
}

test_status_ready = lambda {
    both = _deployed("flux2") | _deployed("crossplane")
    assert cluster.status(_build({}), both).status.ready == True, "ready once every default component is deployed"
    assert cluster.status(_build({}), _deployed("flux2")).status.ready == False, "crossplane still pending"
    assert cluster.status(_build({bootstrap.sync = _sync}), both).status.ready == False, "a requested sync entrypoint must be deployed too"
    assert cluster.status(_build({bootstrap.sync = _sync}), both | _deployed("flux2-sync")).status.ready == True, "ready with the sync entrypoint up"
    assert cluster.status(_build({bootstrap.crossplane.enabled = False}), _deployed("flux2")).status.ready == True, "opted-out components are not waited for"
}

test_status_nothing_requested = lambda {
    dxr = cluster.status(_build({
        bootstrap = {flux.enabled = False, crossplane.enabled = False}
    }), {})
    assert dxr.status.ready == True, "adopting alone is ready as soon as the kubeconfig is in place"
}
