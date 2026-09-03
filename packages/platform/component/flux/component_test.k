import .component

_anno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# NOTE: KCL normalizes the leading underscore, so a helper here shadows ANY
# lambda parameter of the same normalized name over in component.k — `_oxr`
# would shadow render()'s `oxr`, `_obj` would shadow _emit()'s and
# _is_ready()'s `obj`, `_res` would shadow _emit()'s `res`, and the failure
# surfaces inside component.k rather than here. Hence `_xr`, `_pick`,
# `_flux_observed` and friends.
_xr = lambda _sp {
    {apiVersion = "platform.example.org/v1alpha1", kind = "Component", metadata.name = "demo", spec = _sp}
}

# Pick a composed object out of a render() by its composition-resource-name.
_pick = lambda _items, _wanted: str {
    [i for i in _items if i.metadata.annotations[_anno] == _wanted][0]
}

# The example's source: an OCI artifact on a plain-HTTP registry.
_oci_source = {
    kind = "OCIRepository"
    url = "oci://172.18.0.100:80/components/demo"
    ref = {tag = "v1"}
    insecure = True
    interval = "1m"
}

# ---- render: OCI artifact -> Kustomization ----------------------------------

# The default shape: exactly two objects, both named after the XR, both left
# unnamespaced so Crossplane puts them in the XR's namespace.
test_oci_kustomization = lambda {
    _got = component.render(_xr({source = _oci_source, deliver = {kind = "Kustomization", targetNamespace = "default"}}))
    assert len(_got) == 2, "a Component must compose exactly two Flux objects"
    assert [i.metadata.annotations[_anno] for i in _got] == ["source", "delivery"], "wrong composition-resource-names"

    _src = _pick(_got, "source")
    _del = _pick(_got, "delivery")
    assert _src.apiVersion == "source.toolkit.fluxcd.io/v1", "wrong source apiVersion"
    assert _src.kind == "OCIRepository", "wrong source kind"
    assert _del.apiVersion == "kustomize.toolkit.fluxcd.io/v1", "wrong delivery apiVersion"
    assert _del.kind == "Kustomization", "wrong delivery kind"
    assert _src.metadata.name == "demo" and _del.metadata.name == "demo", "both objects must be named after the XR"
    assert _src.metadata?.namespace == Undefined and _del.metadata?.namespace == Undefined, "composed objects must not pin a namespace"

    assert _src.spec.url == "oci://172.18.0.100:80/components/demo", "source url must be carried"
    assert _src.spec.interval == "1m", "source interval must be carried"
    assert _src.spec.ref.tag == "v1", "ref.tag must be carried"
    # Only the keys actually set are forwarded, so Flux keeps its own precedence.
    assert _src.spec.ref?.semver == Undefined, "no semver unless asked for"
    assert _src.spec.ref?.digest == Undefined, "no digest unless asked for"
    assert _src.spec.insecure == True, "insecure must be carried for a plain-HTTP registry"
    # A Kustomization consumes the extracted artifact, not a chart layer.
    assert _src.spec?.layerSelector == Undefined, "no layerSelector unless the delivery is a HelmRelease"

    assert _del.spec.sourceRef.kind == "OCIRepository", "sourceRef must name the source's kind"
    assert _del.spec.sourceRef.name == "demo", "sourceRef must name the source object"
    assert _del.spec.targetNamespace == "default", "targetNamespace must be forwarded"
    assert _del.spec.path == "./", "path must default to ./"
    assert _del.spec.prune == True, "prune must default on"
    assert _del.spec.wait == True, "wait must default on"
    assert _del.spec.timeout == "5m", "timeout must default to 5m"
    # The delivery reconcile interval is spec.interval, NOT source.interval.
    assert _del.spec.interval == "5m", "delivery interval must come from spec.interval"
}

# An explicit false must survive: `or True` would have swallowed it.
test_prune_and_wait_off = lambda {
    _del = _pick(component.render(_xr({
        source = _oci_source
        deliver = {kind = "Kustomization", prune = False, wait = False, path = "apps/demo", timeout = "30s"}
        interval = "2m"
    })), "delivery")
    assert _del.spec.prune == False, "prune=false must be forwarded"
    assert _del.spec.wait == False, "wait=false must be forwarded"
    assert _del.spec.path == "apps/demo", "path must be carried"
    assert _del.spec.timeout == "30s", "timeout must be carried"
    assert _del.spec.interval == "2m", "spec.interval must be carried"
}

