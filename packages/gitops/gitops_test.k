# Tests for the gitops package: what the loop renders, and the one switch that
# repoints Flux at the forge it just installed.
# Run: kcl test
import yaml

_kinds = lambda items: [any] -> [str] {
    [m.kind for m in items]
}
_of = lambda items: [any], kind: str -> [any] {
    [m for m in items if m.kind == kind]
}
_one = lambda items: [any], kind: str -> any {
    _of(items, kind)[0]
}

_base = """\
tenant:
  namespace: platform
source:
  url: https://github.com/yurikrupnik-org/gitops
  path: ./clusters/dev
  secretRef: gitops-auth
  repository: gitops
forge:
  hostname: git.yurikrupnik.com
  storageGb: 20
repositories:
  - name: gitops
    owner: yurikrupnik-org
    description: cluster state
  - name: kcl-packages
    owner: yurikrupnik-org
"""

_build = lambda extra: str -> Gitops {
    Gitops {**yaml.decode(_base + extra)}
}

# ── Shape and order ──────────────────────────────────────────────────────────
test_render_order = lambda {
    out = render(_build(""))
    assert _kinds(out) == [
        "Namespace"
        "Entitlement"
        "Forge"
        "Repository"
        "Repository"
        "GitRepository"
        "Kustomization"
    ], "the grant must precede the XRs that read it, and the Flux objects come last: ${_kinds(out)}"
    assert all_true([o.metadata.labels["app.kubernetes.io/part-of"] == "gitops" for o in out]), "every object carries the part-of label"
}

test_namespaces = lambda {
    out = render(_build(""))
    assert _one(out, "Entitlement").metadata?.namespace == Undefined, "the Entitlement is cluster-scoped"
    assert _one(out, "Entitlement").metadata.name == "platform", "it is keyed by the tenant namespace — that is the join key the Compositions look it up by"
    assert _one(out, "Forge").metadata.namespace == "platform", "the forge lives in the tenant namespace"
    assert all_true([r.metadata.namespace == "platform" for r in _of(out, "Repository")]), "so do its repositories"
    assert _one(out, "GitRepository").metadata.namespace == "flux-system", "the Flux objects live where Flux runs"
    assert _one(out, "Kustomization").metadata.namespace == "flux-system"
}

test_opt_out = lambda {
    out = render(_build("""\
tenant:
  namespace: platform
  createNamespace: false
  manageEntitlement: false
"""))
    assert "Namespace" not in _kinds(out), "createNamespace false emits no Namespace"
    assert "Entitlement" not in _kinds(out), "manageEntitlement false leaves the record to whoever owns billing"
    assert _kinds(out)[0] == "Forge", "what is left still starts with the forge"
}

# ── Entitlement ──────────────────────────────────────────────────────────────
test_entitlement = lambda {
    e = _one(render(_build("""\
tenant:
  namespace: platform
  plan: enterprise
  reference: sub_123
""")), "Entitlement")
    assert e.apiVersion == "platform.example.org/v1alpha1", "the Entitlement CRD is served under the platform group"
    assert e.spec.plan == "enterprise"
    assert e.spec.features == ["forgejo", "repository"], "both capabilities are granted by default"
    assert e.spec.quota == {storageGb = 50, repositories = 50}
    assert e.spec.reference == "sub_123"
}

test_entitlement_without_reference = lambda {
    e = _one(render(_build("")), "Entitlement")
    assert e.spec?.reference == Undefined, "an unset billing pointer is absent, not empty"
}

# ── Forge ────────────────────────────────────────────────────────────────────
test_forge_defaults = lambda {
    f = _one(render(_build("")), "Forge")
    assert f.apiVersion == "cloud.example.org/v1alpha1" and f.kind == "Forge"
    assert f.metadata.name == "git", "the XR name is the helm release name and the Service prefix"
    assert f.spec.hostname == "git.yurikrupnik.com"
    assert f.spec.storageGb == 20
    assert f.spec.database == {mode = "sqlite"}, "sqlite needs nothing else"
    assert f.spec.chartVersion == "17.1.5", "the chart is pinned so a re-render never upgrades a running forge"
    assert f.spec.deletionPolicy == "Delete"
    assert f.spec?.values == Undefined, "no raw chart values unless asked for"
    assert f.spec?.adminSecret == Undefined, "no adminSecret means the chart keeps its generated admin"
}

test_forge_postgres_and_overrides = lambda {
    f = _one(render(_build("""\
forge:
  hostname: git.yurikrupnik.com
  adminSecret: git-admin
  imageTag: 15.0.7
  deletionPolicy: Orphan
  database:
    mode: postgres
    host: pg-rw.platform.svc:5432
    name: forgejo
    user: forgejo
    passwordSecret:
      name: forge-db
      key: app-ini
  ingress:
    enabled: true
    className: nginx
    tlsSecretName: git-tls
  values:
    resources:
      requests:
        cpu: 100m
""")), "Forge")
    assert f.spec.database.host == "pg-rw.platform.svc:5432"
    assert f.spec.database.passwordSecret == {name = "forge-db", key = "app-ini"}, "the password itself never enters the Release"
    assert f.spec.ingress == {enabled = True, className = "nginx", tlsSecretName = "git-tls"}
    assert f.spec.adminSecret == "git-admin" and f.spec.imageTag == "15.0.7"
    assert f.spec.deletionPolicy == "Orphan"
    assert f.spec.values.resources.requests.cpu == "100m", "raw chart values pass through untouched"
}

