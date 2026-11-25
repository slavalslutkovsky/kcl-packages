# Tests for platform-addons: detection -> addons -> Flux / Argo CD objects.
# Run: kcl test ./...
import runtime
import .lib

_run = lambda cfg: {str:any}, detected: [{str:any}], previous: [str] -> lib.Plan {
    lib.plan(lib.Params {
        client = "client-test/test"
        config = cfg
        detected = detected
        previous = previous
    })
}
_row = lambda group: str, kind: str, providers: [str] -> {str:any} {
    {group = group, kind = kind, versions = ["v1"], count = 1, providers = providers}
}
_addon = lambda p: lib.Plan, name: str -> any {
    ([a for a in p.addons if a.name == name] + [None])[0]
}
_installed = lambda p: lib.Plan -> [str] {
    [a.name for a in p.addons if a.installed]
}
_obj = lambda p: lib.Plan, kind: str, name: str -> any {
    ([o for o in p.items if o.kind == kind and o.metadata.name == name] + [None])[0]
}

# ── Flux: a Kyverno policy installs the chart gitops runs ───────────────────
test_kyverno_flux = lambda {
    p = _run({cloud = "gcp"}, [_row("kyverno.io", "ClusterPolicy", [])], [])
    hr = _obj(p, "HelmRelease", "kyverno")
    assert hr.apiVersion == "helm.toolkit.fluxcd.io/v2"
    assert hr.metadata.namespace == "flux-system", "Flux objects live in config.namespace"
    assert hr.spec.chart.spec.version == "3.9.1", "gitops' pinned chart: ${hr.spec.chart.spec.version}"
    assert hr.spec.targetNamespace == "kyverno"
    assert hr.spec.install.createNamespace and hr.spec.install.crds == "CreateReplace"
    assert hr.spec.upgrade.crds == "CreateReplace" and hr.spec.upgrade.remediation.retries == 3
    assert hr.spec.values.admissionController.replicas == 3, "gitops' values are the default"
    repo = _obj(p, "HelmRepository", "kyverno")
    assert repo.spec.url == "https://kyverno.github.io/kyverno/" and "type" not in repo.spec
    assert all o in p.items { o.metadata.labels["platform.shluviza.com/addon"] == "kyverno" and o.metadata.labels["app.kubernetes.io/managed-by"] == "platform-addons" }
    k = _addon(p, "kyverno")
    assert k.installed and k.required and k.reasons == ["kyverno.io/ClusterPolicy"]
}

test_values_override = lambda {
    p = _run({cloud = "gcp", addons.kyverno = {version = "3.9.2", values.admissionController.replicas = 1}}, [_row("kyverno.io", "ClusterPolicy", [])], [])
    hr = _obj(p, "HelmRelease", "kyverno")
    assert hr.spec.chart.spec.version == "3.9.2"
    assert hr.spec.values.admissionController.replicas == 1, "config values win"
    assert hr.spec.values.reportsController.replicas == 2, "catalog defaults stay under them"
}

# ── XR provider selects the operator, not every one the API supports ────────
test_xcanary_flagger = lambda {
    p = _run({cloud = "gcp"}, [_row("platform.shluviza.com", "XCanary", ["flagger"])], [])
    names = _installed(p)
    assert "flagger" in names and "api-xcanary" in names and "crossplane" in names, "${names}"
    assert "argo-rollouts" not in names, "flagger was selected, not argo-rollouts"
    assert "platform.shluviza.com/XCanary provider=flagger" in _addon(p, "flagger").reasons
    assert "requires:flagger" in _addon(p, "istio").reasons, "flagger needs istio, as on mgmt"
    assert _obj(p, "Kustomization", "api-xcanary").spec.path == "./api/xcanary"
}

test_unknown_provider_warns = lambda {
    p = _run({cloud = "gcp"}, [_row("platform.shluviza.com", "XPolicy", ["opa"])], [])
    assert any w in p.warnings { "unknown provider \"opa\"" in w }, "${p.warnings}"
    assert "kyverno" not in _installed(p) and "gatekeeper" not in _installed(p)
}

test_xpostgres_cloudsql_off_gcp = lambda {
    p = _run({cloud = "aws"}, [_row("platform.shluviza.com", "XPostgres", ["cloudsql"])], [])
    assert "crossplane-gcp-sql" not in _installed(p)
    assert any w in p.warnings { "provider=cloudsql" in w and "crossplane-gcp-sql" in w }, "${p.warnings}"
}