# ---- render: OCI chart -> HelmRelease ---------------------------------------

# The artifact IS the chart, so the source has to copy the chart layer whole
# and the release reads it through chartRef instead of a chart name.
test_oci_helmrelease = lambda {
    _got = component.render(_xr({
        source = _oci_source
        deliver = {kind = "HelmRelease", targetNamespace = "default", values = {replicaCount = 1}}
    }))
    _src = _pick(_got, "source")
    _del = _pick(_got, "delivery")

    assert _src.spec.layerSelector.mediaType == "application/vnd.cncf.helm.chart.content.v1.tar+gzip", "the chart layer must be selected by media type"
    assert _src.spec.layerSelector.operation == "copy", "the chart layer must be copied, not extracted"

    assert _del.apiVersion == "helm.toolkit.fluxcd.io/v2", "wrong delivery apiVersion"
    assert _del.kind == "HelmRelease", "wrong delivery kind"
    assert _del.spec.chartRef.kind == "OCIRepository", "chartRef must point at the composed OCIRepository"
    assert _del.spec.chartRef.name == "demo", "chartRef must name the source object"

    # Flux rejects a HelmRelease carrying both; the None that satisfies the
    # generated schema's rule must not reach the composed object.
    assert _del.spec?.chart == Undefined, "an OCIRepository-backed release must carry no chart block"
    assert _del.spec.values == {replicaCount = 1}, "values must pass through verbatim"
    assert _del.spec.interval == "5m", "release interval must come from spec.interval"
    assert _del.spec.timeout == "5m", "timeout must default to 5m"
    assert _del.spec.install.remediation.retries == 3, "a failed install must be retried"
    assert _del.spec.upgrade.remediation.retries == 3, "a failed upgrade must be retried"
}

# ---- render: Helm repository -> HelmRelease ---------------------------------

# A named chart out of a repository index: chartRef cannot express that, so the
# release templates a HelmChart through chart.spec instead.
test_helmrepository_helmrelease = lambda {
    _got = component.render(_xr({
        source = {kind = "HelmRepository", url = "oci://ghcr.io/stefanprodan/charts", interval = "10m"}
        deliver = {kind = "HelmRelease", chart = "podinfo", version = ">=6.0.0 <7.0.0"}
    }))
    _src = _pick(_got, "source")
    _del = _pick(_got, "delivery")

    assert _src.kind == "HelmRepository", "wrong source kind"
    assert _src.spec.interval == "10m", "source interval must be carried"

    # One kind serves both classic and OCI Helm repositories; only the url says
    # which, and the controller has to be told.
    assert _src.spec["type"] == "oci", "an oci:// Helm repository must be typed oci"
    assert _src.spec?.layerSelector == Undefined, "a HelmRepository has no layers to select"

    assert _del.spec.chart.spec.chart == "podinfo", "chart name must be carried"
    assert _del.spec.chart.spec.version == ">=6.0.0 <7.0.0", "chart version must be carried"
    assert _del.spec.chart.spec.sourceRef.kind == "HelmRepository", "chart.spec.sourceRef must name the source's kind"
    assert _del.spec.chart.spec.sourceRef.name == "demo", "chart.spec.sourceRef must name the source object"
    assert _del.spec?.chartRef == Undefined, "a repository-backed release must carry no chartRef"
}

# A classic index.yaml repository must NOT be typed oci.
test_helmrepository_https = lambda {
    _src = _pick(component.render(_xr({
        source = {kind = "HelmRepository", url = "https://charts.example.com"}
        deliver = {kind = "HelmRelease", chart = "podinfo"}
    })), "source")
    assert _src.spec?.type == Undefined, "an https Helm repository keeps the default type"
    # version is optional; the chart's own default (latest) applies.
    assert _src.spec.interval == "1m", "source interval must default to 1m"
}

# ---- render: Git source ------------------------------------------------------

