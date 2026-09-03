# component (flux) — Crossplane Composition logic (function-kcl module).
# The only backend: no cloud account, no Crossplane provider, no managed
# resource. Typed against the generated Flux CRD schemas, it renders TWO
# namespaced objects directly — a source.toolkit.fluxcd.io source and the
# kustomize/helm object that applies it — and then lets the Flux controllers
# own the pull, the diff and the prune. Crossplane places composed namespaced
# resources in the XR's own namespace, so nothing here sets one.
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_o_c_i_repository as ocirepo
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_git_repository as gitrepo
import flux_source.models.v1.source_toolkit_fluxcd_io_v1_helm_repository as helmrepo
import flux_kustomize.models.v1.kustomize_toolkit_fluxcd_io_v1_kustomization as kustomization
import flux_helm.models.v2.helm_toolkit_fluxcd_io_v2_helm_release as helmrelease

# A Helm chart ships as ONE compressed layer that helm-controller loads as it
# is; the default `extract` operation would unpack it and leave nothing to
# load, so an OCIRepository feeding a HelmRelease must select and copy it.
helm_chart_media_type = "application/vnd.cncf.helm.chart.content.v1.tar+gzip"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides. Both flavours of
# absence count: an unset key reads as Undefined, but `?.` over a spec block
# that is itself absent (or empty) yields None.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# Emit a typed Flux object as the plain KRM dict function-kcl composes, under a
# stable composition-resource-name so Crossplane keeps matching the same
# composed resource across reconciles.
#
# The None-stripping is not cosmetic. Two of the generated schemas carry a
# translated CRD CEL rule that KCL cannot satisfy any other way — `has(chart)
# != has(chartRef)` on HelmRelease, and "serviceAccountName implies provider is
# azure or aws" on GitRepository. An attribute that was never assigned is
# Undefined, and `Undefined != None` holds in KCL, so those rules only pass
# when the unused branch is spelled out as None. A literal `chart: null` in the
# composed object would then be rejected by the API server, so the None that
# satisfied the schema is dropped here — after it has done its work.
_emit = lambda obj, res: str {
    {
        apiVersion = obj.apiVersion
        kind = obj.kind
        metadata = {
            name = obj.metadata.name
            annotations = {"krm.kcl.dev/composition-resource-name" = res}
        }
        spec = {k: v for k, v in obj.spec if v != None}
    }
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _src = _spec.source
    _del = _spec?.deliver or {}

    _src_kind = _src?.kind or "OCIRepository"
    _del_kind = _del?.kind or "Kustomization"
    _ref = _src?.ref or {}
    _secret = _src?.secretRef
    _insecure = _src?.insecure or False

    # Two independent clocks: source.interval is how fast a newly pushed
    # revision is NOTICED, spec.interval how often what was fetched is
    # RE-APPLIED (and drift corrected).
    _src_interval = _src?.interval or "1m"
    _interval = _spec?.interval or "5m"
    _timeout = _del?.timeout or "5m"
    _depends = _spec?.dependsOn or []

    # Rejected combinations. A failed assert surfaces as a fatal function
    # result, which is the only way to tell the user something is wrong — a
    # half-rendered pair would be applied and then fought over by Flux.
    assert _del_kind == "HelmRelease" or _src_kind != "HelmRepository", "spec.deliver.kind Kustomization cannot read a HelmRepository (kustomize-controller has no such sourceRef kind): set spec.deliver.kind to HelmRelease, or set spec.source.kind to OCIRepository or GitRepository"
    assert _del_kind != "HelmRelease" or _src_kind == "OCIRepository" or _del?.chart, "spec.deliver.chart is required for a HelmRelease fed by a ${_src_kind}: name the chart inside the source, or set spec.source.kind to OCIRepository to install the artifact itself as the chart"
    assert not _insecure or _src_kind == "OCIRepository", "spec.source.insecure only applies to an OCIRepository, not a ${_src_kind}: drop it, or set spec.source.kind to OCIRepository"

    # _emit is applied per branch, not once at the end: KCL pins a variable to
    # the type of its first assignment, so three different schemas can only
    # meet in one variable once each has become a plain dict.
    _source = Undefined
    if _src_kind == "OCIRepository":
        _source = _emit(ocirepo.OCIRepository {
            metadata.name = _name
            spec = {
                url = _src.url
                interval = _src_interval
                # Only the keys actually set are forwarded, so Flux applies its
                # own precedence (digest > semver > tag) instead of resolving a
                # tag this module invented. An OCI registry has no branches.
                if _ref?.tag or _ref?.semver or _ref?.digest:
                    ref = {
                        if _ref?.tag:
                            tag = _ref.tag
                        if _ref?.semver:
                            semver = _ref.semver
                        if _ref?.digest:
                            digest = _ref.digest
                    }
                if _insecure:
                    insecure = True
                if _secret:
                    secretRef.name = _secret
                if _del_kind == "HelmRelease":
                    layerSelector = {mediaType = helm_chart_media_type, operation = "copy"}
            }
        }, "source")
    elif _src_kind == "GitRepository":
        _source = _emit(gitrepo.GitRepository {
            metadata.name = _name
            spec = {
                url = _src.url
                interval = _src_interval
                # See _emit: this None is what makes the generated
                # serviceAccountName rule satisfiable, and _emit drops it.
                serviceAccountName = None
                if _ref?.branch or _ref?.tag or _ref?.semver:
                    ref = {
                        if _ref?.branch:
                            branch = _ref.branch
                        if _ref?.tag:
                            tag = _ref.tag
                        if _ref?.semver:
                            semver = _ref.semver
                    }
                if _secret:
                    secretRef.name = _secret
            }
        }, "source")
    else:
        _source = _emit(helmrepo.HelmRepository {
            metadata.name = _name
            spec = {
                url = _src.url
                interval = _src_interval
                # The same kind serves classic index.yaml repositories and OCI
                # registries; only the url says which, and the controller needs
                # to be told explicitly.
                if _src.url.startswith("oci://"):
                    $type = "oci"
                if _secret:
                    secretRef.name = _secret
            }
        }, "source")
    _delivery = Undefined
    if _del_kind == "Kustomization":
        _delivery = _emit(kustomization.Kustomization {
            metadata.name = _name
            spec = {
                # Both objects are named after the XR, which is what lets a
                # sibling Component depend on this one by its XR name.
                sourceRef = {kind = _src_kind, name = _name}
                path = _del?.path or "./"
                prune = _flag(_del?.prune, True)
                wait = _flag(_del?.wait, True)
                timeout = _timeout
                interval = _interval
                if _del?.targetNamespace:
                    targetNamespace = _del.targetNamespace
                if _spec?.serviceAccountName:
                    serviceAccountName = _spec.serviceAccountName
                if _spec?.suspend:
                    suspend = True
                if _depends:
                    dependsOn = [{name = n} for n in _depends]
            }
        }, "delivery")
    else:
        _delivery = _emit(helmrelease.HelmRelease {
            metadata.name = _name
            spec = {
                interval = _interval
                timeout = _timeout
                if _src_kind == "OCIRepository":
                    # The artifact IS the chart, so there is no chart name to
                    # look up and no HelmChart object in between.
                    chartRef = {kind = "OCIRepository", name = _name}
                    chart = None
                else:
                    chart.spec = {
                        chart = _del.chart
                        if _del?.version:
                            version = _del.version
                        sourceRef = {kind = _src_kind, name = _name}
                    }
                    chartRef = None
                if _del?.values:
                    values = _del.values
                if _del?.targetNamespace:
                    targetNamespace = _del.targetNamespace
                if _spec?.serviceAccountName:
                    serviceAccountName = _spec.serviceAccountName
                if _spec?.suspend:
                    suspend = True
                if _depends:
                    dependsOn = [{name = n} for n in _depends]
                # A component that failed to install because its dependency was
                # not up yet should retry, not stay wedged until someone looks.
                install.remediation.retries = 3
                upgrade.remediation.retries = 3
            }
        }, "delivery")
    [_source, _delivery]
}