test_xdatalake_families = lambda {
    p = _run({cloud = "azure"}, [_row("platform.shluviza.com", "XDataLake", [])], [])
    names = _installed(p)
    assert all f in ["storage", "managedidentity", "authorization"] { "crossplane-azure-${f}" in names }, "${names}"
    assert "crossplane-azure" in names and "crossplane-gcp-storage" not in names
}

# ── Sticky installs ──────────────────────────────────────────────────────────
test_sticky_previous = lambda {
    p = _run({cloud = "gcp"}, [], ["keda"])
    k = _addon(p, "keda")
    assert k.installed and not k.required and k.reasons == ["previous"]
    assert _obj(p, "HelmRelease", "keda") != None
    gone = _run({cloud = "gcp", addons.keda.remove = True}, [], ["keda"])
    assert not _addon(gone, "keda").installed, "remove: true drops it"
    assert not gone.items
}

# ── Main cloud only ──────────────────────────────────────────────────────────
test_other_cloud_family = lambda {
    p = _run({cloud = "gcp"}, [_row("s3.aws.m.upbound.io", "Bucket", [])], [])
    assert "crossplane-aws-s3" not in _installed(p) and not p.items
    assert any w in p.warnings { w.startswith("s3.aws.m.upbound.io/Bucket: crossplane-aws-s3") }, "${p.warnings}"
    assert not p.unmapped, "a gated family is a warning, not unmapped"
    extra = _run({cloud = "gcp", crossplane.extraClouds = ["aws"]}, [_row("s3.aws.m.upbound.io", "Bucket", [])], [])
    assert "crossplane-aws-s3" in _installed(extra)
}

test_forced_families = lambda {
    p = _run({cloud = "gcp", crossplane = {families = ["sql"], vars = {GCP_ADMIN_PROJECT = "x"}}}, [], [])
    assert _addon(p, "crossplane-gcp-sql").reasons == ["config"]
    sql = _obj(p, "Kustomization", "crossplane-gcp-sql")
    assert sql.spec.postBuild.substitute.GCP_ADMIN_PROJECT == "x"
    deps = [d.name for d in sql.spec.dependsOn]
    assert "crossplane-gcp-runtime" in deps and "crossplane-gcp-config" not in deps, "a family never waits on the ProviderConfig it enables: ${deps}"
}

# ── Argo CD ──────────────────────────────────────────────────────────────────
test_argo_sync_waves = lambda {
    p = _run({cloud = "gcp", delivery = "argo", crossplane.vars.GCP_ADMIN_PROJECT = "x"}, [_row("storage.gcp.m.upbound.io", "Bucket", [])], [])
    assert all o in p.items { o.kind == "Application" and o.metadata.namespace == "argocd" and o.spec.project == "default" }
    wave = lambda n: str -> str {
        _obj(p, "Application", n).metadata.annotations["argocd.argoproj.io/sync-wave"]
    }
    assert wave("crossplane") == "0" and wave("crossplane-functions") == "1"
    assert wave("crossplane-gcp-runtime") == "2" and wave("crossplane-gcp-storage") == "3", "depth follows requires"
    storage = _obj(p, "Application", "crossplane-gcp-storage")
    assert storage.spec.source.plugin.name == "flux-envsubst"
    assert storage.spec.source.plugin.env == [{name = "GCP_ADMIN_PROJECT", value = "x"}]
    assert storage.spec.source.path == "platform/crossplane/providers/gcp/storage"
    assert storage.spec.syncPolicy.syncOptions == ["CreateNamespace=true", "ServerSideApply=true"]
    core = _obj(p, "Application", "crossplane")
    assert core.spec.source.chart == "crossplane" and core.spec.source.targetRevision == "2.4.0"
    assert core.spec.destination.namespace == "crossplane-system"
}

# ── Unmapped ─────────────────────────────────────────────────────────────────
test_unmapped = lambda {
    p = lib.plan(lib.Params {
        client = "client-test/test"
        config.cloud = "gcp"
        detected = [_row("", "ConfigMap", []), _row("apps", "Deployment", []), _row("argoproj.io", "Application", []), _row("example.com", "Widget", []), _row("thirdparty.io", "Gadget", [])]
        provided = ["example.com"]
    })
    assert p.unmapped == ["thirdparty.io/Gadget"], "${p.unmapped}"
    assert not p.items
}

