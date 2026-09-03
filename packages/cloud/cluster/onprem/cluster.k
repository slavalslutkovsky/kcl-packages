# cluster (onprem) — Crossplane Composition logic (function-kcl module).
# Nothing is provisioned: the cluster already exists somewhere no cloud
# provider reaches, and the XR ADOPTS it through a kubeconfig Secret the user
# places next to the XR. What the Composition manages is what runs on top —
# FluxCD, Crossplane and the GitOps entrypoint that pulls everything else —
# each a pinned Helm release driven through provider-helm from the management
# cluster. A per-XR ProviderConfig carries the kubeconfig, so every Release
# here lands in the adopted cluster and not in the one Crossplane runs on.
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as release
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_provider_config as providerconfig

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Key of the kubeconfig inside spec.kubeconfigSecret — the same key the cloud
# backends publish theirs under, so a Secret copied from a cloud cluster's
# connection secret adopts as-is.
kubeconfig_key = "kubeconfig"

# Pinned charts. flux2 and flux2-sync ship together from the fluxcd-community
# repo (2.19.0 / 1.15.0 both install Flux v2.9.1); crossplane matches the
# version the management cluster itself runs (devkit.toml).
flux_chart_repository = "https://fluxcd-community.github.io/helm-charts"
flux_chart_version = "2.19.0"
flux_sync_chart_version = "1.15.0"
flux_namespace = "flux-system"
crossplane_chart_repository = "https://charts.crossplane.io/stable"
crossplane_chart_version = "2.3.4"
crossplane_namespace = "crossplane-system"

# XRD defaults only exist on an XR that went through the API server; a locally
# rendered example or a unit test carries none. `or` would also swallow an
# explicit false, so presence — not truthiness — decides.
_flag = lambda v, fallback: bool -> bool {
    fallback if v in [None, Undefined] else v
}

# A Helm release's observed state — "deployed" once the chart is up. Read from
# the composed Release's atProvider; absent until the first reconcile.
_state = lambda ocds, res: str -> str {
    (ocds[res]?.Resource?.status?.atProvider?.state or "") if res in (ocds or {}) else ""
}

deployed = lambda ocds, res: str -> bool {
    _state(ocds, res) == "deployed"
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _boot = _spec?.bootstrap or {}
    _sync = _boot?.sync
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _flux = _flag(_boot?.flux?.enabled, True)
    _crossplane = _flag(_boot?.crossplane?.enabled, True)

    # Rejected shapes. A failed assert surfaces as a fatal function result,
    # which is the only way to tell the user something is wrong — the
    # alternative is silently pretending a field took effect.
    assert _spec?.kubeconfigSecret, "cluster-onprem: spec.kubeconfigSecret is required — the Secret (key `${kubeconfig_key}`) in the XR's namespace that reaches the existing cluster"
    assert not _spec?.version, "cluster-onprem: spec.version is not expressible — the version of an existing cluster is whatever it runs; drop it (status.version is not reported either)"
    assert not _spec?.autoscaling and not _spec?.machineType and not _spec?.spot, "cluster-onprem: spec.autoscaling, spec.machineType and spec.spot are not expressible — an existing cluster's nodes are not managed here"
    assert not _spec?.network, "cluster-onprem: spec.network is not expressible — an existing cluster is already on its network"
    assert not _spec?.resourceGroup, "cluster-onprem: spec.resourceGroup is Azure-only"
    assert not _sync or _flux, "cluster-onprem: spec.bootstrap.sync needs Flux — drop spec.bootstrap.flux.enabled=false, or drop the sync"

    # The adopted cluster's credentials, scoped to this XR. The helm provider
    # resolves a namespaced ProviderConfig in the Release's own namespace,
    # which is the XR's namespace for every composed resource. A ProviderConfig
    # has no Ready condition, so it is declared ready outright — otherwise the
    # XR would wait on it forever.
    _items: [any] = [providerconfig.ProviderConfig {
        metadata.name = _name
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "providerconfig"
            "krm.kcl.dev/ready" = "True"
        }
        spec.credentials = {
            source = "Secret"
            secretRef = {namespace = _ns, name = _spec.kubeconfigSecret, key = kubeconfig_key}
        }
    }]

    # One Release per component. external-name pins the Helm release name in
    # the adopted cluster; the composed MR's own name stays generated.
    _release = lambda res: str, chart, ns: str, values {
        release.Release {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = res
                "crossplane.io/external-name" = res
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.providerConfigRef = {kind = "ProviderConfig", name = _name}
            spec.forProvider.namespace = ns
            spec.forProvider.chart = chart
            if values:
                spec.forProvider.values = values
            spec.forProvider.wait = True
            spec.forProvider.waitTimeout = "10m"
        }
    }

    if _flux:
        _items += [_release("flux2", {
            name = "flux2"
            repository = flux_chart_repository
            version = _boot?.flux?.version or flux_chart_version
        }, flux_namespace, Undefined)]

    # The entrypoint is rendered only once Flux is up: its chart is nothing but
    # a GitRepository and a Kustomization, which cannot exist before the CRDs
    # the flux2 chart installs. Gating on the observed state keeps the Release
    # from being created just to fail until then.
    if _sync and deployed(ocds, "flux2"):
        _items += [_release("flux2-sync", {
            name = "flux2-sync"
            repository = flux_chart_repository
            version = flux_sync_chart_version
        }, flux_namespace, {
            gitRepository.spec = {
                url = _sync.url
                interval = _sync?.interval or "5m"
                # Only one of the two is set; the chart defaults to branch
                # `master` otherwise, which is why the XRD defaults branch.
                if _sync?.tag:
                    ref = {tag = _sync.tag}
                else:
                    ref = {branch = _sync?.branch or "main"}
                if _sync?.secretRef:
                    secretRef.name = _sync.secretRef
            }
            kustomization.spec = {
                path = _sync?.path or "./"
                interval = _sync?.interval or "5m"
                prune = True
                wait = True
            }
        })]

    if _crossplane:
        _items += [_release("crossplane", {
            name = "crossplane"
            repository = crossplane_chart_repository
            version = _boot?.crossplane?.version or crossplane_chart_version
        }, crossplane_namespace, Undefined)]

    _items
}

# Build the desired composite carrying observed status back to the XR. There
# is no cloud to read back from: ready means every requested component is
# deployed in the adopted cluster, and the kubeconfig is the one the user
# supplied.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _boot = _spec?.bootstrap or {}
    _site = _spec?.region or "onprem"

    _wanted = []
    if _flag(_boot?.flux?.enabled, True):
        _wanted += ["flux2"]
        if _boot?.sync:
            _wanted += ["flux2-sync"]


    if _flag(_boot?.crossplane?.enabled, True):
        _wanted += ["crossplane"]

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "KubernetesCluster"
        metadata.name = _name
        status = {
            provider = "onprem"
            ready = all _r in _wanted {
                deployed(ocds, _r)
            }
            name = _name
            if _spec?.kubeconfigSecret:
                kubeconfigSecret = _spec.kubeconfigSecret
            id = "${_site}/${_name}"
        }
    }
}