# Flux reports readiness the same way on every kind: a Ready condition in
# status.conditions. Observed state is absent on the first reconcile, so every
# read is optional — a missing object reads as "not ready", never as an error.
_ready_condition = lambda obj {
    _hit = [c for c in (obj?.status?.conditions or []) if c?.type == "Ready"]
    _hit[0] if _hit else Undefined
}

_is_ready = lambda obj -> bool {
    (_ready_condition(obj)?.status or "") == "True"
}

_condition_message = lambda obj -> str {
    _ready_condition(obj)?.message or ""
}

# Build the desired composite carrying observed Flux state back to the XR.
# ocds[<name>].Resource is the composed object itself — a plain Kubernetes
# object, with no atProvider layer, since these are not managed resources.
status = lambda oxr, ocds {
    _observed = ocds or {}
    _src_obj = _observed["source"]?.Resource if "source" in _observed else Undefined
    _del_obj = _observed["delivery"]?.Resource if "delivery" in _observed else Undefined

    _src_ready = _is_ready(_src_obj)
    _del_ready = _is_ready(_del_obj)

    # What the cluster COULD have vs what it DOES have; a lag between the two
    # means delivery is still catching up with a revision already fetched.
    _del_kind = oxr.spec?.deliver?.kind or "Kustomization"
    _applied = ""
    if _del_kind == "Kustomization":
        _applied = _del_obj?.status?.lastAppliedRevision or ""
    else:
        _history = _del_obj?.status?.history or []
        if _history:
            _applied = _history[0]?.chartVersion or ""

    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "Component"
        metadata.name = oxr.metadata.name
        status = {
            ready = _src_ready and _del_ready
            sourceReady = _src_ready
            deliveryReady = _del_ready
            sourceRevision = _src_obj?.status?.artifact?.revision or ""
            appliedRevision = _applied
            # Whichever half is stuck explains why, the source first: a
            # delivery failure is usually downstream of a fetch that failed.
            message = "" if _src_ready and _del_ready else (_condition_message(_src_obj) if not _src_ready else _condition_message(_del_obj))
        }
    }
}
