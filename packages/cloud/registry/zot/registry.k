# registry (zot) — Crossplane Composition logic (function-kcl module).
# The in-cluster backend: no cloud account, no IAM. Typed against the helm
# schema package, it renders one namespaced provider-helm Release that installs
# the zot chart into the XR's own namespace. zot is the CNCF OCI-native
# registry (project-zot), so a client that pushes to ECR/Artifact
# Registry/ACR pushes here unchanged.
import json
import helm.models.v1beta1.helmm_crossplane_io_v1beta1_release as backend

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Pinned so a re-render never silently upgrades a running registry.
chart_repository = "https://zotregistry.dev/helm-charts"
chart_name = "zot"
chart_version = "0.1.122"

# The chart's container port, and the service port it publishes.
registry_port = 5000

# Where the chart mounts a Secret listed in `externalSecrets`, and the htpasswd
# file zot then reads inside it.
secret_mount = "/secret"
htpasswd_key = "htpasswd"

# Chart service name, given `fullnameOverride = <xr name>`.
service_host = lambda name: str, namespace: str -> str {
    "${name}.${namespace}.svc.cluster.local"
}

# zot's config.json. Storage retention needs the garbage collector: without
# `gc` the policies are recorded and never act.
config_json = lambda spec: any -> str {
    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel; both mean
    # "no retention asked for", and neither day count nor image count can be 0.
    _untagged = spec?.untaggedRetentionDays or Undefined
    _keep = spec?.keepLastImages or Undefined

    _storage: {str:any} = {
        rootDirectory = "/var/lib/registry"
        dedupe = True
        gc = True
        gcDelay = "1h"
    }
    if _untagged != Undefined or _keep != Undefined:
        _policy: {str:any} = {repositories = ["**"], deleteUntagged = _untagged != Undefined}
        if _keep != Undefined:
            # keepTags patterns are Go REGEXES (repository names above are
            # globs): ".*" is every tag, "**" does not compile.
            _policy = _policy | {keepTags = [{patterns = [".*"], mostRecentlyPushedCount = _keep}]}

        _retention: {str:any} = {dryRun = False, policies = [_policy]}

        # Untagged images become deletable only once this delay has elapsed
        # since they were pushed; with no age limit there is no delay to set.
        if _untagged != Undefined:
            _retention = _retention | {delay = "${_untagged * 24}h"}

        _storage = _storage | {retention = _retention}

    _http: {str:any} = {address = "0.0.0.0", port = "${registry_port}", readTimeout = "60s", writeTimeout = "60s"}

    # Credentials are supplied by the user's own Secret; without one zot serves
    # anonymous read/write, which is safe only because the chart publishes a
    # ClusterIP service and no ingress.
    if spec?.htpasswdSecret:
        _http = _http | {
            auth = {
                htpasswd = {path = "${secret_mount}/${htpasswd_key}"}
            }
            accessControl = {
                repositories = {
                    "**" = {
                        defaultPolicy = ["read", "create", "update", "delete"]
                        anonymousPolicy = ["read"] if (spec?.publicAccess or False) else []
                    }
                }
            }
        }

    _cfg: {str:any} = {storage = _storage, http = _http, log = {level = "info"}}

    # The CVE search extension is zot's scanning story: it downloads the
    # vulnerability database and reports per-image CVEs.
    _scan = spec?.scanOnPush
    if _scan == Undefined:
        _scan = True

    if _scan:
        _cfg = _cfg | {
            extensions = {
                search = {enable = True, cve = {updateInterval = "2h"}}
            }
        }

    json.encode(_cfg)
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"

    _values = {
        fullnameOverride = _name
        service = {$type = "ClusterIP", port = registry_port}
        # Images are large and a registry that loses them on restart is not a
        # registry: the chart switches to a StatefulSet with a PVC when
        # persistence is on.
        persistence = True
        pvc = {create = True, storage = "${_spec?.storageGb or 8}Gi"}
        mountConfig = True
        configFiles = {"config.json" = config_json(_spec)}
        if _spec?.htpasswdSecret:
            externalSecrets = [{secretName = _spec.htpasswdSecret, mountPath = secret_mount}]
        if _spec?.tags:
            podLabels = _spec.tags
    }

    # external-name pins the Helm release name to the XR name, matching the
    # chart resource names `fullnameOverride` produces (and the endpoints
    # status() reports).
    [backend.Release {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if (_spec?.deletionPolicy or "Delete") == "Orphan":
            spec.managementPolicies = _orphan_policies
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
    }]
}

# Build the desired composite carrying observed status back to the XR.
# In-cluster endpoints are deterministic from the release name, so they are
# reported as soon as the chart is deployed rather than read back from a cloud.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _host = "${service_host(_name, _ns)}:${registry_port}"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Registry"
        metadata.name = _name
        status = {
            provider = "zot"
            ready = (_at?.state or "") == "deployed"
            registryName = _name
            endpoint = _host
            repository = "${_host}/${_name}"
            url = "oci://${_host}/${_name}"
            "cloud-url" = "kubernetes://${_ns}/statefulset/${_name}"
            if _spec?.htpasswdSecret:
                authSecret = _spec.htpasswdSecret
            if _at?.revision:
                id = "${_ns}/${_name}@${_at.revision}"
        }
    }
}
