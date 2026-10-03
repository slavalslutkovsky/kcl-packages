# application — Crossplane Composition logic (function-kcl module).
#
# A WRAPPER, not a second renderer. The Deployment, Service, ConfigMap, KEDA
# ScaledObject and ExternalSecret come out of the `app` package (packages/app)
# — the same library `kcl run packages/app -D values=…` and `just
# component-push` use — so an Application XR and a values.yaml produce the same
# objects from the same code. Only two things happen here that the app package
# does not do: the pieces are WIRED to each other (a ConfigMap and the
# generated Secret are mounted as envFrom, instead of the values file author
# repeating their names), and the north-south ROUTE is rendered, typed against
# the Gateway API and Istio CRD schemas.
#
# `app.lib`, not `app`: importing the package root would execute its main.k and
# emit its demo release into this module's output (same reason
# platform/pricing imports it that way).
#
# Crossplane v2 composes arbitrary namespaced resources, so there is no
# provider MR wrapper and no providerConfigRef anywhere below; composed objects
# carry no namespace (Crossplane places them in the XR's) and each one carries
# the composition-resource-name annotation that makes it addressable in ocds.
import app.lib as app
import gateway_api.models.v1.gateway_networking_k8s_io_v1_http_route as gwapi
import istio.models.v1.networking_istio_io_v1_virtual_service as istiovs
import istio.models.v1.networking_istio_io_v1_destination_rule as istiodr

# Composed-resource name per kind the app package renders. The names are what
# status() reads back out of ocds, so they are part of this module's contract
# and must not be renamed casually.
_appResources = {
    Deployment = "deployment"
    Service = "service"
    ConfigMap = "config"
    ScaledObject = "scaler"
    HorizontalPodAutoscaler = "hpa"
    ExternalSecret = "secrets"
}

_resAnno = lambda name: str -> {str:str} {
    {"krm.kcl.dev/composition-resource-name" = name}
}

# Explicit "was this field set?" test. Truthiness cannot answer it: `false` and
# `0` are legitimate values that must still be forwarded (prometheus: false,
# replicas: 0, minReplicas: 0).
_set = lambda value -> bool {
    not (value == Undefined or value == None)
}

# Key lookup with a default. Written as an index rather than `?.` because the
# XRD has fields KCL reserves as keywords (`type`), which `.type` will not parse.
_get = lambda src: {str:any}, key: str, fallback: any -> any {
    src[key] if key in src and _set(src[key]) else fallback
}

# ── Workload (rendered by the app package) ───────────────────────────────────
_probe = lambda path: str, port: int, health: {str:any} -> app.Probe {
    app.Probe {
        path = path
        port = port
        failureThreshold = _get(health, "failureThreshold", 3)
        periodSeconds = _get(health, "periodSeconds", 10)
    }
}

# KEDA over a native HPA: a superset (the same cpu/memory utilisation triggers,
# plus event-driven ones and scale-to-zero), and the app package rejects both
# at once. Passthrough triggers keep their KEDA shape verbatim.
_scaler = lambda scaling: {str:any} -> app.Scaler {
    app.Scaler {
        minReplicas = _get(scaling, "minReplicas", 1)
        maxReplicas = _get(scaling, "maxReplicas", 10)
        if _set(scaling?.cpu):
            cpu = scaling.cpu
        if _set(scaling?.memory):
            memory = scaling.memory
        triggers = [{
            $type = _t["type"]
            metadata = _t?.metadata or {}
        } | ({metricType = _t.metricType} if _t?.metricType else {}) | ({name = _t.name} if _t?.name else {}) for _t in (scaling?.triggers or [])]
    }
}

_workload = lambda name: str, spec: {str:any} -> app.Workload {
    _port = _get(spec, "port", 8080)
    _health = spec?.health or {}
    _env = spec?.env or {}
    _secrets = spec?.secrets

    # The wiring a values.yaml leaves to its author: the ConfigMap the app
    # package renders from `config` and the Secret external-secrets creates
    # from `secrets` are mounted here, by the same derived names.
    # `optional = False` on the secret is deliberate — a pod that starts
    # without its credentials fails later and less legibly than one that waits.
    _envFrom = ([{kind = "configMap", name = "${name}-config"}] if spec?.config else []) + ([{
        kind = "secret"
        name = "${name}-secrets"
        optional = False
    }] if _secrets and _get(_secrets, "mountAsEnv", True) else [])

    _w = app.Workload {
        name = name
        image = spec.image
        component = _get(spec, "component", "server")
        partOf = _get(spec, "partOf", "platform")
        if _set(spec?.version):
            version = spec.version
        port = _port
        # Ignored by the app package once `scaler` is set: the Deployment is
        # then rendered without spec.replicas so a re-apply cannot fight the
        # autoscaler over the replica count.
        replicas = _get(spec, "replicas", 2)
        prometheus = _get(spec, "prometheus", True)
        metricsPath = _get(spec, "metricsPath", "/metrics")
        # Sorted: map iteration order must never leak into the pod template,
        # or an unchanged spec would roll the Deployment.
        env = [{name = _k, value = _env[_k]} for _k in sorted(_env)]
        envFrom = _envFrom
        if _health?.startupPath:
            startupProbe = _probe(_health.startupPath, _port, _health)
        if _health?.livenessPath:
            livenessProbe = _probe(_health.livenessPath, _port, _health)
        if _health?.readinessPath:
            readinessProbe = _probe(_health.readinessPath, _port, _health)
        if spec?.scaling:
            scaler = _scaler(spec.scaling)
    }

    # Deep-merge onto the app package's own defaults rather than replacing
    # them: a spec that sets only limits.memory must not silently drop the
    # requests. mergeValues is the same right-wins merge the env overlays use.
    _w | {resources = app.mergeValues(_w.resources, spec.resources)} if _set(spec?.resources) else _w
}

