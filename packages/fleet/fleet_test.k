# Tests for the fleet package: the two layers, the platform barrier, and the
# three engines' mapping onto Component.spec.
# Run: kcl test
import yaml
import file

_kinds = lambda items: [any] -> [str] {
    [m.kind for m in items]
}
_named = lambda items: [any], name: str -> any {
    [m for m in items if m.metadata.name == name][0]
}
_components = lambda items: [any] -> [any] {
    [m for m in items if m.kind == "Component"]
}

# A fleet with both layers and all three engines.
_fleetValues = """\
name: platform
platform:
  - name: crossplane
    engine: helm
    source: {url: "https://charts.crossplane.io/stable", interval: 1h}
    chart: crossplane
    version: 2.3.4
    targetNamespace: crossplane-system
  - name: platform-apis
    engine: crossplane
    source: {url: "oci://ghcr.io/example/platform-apis", tag: v1.4.0}
    path: ./apis
    dependsOn: [crossplane]
teams:
  - name: web
    namespace: web
    labels: {team: web}
    apps:
      - name: nginx
        engine: helm
        source: {url: "oci://registry-1.docker.io/bitnamicharts"}
        chart: nginx
        version: 21.1.24
        values: {replicaCount: 2}
      - name: web-api
        engine: kustomize
        source: {url: "https://github.com/example/web-api", branch: main, secretRef: web-api-git}
        path: ./deploy/overlays/dev
        dependsOn: [nginx]
        serviceAccount: web-deployer
  - name: data
    namespace: data
    createNamespace: false
    apps:
      - name: data-resources
        engine: crossplane
        source: {url: "oci://ghcr.io/example/data-resources", semver: ">=1.0.0 <2.0.0"}
"""

# ── The tree: namespaces first, then the platform layer, then the teams ──────
test_render_order_and_identity = lambda {
    out = render(Fleet {**yaml.decode(_fleetValues)})
    assert _kinds(out) == ["Namespace", "Component", "Component", "Component", "Component", "Component"], "one Namespace for the team that wants one, then platform, then team apps: ${_kinds(out)}"
    assert out[0].metadata.name == "web", "data sets createNamespace: false, so only web's Namespace is rendered"
    assert out[0].metadata.labels["team"] == "web", "team labels reach the Namespace"

    cs = _components(out)
    assert [c.metadata.name for c in cs] == ["crossplane", "platform-apis", "nginx", "web-api", "data-resources"], "platform layer before the teams, file order inside each"
    assert all_true([c.metadata.namespace == "flux-system" for c in cs]), "every Component lives in the fleet namespace: dependsOn only reaches siblings there"
    assert all_true([c.metadata.labels["app.kubernetes.io/part-of"] == "platform" for c in cs])
    assert [c.metadata.labels["platform.example.org/layer"] for c in cs] == ["platform", "platform", "application", "application", "application"], "the layer label is the phase selector for a split apply"
    assert _named(cs, "nginx").metadata.labels["platform.example.org/team"] == "web"
    assert "platform.example.org/team" not in _named(cs, "crossplane").metadata.labels, "a platform app belongs to no team"
    assert [c.metadata.labels["platform.example.org/engine"] for c in cs] == ["helm", "crossplane", "helm", "kustomize", "crossplane"]
}

# ── The barrier that makes this an app OF apps ───────────────────────────────
test_platform_barrier = lambda {
    cs = _components(render(Fleet {**yaml.decode(_fleetValues)}))
    assert _named(cs, "crossplane").spec?.dependsOn == Undefined, "the first platform app waits for nothing"
    assert _named(cs, "platform-apis").spec.dependsOn == ["crossplane"], "a platform app gets its own dependencies only — never the barrier"
    assert _named(cs, "nginx").spec.dependsOn == ["crossplane", "platform-apis"], "a team app waits for the whole platform layer"
    _webApiDeps = _named(cs, "web-api").spec.dependsOn
    assert _webApiDeps == ["nginx", "crossplane", "platform-apis"], "own dependencies first, then the barrier, no duplicates: ${_webApiDeps}"

    off = _components(render(Fleet {**yaml.decode(_fleetValues), waitForPlatform = False}))
    assert off[2].spec?.dependsOn == Undefined, "waitForPlatform: false drops the barrier fleet-wide"
    assert _named(off, "web-api").spec.dependsOn == ["nginx"], "own dependencies survive the barrier being off"

    # One app opting out, while its sibling in the same team still waits.
    _opt = yaml.decode(_fleetValues)
    _opt.teams[0].apps[0].waitForPlatform = False
    perApp = _components(render(Fleet {**_opt}))
    assert _named(perApp, "nginx").spec?.dependsOn == Undefined, "one app may opt out of the barrier"
    assert _named(perApp, "web-api").spec.dependsOn == ["nginx", "crossplane", "platform-apis"], "its siblings still wait"
}