# Branches only exist here, and the None that satisfies the generated
# serviceAccountName rule must not reach the composed object.
test_git_kustomization = lambda {
    _got = component.render(_xr({
        source = {kind = "GitRepository", url = "https://github.com/example/repo", ref = {branch = "main"}, secretRef = "git-auth"}
        deliver = {kind = "Kustomization", path = "clusters/dev"}
    }))
    _src = _pick(_got, "source")
    _del = _pick(_got, "delivery")
    assert _src.kind == "GitRepository", "wrong source kind"
    assert _src.spec.ref.branch == "main", "ref.branch must be carried"
    assert _src.spec.secretRef.name == "git-auth", "secretRef must be carried as an object name"
    assert _src.spec?.serviceAccountName == Undefined, "no null serviceAccountName may reach the API server"
    assert _del.spec.sourceRef.kind == "GitRepository", "sourceRef must name the source's kind"
}

# ---- render: ordering, suspension and impersonation -------------------------
test_ordering_forwarded = lambda {
    _spec = {
        source = _oci_source
        deliver = {kind = "Kustomization"}
        dependsOn = ["infra", "certs"]
        suspend = True
        serviceAccountName = "demo-applier"
    }
    _del = _pick(component.render(_xr(_spec)), "delivery")

    # The entries are typed DependencyReferences, so compare what they carry:
    # the sibling XR names, in the order they were declared.
    assert [d.name for d in _del.spec.dependsOn] == ["infra", "certs"], "dependsOn must become Flux dependency references, in order"
    assert _del.spec.suspend == True, "suspend must be forwarded"
    assert _del.spec.serviceAccountName == "demo-applier", "serviceAccountName must be forwarded"

    # The same three on the HelmRelease branch.
    _rel = _pick(component.render(_xr(_spec | {
        deliver = {kind = "HelmRelease"}
    })), "delivery")
    assert [d.name for d in _rel.spec.dependsOn] == ["infra", "certs"], "dependsOn must be forwarded to a HelmRelease too"
    assert _rel.spec.suspend == True, "suspend must be forwarded to a HelmRelease too"
    assert _rel.spec.serviceAccountName == "demo-applier", "serviceAccountName must be forwarded to a HelmRelease too"
}

# Unset knobs stay unset, so each Flux controller keeps its own default and an
# empty dependsOn never blocks the first reconcile.
test_ordering_omitted = lambda {
    _del = _pick(component.render(_xr({source = _oci_source})), "delivery")
    assert _del.spec?.dependsOn == Undefined, "no dependsOn unless asked for"
    assert _del.spec?.suspend == Undefined, "no suspend unless asked for"
    assert _del.spec?.serviceAccountName == Undefined, "no serviceAccountName unless asked for"
    assert _del.spec?.targetNamespace == Undefined, "no targetNamespace unless asked for"

    _src = _pick(component.render(_xr({
        source = {kind = "OCIRepository", url = "oci://reg/demo"}
    })), "source")
    assert _src.spec?.ref == Undefined, "no ref at all when none of tag/semver/digest is set"
    assert _src.spec?.insecure == Undefined, "no insecure unless asked for"
    assert _src.spec?.secretRef == Undefined, "no secretRef unless asked for"
}

# ---- status ------------------------------------------------------------------
# Shape as function-kcl hands it over: ocds[<resource-name>].Resource is the
# composed Flux object itself. There is no atProvider layer — that belongs to
# managed resources, and these are not managed resources.
_ready_conditions = lambda _cond_status: str, _cond_msg: str {
    [{"type" = "Reconciling", status = "False", message = "irrelevant"}, {"type" = "Ready", status = _cond_status, message = _cond_msg}]
}

_flux_observed = lambda _src_obj, _del_obj {
    {source = {Resource = _src_obj}, delivery = {Resource = _del_obj}}
}

_fetched = {
    status = {
        conditions = _ready_conditions("True", "stored artifact for digest 'v1@sha256:abc'")
        artifact = {revision = "v1@sha256:abc"}
    }
}

_applied = {
    status = {
        conditions = _ready_conditions("True", "Applied revision: v1@sha256:abc")
        lastAppliedRevision = "v1@sha256:abc"
    }
}