_release = lambda name: str, spec: {str:any} -> app.Release {
    _secrets = spec?.secrets
    app.Release {
        workload = _workload(name, spec)
        if spec?.config:
            config = spec.config
        # Nothing secret is written into the XR — only the coordinates of what
        # external-secrets should fetch, and the ClusterSecretStore to fetch it
        # from. The target Secret is "<name>-secrets" (the app package default).
        if _secrets:
            externalSecret = app.ExternalSecretSpec {
                store = _get(_secrets, "store", "gcp-secret-manager")
                refreshInterval = _get(_secrets, "refreshInterval", "1h")
                items = _secrets["items"]
            }
    }
}

# The app package renders objects for a values file, i.e. without the
# composed-resource annotation Crossplane addresses them by. Stamp it from the
# kind: one object per kind here, so the kind IS the identity.
_composed = lambda items: [any] -> [any] {
    [_it | {metadata.annotations = _resAnno(_appResources[_it.kind] or _it.kind.lower())} for _it in items]
}

# ── Route ────────────────────────────────────────────────────────────────────
# The Gateway is referenced, never created: one Gateway per application is one
# load balancer per application. Both backends attach to a shared,
# platform-owned gateway.
_httpRoute = lambda name: str, port: int, route: {str:any} -> gwapi.HTTPRoute {
    _gw = route["gateway"]
    _timeout = route?.timeoutSeconds
    gwapi.HTTPRoute {
        metadata = {
            name = name
            annotations = _resAnno("route")
        }
        spec = {
            hostnames = route["hosts"]
            parentRefs = [{
                name = _gw["name"]
            } | ({namespace = _gw.namespace} if _gw?.namespace else {}) | ({sectionName = _gw.sectionName} if _gw?.sectionName else {})]
            rules = [{
                matches = [{
                    path = {$type = _get(route, "pathType", "PathPrefix"), value = _get(route, "path", "/")}
                }]
                # The Service the app package rendered, in this namespace.
                backendRefs = [{name = name, port = port}]
                # Gateway API durations are Go durations, not seconds.
                if _set(_timeout):
                    timeouts = {request = "${_timeout}s"}
            }]
        }
    }
}

# Istio addresses a Gateway in another namespace as "<namespace>/<name>";
# bare means "this namespace".
_gatewayRef = lambda gw: {str:any} -> str {
    "${gw.namespace}/${gw['name']}" if gw?.namespace else gw["name"]
}

_virtualService = lambda name: str, port: int, route: {str:any} -> istiovs.VirtualService {
    _timeout = route?.timeoutSeconds
    _retries = route?.retries
    _path = _get(route, "path", "/")
    istiovs.VirtualService {
        metadata = {
            name = name
            annotations = _resAnno("route")
        }
        spec = {
            hosts = route["hosts"]
            gateways = [_gatewayRef(route["gateway"])]
            http = [{
                match = [{uri = {exact = _path} if _get(route, "pathType", "PathPrefix") == "Exact" else {prefix = _path}}]
                # Short name: the Service lives in the same namespace as this
                # VirtualService, so a FQDN would only hard-code the namespace
                # Crossplane already chose.
                route = [{
                    destination = {host = name, port = {number = port}}
                }]
                if _set(_timeout):
                    timeout = "${_timeout}s"
                if _retries:
                    retries = {
                        attempts = _get(_retries, "attempts", 2)
                        retryOn = _get(_retries, "retryOn", "connect-failure,refused-stream,unavailable,5xx")
                    } | ({perTryTimeout = "${_retries.perTryTimeoutSeconds}s"} if _retries?.perTryTimeoutSeconds else {})
            }]
        }
    }
}