# ── helm: a chart out of a Helm repository ───────────────────────────────────
test_engine_helm = lambda {
    cs = _components(render(Fleet {**yaml.decode(_fleetValues)}))
    nginx = _named(cs, "nginx")
    assert nginx.spec.source.kind == "HelmRepository", "a helm app indexes a Helm repository unless told otherwise"
    assert nginx.spec.source.url == "oci://registry-1.docker.io/bitnamicharts" and nginx.spec.source.interval == "1m"
    assert nginx.spec.deliver.kind == "HelmRelease"
    assert nginx.spec.deliver.chart == "nginx" and nginx.spec.deliver.version == "21.1.24"
    assert nginx.spec.deliver.values == {replicaCount = 2}
    assert nginx.spec.deliver.targetNamespace == "web", "a team app lands in its team's namespace"
    assert all_true([k not in nginx.spec.deliver for k in ["path", "prune", "wait"]]), "HelmRelease has no kustomize knobs: ${nginx.spec.deliver}"
    assert _named(cs, "crossplane").spec.deliver.targetNamespace == "crossplane-system", "targetNamespace overrides the team (and is the only namespace a platform app has)"

    # A chart that IS an OCI artifact: no `chart`, the tag pins it, and the
    # Composition delivers it by chartRef.
    art = _components(render(Fleet {**yaml.decode("""\
teams:
  - name: web
    namespace: web
    apps:
      - name: podinfo
        engine: helm
        source: {url: "oci://ghcr.io/stefanprodan/charts/podinfo", kind: OCIRepository, tag: 6.7.1}
""")}))[0]
    assert art.spec.source.kind == "OCIRepository" and art.spec.source.ref.tag == "6.7.1"
    assert art.spec.deliver.kind == "HelmRelease" and "chart" not in art.spec.deliver, "the artifact is the chart: nothing to name"
}

# ── kustomize / crossplane: manifests applied by kustomize-controller ────────
test_engine_kustomize_and_crossplane = lambda {
    cs = _components(render(Fleet {**yaml.decode(_fleetValues)}))
    api = _named(cs, "web-api")
    assert api.spec.source.kind == "GitRepository", "an https:// URL on a non-helm app is a clone, not an artifact"
    assert api.spec.source.ref.branch == "main" and api.spec.source.secretRef == "web-api-git"
    assert api.spec.deliver.kind == "Kustomization"
    assert api.spec.deliver.path == "./deploy/overlays/dev" and api.spec.deliver.prune == True and api.spec.deliver.wait == True
    assert api.spec.deliver.targetNamespace == "web"
    assert "values" not in api.spec.deliver, "a Kustomization has no values"
    assert api.spec.serviceAccountName == "web-deployer", "the impersonated identity is what bounds a team's blast radius"

    xrs = _named(cs, "data-resources")
    assert xrs.spec.source.kind == "OCIRepository" and xrs.spec.source.ref.semver == ">=1.0.0 <2.0.0"
    assert xrs.spec.deliver.kind == "Kustomization" and xrs.spec.deliver.path == "./", "crossplane content is YAML like any other; the engine label is what says it is XRs"
    assert xrs.spec.deliver.wait == True, "the XRs' readiness is what the Component reports"
    assert "serviceAccountName" not in xrs.spec, "unset optional fields are not emitted"
}

# ── The shipped example and its overlay ──────────────────────────────────────
test_example_valid = lambda {
    f = Fleet {**yaml.decode(file.read("examples/values.yaml"))}
    out = render(f)
    assert _kinds(out) == ["Namespace", "Namespace"] + ["Component"] * 7, "two teams, three platform apps, four team apps: ${_kinds(out)}"
    assert [a.name for a in f.platform] == ["crossplane", "platform-apis", "policy"]
    assert [t.name for t in f.teams] == ["web", "data"]
    assert all_true([len(c.spec.dependsOn) >= 3 for c in _components(out) if c.metadata.labels["platform.example.org/layer"] == "application"]), "every team app waits for all three platform apps"

    # The overlay replaces the teams list wholesale (Helm overlay semantics):
    # `_merge` is main.k's overlay merge, the same one `-D env=prod` applies.
    prod = yaml.decode(file.read("examples/values.prod.yaml"))
    merged = Fleet {**_merge(yaml.decode(file.read("examples/values.yaml")), prod)}
    assert merged.name == "platform-prod" and len(merged.teams) == 1, "prod runs the web team only"
    assert len(merged.platform) == 3, "the overlay leaves the platform layer alone"
    assert _named(_components(render(merged)), "web-api").spec.source.kind == "OCIRepository", "prod tracks a release artifact, not a branch"
}

# invalid inputs — a helm app whose source.kind is an explicit GitRepository, a
# chart name on a kustomize app, `values` on a Kustomization, a HelmRepository
# app with no `chart`, a `chart` alongside an OCI-artifact chart, a `branch` on
# an OCI source, a `digest` on a Git source, `insecure` on anything but an
# OCIRepository, a URL whose scheme contradicts the source kind, duplicate app
# names across teams, a dependsOn naming nothing, a platform app depending on a
# team app, and an empty team — are rejected by the schema `check` blocks (kcl
# test cannot catch an assert, so they are listed rather than executed).
#
# NOT rejected, and deliberately: a helm app pointed at an https:// URL that
# happens to be a Git host. An index URL and a clone URL are the same scheme —
# only Flux can tell them apart, and it does, by failing the fetch.
test_render_order_and_identity()
test_platform_barrier()
test_engine_helm()
test_engine_kustomize_and_crossplane()
test_example_valid()