# ── Custom addons ────────────────────────────────────────────────────────────
test_custom_helm_depends_on = lambda {
    p = _run({cloud = "gcp", addons = {"my-tool" = {
        enabled = True
        namespace = "tools"
        helm = {repo = "oci://ghcr.io/example/charts", chart = "my-tool", version = "1.2.3"}
        values.replicas = 2
        dependsOn = ["cert-manager"]
    }}}, [], [])
    assert "cert-manager" in _installed(p) and "requires:my-tool" in _addon(p, "cert-manager").reasons
    hr = _obj(p, "HelmRelease", "my-tool")
    assert hr.spec.dependsOn == [{name = "cert-manager"}]
    assert hr.spec.targetNamespace == "tools" and hr.spec.values.replicas == 2
    assert _obj(p, "HelmRepository", "my-tool").spec.type == "oci"
    assert _addon(p, "my-tool").dependsOn == ["cert-manager"]
}

test_custom_oci_helm_argo = lambda {
    p = _run({cloud = "gcp", delivery = "argo", addons = {"my-tool" = {
        enabled = True
        helm = {repo = "oci://ghcr.io/example/charts", chart = "my-tool", version = "1.2.3"}
    }}}, [], [])
    app = _obj(p, "Application", "my-tool")
    assert app.spec.source.repoURL == "ghcr.io/example/charts", "Argo CD wants OCI Helm repos without the scheme"
    repo = _obj(p, "Secret", "repo-my-tool")
    assert repo.metadata.namespace == "argocd" and repo.metadata.labels["argocd.argoproj.io/secret-type"] == "repository"
    assert repo.stringData == {type = "helm", name = "my-tool", url = "ghcr.io/example/charts", enableOCI = "true"}
}

test_custom_kustomize_git = lambda {
    p = _run({cloud = "gcp", addons.app = {enabled = True, kustomize = {url = "https://github.com/org/repo.git", ref = "v1.0.0", path = "./deploy"}}}, [], [])
    assert _obj(p, "GitRepository", "app").spec.ref == {tag = "v1.0.0"}
    ks = _obj(p, "Kustomization", "app")
    assert ks.spec.sourceRef == {kind = "GitRepository", name = "app", namespace = "flux-system"} and ks.spec.prune and ks.spec.wait
}

# ── Catalog ──────────────────────────────────────────────────────────────────
test_catalog_targets = lambda {
    names = [a.name for a in lib.catalog]
    bad = [t for a in lib.catalog for _, ts in a.providers for t in ts if t not in names] + [t for a in lib.catalog for _, ts in a.cloudRequires for t in ts if t not in names]
    assert not bad, "provider/cloud targets outside the catalog: ${bad}"
    assert len(names) == len(lib.uniq(names)), "duplicate addon names"
}

# ── Validation ───────────────────────────────────────────────────────────────
# One runtime.catch per test: a caught check failure leaks into the next
# catch in the same test (see manager_test.k).
test_reject_custom_without_install = lambda {
    assert "exactly one of helm" in runtime.catch(lambda {
        _run({cloud = "gcp", addons.x = {enabled = True}}, [], [])
    })
}

test_reject_unknown_requires = lambda {
    assert "unknown requires" in runtime.catch(lambda {
        _run({cloud = "gcp", addons.x = {enabled = True, manifests = {url = "https://g/x", ref = "main"}, dependsOn = ["nope"]}}, [], [])
    })
}

test_reject_cycle = lambda {
    assert "requires cycle: a -> b -> a" in runtime.catch(lambda {
        _run({cloud = "gcp", addons = {
            a = {enabled = True, manifests = {url = "https://g/a", ref = "main"}, dependsOn = ["b"]}
            b = {manifests = {url = "https://g/b", ref = "main"}, dependsOn = ["a"]}
        }}, [], [])
    })
}

test_reject_values_file = lambda {
    assert "valuesFile must arrive resolved" in runtime.catch(lambda {
        _run({cloud = "gcp", addons.kyverno.valuesFile = {source = "s", path = "p"}}, [], [])
    })
}

test_reject_cloud = lambda {
    assert runtime.catch(lambda {
        _run({cloud = "mars"}, [], [])
    }) != ""
}

test_reject_delivery = lambda {
    assert runtime.catch(lambda {
        _run({cloud = "gcp", delivery = "jenkins"}, [], [])
    }) != ""
}

test_reject_addon_kinds = lambda {
    assert "items may only hold" in runtime.catch(lambda {
        lib.Plan {items = [{apiVersion = "pkg.crossplane.io/v1", kind = "Provider"}], addons = [], unmapped = [], warnings = []}
    })
}