# Applies to every caller of this Service, north-south and east-west alike —
# which is the point: a connection-pool ceiling that only held for gateway
# traffic would not protect the application.
_destinationRule = lambda name: str, policy: {str:any} -> istiodr.DestinationRule {
    istiodr.DestinationRule {
        metadata = {
            name = name
            annotations = _resAnno("destination")
        }
        spec = {
            host = name
            trafficPolicy = ({
                loadBalancer = {simple = policy.loadBalancer}
            } if policy?.loadBalancer else {}) | ({
                connectionPool = {
                    tcp = {maxConnections = policy.maxConnections}
                }
            } if _set(policy?.maxConnections) else {}) | ({
                # Consecutive-5xx ejection with a bounded blast radius: at most
                # half the endpoints can be ejected at once, so outlier
                # detection can never empty the pool.
                outlierDetection = {
                    consecutive5xxErrors = 5
                    interval = "10s"
                    baseEjectionTime = "30s"
                    maxEjectionPercent = 50
                }
            } if _get(policy, "outlierDetection", False) else {})
        }
    }
}

# The mesh pair: the VirtualService always, the DestinationRule only when a
# traffic policy was asked for — an empty DestinationRule would claim
# ownership of the host and change nothing.
_istioRoute = lambda name: str, port: int, route: {str:any} -> [any] {
    _policy = route?.trafficPolicy
    [_virtualService(name, port, route)] + ([_destinationRule(name, _policy)] if _policy else [])
}

_route = lambda name: str, port: int, route: {str:any} -> [any] {
    _routeType = _get(route, "type", "none")
    ([_httpRoute(name, port, route)] if _routeType == "gateway-api" else []) + (_istioRoute(name, port, route) if _routeType == "istio" else [])
}

# render(oxr) — every object of one application. No ocds parameter: what is
# emitted is derived entirely from the spec, and the observed state only ever
# feeds status().
render = lambda oxr -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _routeSpec = _spec?.route or {}
    _routeType = _get(_routeSpec, "type", "none")

    # The XRD cannot express "required once type is set" (structural schemas
    # have no conditional requirements), so the two fields a route cannot be
    # built without are checked here, where the fix can be stated.
    assert _routeType == "none" or _routeSpec?.hosts, "route.type is ${_routeType} but no route.hosts: a route with no hostname would claim every hostname the gateway serves. Set route.hosts, or route.type: none for a Service-only application."
    assert _routeType == "none" or _routeSpec?.gateway, "route.type is ${_routeType} but no route.gateway: this XR attaches to a shared, platform-owned gateway and never creates one. Set route.gateway.name (and .namespace when it lives elsewhere)."

    _composed(app.renderRelease(_release(_name, _spec))) + _route(_name, _get(_spec, "port", 8080), _routeSpec)
}

# ── Status ───────────────────────────────────────────────────────────────────
_observed = lambda ocds, name: str -> any {
    (ocds[name]?.Resource?.status) if (name in ocds) else Undefined
}

# Gateway API publishes acceptance per attached parent: the route exists long
# before a gateway has agreed to serve it, and a rejected parentRef (wrong
# listener, hostname not allowed, cross-namespace without a ReferenceGrant) is
# reported here and nowhere else.
_acceptedBy = lambda conditions: [any] -> bool {
    any _c in conditions {
        _c["type"] == "Accepted" and _c["status"] == "True"
    }
}

_accepted = lambda st -> bool {
    _parents = st?.parents or []
    any _p in _parents {
        _acceptedBy(_p?.conditions or [])
    }
}

# Build the desired composite carrying observed state back to the XR.
status = lambda oxr, ocds -> any {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _port = _get(_spec, "port", 8080)
    _routeSpec = _spec?.route or {}
    _routeType = _get(_routeSpec, "type", "none")
    _hosts = _routeSpec?.hosts or []
    _path = _get(_routeSpec, "path", "/")

    _dep = _observed(ocds, "deployment")
    _available = _dep?.availableReplicas or 0
    _workloadReady = _available > 0

    # Istio publishes no status on a VirtualService, so its existence in ocds
    # is the only signal there is; an HTTPRoute is only routing traffic once a
    # parent accepted it.
    _routeObserved = "route" in ocds
    _routeReady = True if _routeType == "none" else (_accepted(_observed(ocds, "route")) if _routeType == "gateway-api" else _routeObserved)

    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "Application"
        metadata.name = _name
        status = {
            ready = _workloadReady and _routeReady
            workloadReady = _workloadReady
            replicas = _dep?.replicas or 0
            availableReplicas = _available
            serviceName = _name
            endpoint = "${_name}.${_ns}.svc.cluster.local:${_port}"
            route = _routeType
            if _routeType != "none":
                routeReady = _routeReady
                hosts = _hosts
                if _hosts:
                    url = "https://${_hosts[0]}" + ("" if _path == "/" else _path)
            if not _workloadReady:
                message = "deployment/${_name} has no available replicas yet"
            elif not _routeReady:
                message = "route/${_name} is not accepted by gateway ${_gatewayRef(_routeSpec['gateway'])} yet"
            else:
                message = ""
        }
    }
}