test_status_ready = lambda {
    _out = component.status(_xr({source = _oci_source}), _flux_observed(_fetched, _applied))
    assert _out.apiVersion == "platform.example.org/v1alpha1", "the desired composite must keep the XR's apiVersion"
    assert _out.kind == "Component", "the desired composite must keep the XR's kind"
    assert _out.metadata.name == "demo", "the desired composite must keep the XR's name"

    _st = _out.status
    assert _st.ready == True, "both halves ready means the component is ready"
    assert _st.sourceReady == True, "the source's Ready condition must be reported"
    assert _st.deliveryReady == True, "the delivery's Ready condition must be reported"
    assert _st.sourceRevision == "v1@sha256:abc", "the fetched revision must be copied"
    assert _st.appliedRevision == "v1@sha256:abc", "the applied revision must be copied"
    assert _st.message == "", "a ready component has nothing to explain"
}

# A fetch that failed leaves nothing to apply, so the source's message is the
# one worth surfacing even though the delivery is unhealthy too.
test_status_source_not_ready = lambda {
    _stuck = {
        status = {conditions = _ready_conditions("False", "failed to pull artifact: unauthorized")}
    }
    _st = component.status(_xr({source = _oci_source}), _flux_observed(_stuck, _applied)).status
    assert _st.ready == False, "an unready source must keep the component unready"
    assert _st.sourceReady == False, "the failed source must be reported"
    assert _st.deliveryReady == True, "the delivery's own condition must still be reported"
    assert _st.sourceRevision == "", "a source with no artifact has no revision"
    assert _st.message == "failed to pull artifact: unauthorized", "the source's Ready message must propagate"
}

test_status_delivery_not_ready = lambda {
    _stuck = {
        status = {
            conditions = _ready_conditions("False", "Kustomization apply failed: namespace not found")
            lastAppliedRevision = "v0@sha256:old"
        }
    }
    _st = component.status(_xr({source = _oci_source}), _flux_observed(_fetched, _stuck)).status
    assert _st.ready == False, "an unready delivery must keep the component unready"
    assert _st.sourceReady == True, "the healthy source must still be reported"
    assert _st.deliveryReady == False, "the failed delivery must be reported"
    # Fetched but not applied: the lag between the two is the diagnosis.
    assert _st.sourceRevision == "v1@sha256:abc", "the fetched revision must be copied"
    assert _st.appliedRevision == "v0@sha256:old", "the last applied revision must be copied"
    assert _st.message == "Kustomization apply failed: namespace not found", "the delivery's Ready message must propagate"
}

# A HelmRelease has no lastAppliedRevision; its newest history entry carries
# the chart version actually installed.
test_status_helmrelease_revision = lambda {
    _released = {
        status = {
            conditions = _ready_conditions("True", "Helm install succeeded")
            history = [{chartVersion = "6.9.0"}, {chartVersion = "6.8.0"}]
        }
    }
    _st = component.status(_xr({source = _oci_source, deliver = {kind = "HelmRelease"}}), _flux_observed(_fetched, _released)).status
    assert _st.ready == True, "a released chart means the component is ready"
    assert _st.appliedRevision == "6.9.0", "the newest history entry's chart version must be reported"
}

# First reconcile: nothing has been observed yet, which must read as "not
# ready" rather than crash on the missing state.
test_status_unobserved = lambda {
    _st = component.status(_xr({source = _oci_source}), {}).status
    assert _st.ready == False, "an unobserved component is not ready"
    assert _st.sourceReady == False, "an unobserved source is not ready"
    assert _st.deliveryReady == False, "an unobserved delivery is not ready"
    assert _st.sourceRevision == "", "no revision before the source reports"
    assert _st.appliedRevision == "", "no applied revision before the delivery reports"
    assert _st.message == "", "no message before either half reports"
}

# Half-observed is the normal second reconcile: the source exists, the delivery
# has not been created yet.
test_status_half_observed = lambda {
    _st = component.status(_xr({source = _oci_source}), {
        source = {Resource = _fetched}
    }).status
    assert _st.sourceReady == True, "the observed source must be reported"
    assert _st.deliveryReady == False, "a delivery that does not exist yet is not ready"
    assert _st.ready == False, "one half is not enough"
    assert _st.sourceRevision == "v1@sha256:abc", "the fetched revision must be copied"
    assert _st.appliedRevision == "", "nothing has been applied yet"
    assert _st.message == "", "an absent delivery has no message to report"
}