# ── Repositories ─────────────────────────────────────────────────────────────
test_repositories = lambda {
    repos = _of(render(_build("")), "Repository")
    assert [r.metadata.name for r in repos] == ["gitops", "kcl-packages"], "one XR per entry, in values order"
    assert all_true([r.spec.forge == {baseUrl = "http://git-http.platform.svc:3000/api/v1", secretRef = "forge-token"} for r in repos]), "the API root is the Forge's own status.apiUrl, computed rather than copied by hand"
    assert repos[0].spec.owner == "yurikrupnik-org" and repos[0].spec.name == "gitops"
    assert repos[0].spec.description == "cluster state"
    assert repos[0].spec.private == True and repos[0].spec.defaultBranch == "main"
    assert repos[0].spec.autoInit == False, "seeded by a push: an initial commit would collide with the history"
    assert repos[0].spec.deletionPolicy == "Orphan", "a repository carries history no other object holds"
    assert repos[1].spec?.description == Undefined
}

test_repository_extras = lambda {
    r = _of(render(_build("""\
repositories:
  - name: gitops
    owner: yurikrupnik-org
    private: false
    autoInit: true
    license: Apache-2.0
    createOrganization: true
    organization:
      description: platform org
      visibility: limited
    webhook:
      url: https://ci.example.org/hook
      secretRef: hook-secret
      events: [push, pull_request]
""")), "Repository")[0]
    assert r.spec.license == "Apache-2.0" and r.spec.autoInit == True
    assert r.spec.createOrganization == True
    assert r.spec.organization == {fullName = "yurikrupnik-org", description = "platform org", visibility = "limited"}, "an unset fullName defaults to the owner"
    assert r.spec.webhook == {url = "https://ci.example.org/hook", secretRef = "hook-secret", events = ["push", "pull_request"], active = True}
}

test_no_repositories = lambda {
    out = render(_build("""\
repositories: []
source:
  url: https://github.com/yurikrupnik-org/gitops
  origin: github
"""))
    assert "Repository" not in _kinds(out), "a forge with no repositories is a valid render"
}

# ── Flux source, and the switch ──────────────────────────────────────────────
test_source_github = lambda {
    out = render(_build(""))
    gr = _one(out, "GitRepository")
    assert gr.apiVersion == "source.toolkit.fluxcd.io/v1"
    assert gr.spec.url == "https://github.com/yurikrupnik-org/gitops", "origin github follows source.url"
    assert gr.spec.ref.branch == "main"
    assert gr.spec.interval == "1m"
    assert gr.spec.secretRef.name == "gitops-auth"
    k = _one(out, "Kustomization")
    assert k.apiVersion == "kustomize.toolkit.fluxcd.io/v1"
    assert k.spec.sourceRef.kind == "GitRepository" and k.spec.sourceRef.name == "gitops", "the Kustomization reads the source rendered beside it"
    assert k.spec.path == "./clusters/dev"
    assert k.spec.prune == True and k.spec.wait == True
    assert k.spec.interval == "10m", "the source is polled faster than the whole tree is re-applied"
}

test_source_switch_to_forge = lambda {
    out = render(_build("""\
source:
  origin: forge
  url: https://github.com/yurikrupnik-org/gitops
  repository: gitops
  secretRef: forge-auth
"""))
    gr = _one(out, "GitRepository")
    assert gr.spec.url == "http://git-http.platform.svc:3000/yurikrupnik-org/gitops.git", "the loop closes: Flux now clones the forge's own copy, in-cluster"
    assert gr.spec.secretRef.name == "forge-auth", "the forge needs its own git credential, not the API token"
    assert _one(out, "Kustomization").spec.path == "./clusters/dev", "everything else about the delivery is unchanged by the switch"
    assert len(_of(out, "Repository")) == 2, "and the repositories it now reconciles from are still managed here"
}

test_public_source_needs_no_secret = lambda {
    gr = _one(render(_build("""\
source:
  url: https://github.com/yurikrupnik-org/gitops
""")), "GitRepository")
    assert gr.spec?.secretRef == Undefined, "a public repository needs no credential"
}

# ── Derived URLs ─────────────────────────────────────────────────────────────
test_urls = lambda {
    g = _build("")
    assert serviceHost(g) == "git-http.platform.svc:3000", "the forgejo chart's web Service is <release>-http on 3000"
    assert apiUrl(g) == "http://git-http.platform.svc:3000/api/v1"
    assert cloneUrl(g, g.repositories[1]) == "http://git-http.platform.svc:3000/yurikrupnik-org/kcl-packages.git"
    assert sourceUrl(g) == "https://github.com/yurikrupnik-org/gitops"
}
