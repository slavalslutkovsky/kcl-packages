import file
import yaml
import .application

_anno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# NOTE: KCL normalizes the leading underscore, so a helper here shadows ANY
# lambda parameter of the same normalized name over in application.k (`_route`
# would shadow render()'s route helper, `_spec` its spec). Hence `_build`,
# `_pick`, `_kinds`.
_build = lambda _s {
    {apiVersion = "platform.example.org/v1alpha1", kind = "Application", metadata = {name = "demo", namespace = "shop"}, spec = _s}
}

# The smallest spec the XRD admits.
_min = {image = "reg/api:v1"}

# Pick one composed object by its composition-resource-name.
_pick = lambda _items, _res: str {
    [i for i in _items if i.metadata.annotations[_anno] == _res][0]
}

_kinds = lambda _items {
    [i.kind for i in _items]
}

_names = lambda _items {
    [i.metadata.annotations[_anno] for i in _items]
}

_gwRoute = {
    "type" = "gateway-api"
    hosts = ["api.example.org"]
    gateway = {name = "platform", namespace = "istio-ingress"}
}

_meshRoute = {
    "type" = "istio"
    hosts = ["api.example.org"]
    gateway = {name = "platform", namespace = "istio-ingress"}
}

# Shape as function-kcl hands observed state over.
_wrap = lambda _st {
    {
        Resource = {status = _st}
    }
}

_deploymentUp = _wrap({replicas = 3, availableReplicas = 3, readyReplicas = 3})
_routeAccepted = _wrap({parents = [{conditions = [{"type" = "ResolvedRefs", "status" = "True"}, {"type" = "Accepted", "status" = "True"}]}]})
_routeRejected = _wrap({parents = [{conditions = [{"type" = "Accepted", "status" = "False", reason = "NotAllowedByListeners"}]}]})

# ---- workload ---------------------------------------------------------------
test_minimal_renders_workload_only = lambda {
    items = application.render(_build(_min))
    assert _kinds(items) == ["Deployment", "Service"], "no config, no secrets, no route: two objects"
    assert _names(items) == ["deployment", "service"]
    d = _pick(items, "deployment")
    assert d.metadata.name == "demo"
    assert d.metadata?.namespace == Undefined, "Crossplane places composed resources; a namespace here would fight it"
    assert d.spec.replicas == 2, "the XR default, not the app package's 0"
    assert d.spec.template.spec.containers[0].image == "reg/api:v1"
    assert d.spec.template.spec.containers[0].ports[0].containerPort == 8080
    assert _pick(items, "service").spec.ports[0].port == 8080
}

test_env_is_sorted = lambda {
    items = application.render(_build(_min | {
        env = {ZONE = "eu", ALPHA = "1", MIDDLE = "x"}
    }))
    env = _pick(items, "deployment").spec.template.spec.containers[0].env
    assert [e.name for e in env] == ["ALPHA", "MIDDLE", "ZONE"], "map order must not leak into the pod template"
    assert [e.value for e in env] == ["1", "x", "eu"]
}

test_config_is_rendered_and_mounted = lambda {
    items = application.render(_build(_min | {
        config = {LOG_LEVEL = "debug"}
    }))
    cm = _pick(items, "config")
    assert cm.kind == "ConfigMap" and cm.metadata.name == "demo-config"
    assert cm.data == {LOG_LEVEL = "debug"}
    envFrom = _pick(items, "deployment").spec.template.spec.containers[0].envFrom
    assert len(envFrom) == 1 and envFrom[0].configMapRef.name == "demo-config", "the wiring a values.yaml leaves to its author"
}

test_secrets_become_an_externalsecret_and_are_mounted = lambda {
    items = application.render(_build(_min | {
        secrets = {
            store = "aws-secrets"
            refreshInterval = "15m"
            items = [{secretKey = "TOKEN", key = "demo-token"}, {secretKey = "DSN", key = "demo-db", property = "url"}]
        }
    }))
    es = _pick(items, "secrets")
    assert es.kind == "ExternalSecret" and es.metadata.name == "demo-secrets"
    assert es.spec.refreshInterval == "15m"
    assert es.spec.secretStoreRef.name == "aws-secrets" and es.spec.secretStoreRef.kind == "ClusterSecretStore"
    assert es.spec.target.name == "demo-secrets"
    assert [d.secretKey for d in es.spec.data] == ["TOKEN", "DSN"]
    assert es.spec.data[1].remoteRef.property == "url"
    envFrom = _pick(items, "deployment").spec.template.spec.containers[0].envFrom
    assert len(envFrom) == 1 and envFrom[0].secretRef.name == "demo-secrets"
    assert envFrom[0].secretRef.optional == False, "a pod without its credentials must wait, not start"
}

test_secrets_can_be_left_unmounted = lambda {
    items = application.render(_build(_min | {
        secrets = {
            mountAsEnv = False
            items = [{secretKey = "TOKEN", key = "demo-token"}]
        }
    }))
    assert _pick(items, "secrets").spec.secretStoreRef.name == "gcp-secret-manager", "store default"
    assert _pick(items, "deployment").spec.template.spec.containers[0]?.envFrom == Undefined
}

test_probes_share_the_container_port = lambda {
    items = application.render(_build(_min | {port = 9090, health = {
        readinessPath = "/ready"
        livenessPath = "/live"
        startupPath = "/start"
        failureThreshold = 6
        periodSeconds = 5
    }}))
    c = _pick(items, "deployment").spec.template.spec.containers[0]
    assert c.readinessProbe.httpGet.path == "/ready" and c.readinessProbe.httpGet.port == 9090
    assert c.livenessProbe.httpGet.path == "/live" and c.livenessProbe.httpGet.port == 9090
    assert c.startupProbe.httpGet.path == "/start" and c.startupProbe.httpGet.port == 9090
    assert c.readinessProbe.failureThreshold == 6 and c.readinessProbe.periodSeconds == 5
}

test_resources_deep_merge_onto_the_defaults = lambda {
    items = application.render(_build(_min | {
        resources = {
            limits = {memory = "1Gi"}
        }
    }))
    res = _pick(items, "deployment").spec.template.spec.containers[0].resources
    assert res.limits.memory == "1Gi"
    assert res.requests == {memory = "128Mi", cpu = "250m"}, "a partial override must not drop the requests"
}

test_scaling_hands_the_replica_count_to_keda = lambda {
    items = application.render(_build(_min | {replicas = 7, scaling = {
        minReplicas = 0
        maxReplicas = 20
        cpu = 60
        triggers = [{"type" = "nats-jetstream", metadata = {stream = "orders", lagThreshold = "50"}, metricType = "AverageValue"}]
    }}))
    assert _kinds(items) == ["Deployment", "Service", "ScaledObject"]
    assert _pick(items, "deployment").spec?.replicas == Undefined, "the autoscaler owns the replica count"
    so = _pick(items, "scaler")
    assert so.spec.minReplicaCount == 0 and so.spec.maxReplicaCount == 20
    assert so.spec.scaleTargetRef.name == "demo"
    types = [t.type for t in so.spec.triggers]
    assert "cpu" in types and "nats-jetstream" in types
    nats = [t for t in so.spec.triggers if t.type == "nats-jetstream"][0]
    assert nats.metadata.stream == "orders" and nats.metricType == "AverageValue"
}

test_prometheus_off_is_honoured = lambda {
    items = application.render(_build(_min | {prometheus = False}))
    ann = _pick(items, "deployment").spec.template.metadata?.annotations
    assert ann == Undefined, "false is a value, not an unset field"
}

# ---- gateway api ------------------------------------------------------------
test_gateway_api_route = lambda {
    items = application.render(_build(_min | {port = 8443, route = _gwRoute | {path = "/api", pathType = "Exact", timeoutSeconds = 15}}))
    assert _kinds(items) == ["Deployment", "Service", "HTTPRoute"]
    r = _pick(items, "route")
    assert r.apiVersion == "gateway.networking.k8s.io/v1"
    assert r.metadata.name == "demo"
    assert r.spec.hostnames == ["api.example.org"]
    assert r.spec.parentRefs[0].name == "platform" and r.spec.parentRefs[0].namespace == "istio-ingress"
    assert r.spec.parentRefs[0]?.sectionName == Undefined
    only = r.spec.rules[0]
    assert only.matches[0].path["type"] == "Exact" and only.matches[0].path.value == "/api"
    assert only.backendRefs[0].name == "demo" and only.backendRefs[0].port == 8443
    assert only.timeouts.request == "15s", "Gateway API takes a Go duration, not seconds"
}

test_gateway_api_section_name_and_defaults = lambda {
    items = application.render(_build(_min | {route = _gwRoute | {
        gateway = {name = "platform", sectionName = "https"}
    }}))
    r = _pick(items, "route")
    parent = r.spec.parentRefs[0]
    assert parent.group == "gateway.networking.k8s.io" and parent.kind == "Gateway"
    assert parent.name == "platform" and parent.sectionName == "https" and parent?.namespace == Undefined
    assert r.spec.rules[0].matches[0].path["type"] == "PathPrefix" and r.spec.rules[0].matches[0].path.value == "/"
    assert r.spec.rules[0]?.timeouts == Undefined, "no timeout leaves the implementation default"
}

test_gateway_api_ignores_istio_only_knobs = lambda {
    items = application.render(_build(_min | {route = _gwRoute | {
        retries = {attempts = 3}
        trafficPolicy = {maxConnections = 10}
    }}))
    assert _kinds(items) == ["Deployment", "Service", "HTTPRoute"], "no DestinationRule without the mesh"
    assert _pick(items, "route").spec.rules[0]?.timeouts == Undefined, "trafficPolicy is not a timeout, and retries have no standard HTTPRoute field at all"
}

# ---- istio ------------------------------------------------------------------
test_istio_virtualservice = lambda {
    items = application.render(_build(_min | {route = _meshRoute | {path = "/api", timeoutSeconds = 10, retries = {attempts = 3, perTryTimeoutSeconds = 2}}}))
    assert _kinds(items) == ["Deployment", "Service", "VirtualService"]
    vs = _pick(items, "route")
    assert vs.apiVersion == "networking.istio.io/v1"
    assert vs.spec.hosts == ["api.example.org"]
    assert vs.spec.gateways == ["istio-ingress/platform"], "a gateway elsewhere is <namespace>/<name>"
    http = vs.spec.http[0]
    assert http.match[0].uri.prefix == "/api" and http.match[0].uri?.exact == Undefined
    assert http.route[0].destination.host == "demo" and http.route[0].destination.port.number == 8080
    assert http.timeout == "10s"
    assert http.retries.attempts == 3 and http.retries.perTryTimeout == "2s"
    assert http.retries.retryOn == "connect-failure,refused-stream,unavailable,5xx"
}

test_istio_exact_path_and_local_gateway = lambda {
    items = application.render(_build(_min | {route = _meshRoute | {path = "/exact", pathType = "Exact", gateway = {name = "mesh"}}}))
    vs = _pick(items, "route")
    assert vs.spec.http[0].match[0].uri.exact == "/exact" and vs.spec.http[0].match[0].uri?.prefix == Undefined
    assert vs.spec.gateways == ["mesh"], "a bare name means this namespace"
    assert vs.spec.http[0]?.retries == Undefined
}

test_istio_traffic_policy_becomes_a_destinationrule = lambda {
    items = application.render(_build(_min | {route = _meshRoute | {
        trafficPolicy = {
            loadBalancer = "LEAST_REQUEST"
            maxConnections = 256
            outlierDetection = True
        }
    }}))
    assert _kinds(items) == ["Deployment", "Service", "VirtualService", "DestinationRule"]
    dr = _pick(items, "destination")
    assert dr.spec.host == "demo"
    assert dr.spec.trafficPolicy.loadBalancer.simple == "LEAST_REQUEST"
    assert dr.spec.trafficPolicy.connectionPool.tcp.maxConnections == 256
    od = dr.spec.trafficPolicy.outlierDetection
    assert od.consecutive5xxErrors == 5 and od.maxEjectionPercent == 50, "ejection can never empty the pool"
}

test_istio_without_traffic_policy_emits_no_destinationrule = lambda {
    items = application.render(_build(_min | {route = _meshRoute}))
    assert _kinds(items) == ["Deployment", "Service", "VirtualService"], "an empty DestinationRule would own the host and change nothing"
}

# ---- route validation -------------------------------------------------------

# render() asserts that a route carries both `hosts` and `gateway` — the XRD
# cannot express "required once type is set" — and a failing KCL assert aborts
# the run rather than something a test can catch. So what is pinned here is the
# rejecting condition itself: with type `none` neither field is read, nothing
# routes, and the application is reachable only through its ClusterIP Service.
test_route_none_reads_no_route_fields = lambda {
    items = application.render(_build(_min | {
        route = {"type" = "none"}
    }))
    assert _kinds(items) == ["Deployment", "Service"]
    assert application.status(_build(_min | {
        route = {"type" = "none"}
    }), {deployment = _deploymentUp}).status.ready == True
}

# ---- examples ---------------------------------------------------------------
test_examples_render = lambda {
    gw = application.render(yaml.decode(file.read("../xrd/examples/application-k8s.yaml")))
    mesh = application.render(yaml.decode(file.read("../xrd/examples/application-istio.yaml")))
    assert _kinds(gw) == ["Deployment", "Service", "ScaledObject", "ConfigMap", "ExternalSecret", "HTTPRoute"]
    assert _pick(gw, "route").spec.rules[0].timeouts.request == "15s"
    remote = _pick(gw, "secrets").spec.data[1].remoteRef
    assert remote.key == "checkout-db" and remote.property == "url"
    envFrom = _pick(gw, "deployment").spec.template.spec.containers[0].envFrom
    assert envFrom[0].configMapRef.name == "checkout-api-config"
    assert envFrom[1].secretRef.name == "checkout-api-secrets" and envFrom[1].secretRef.optional == False
    assert _kinds(mesh) == ["Deployment", "Service", "VirtualService", "DestinationRule"]
    assert _pick(mesh, "route").spec.http[0].match[0].uri.prefix == "/api"
}

# ---- status -----------------------------------------------------------------
test_status_first_reconcile = lambda {
    st = application.status(_build(_min), {})
    assert st.kind == "Application" and st.apiVersion == "platform.example.org/v1alpha1"
    assert st.metadata.name == "demo"
    assert st.status.ready == False and st.status.workloadReady == False
    assert st.status.availableReplicas == 0 and st.status.replicas == 0
    assert st.status.serviceName == "demo"
    assert st.status.endpoint == "demo.shop.svc.cluster.local:8080"
    assert st.status.route == "none"
    assert st.status?.routeReady == Undefined and st.status?.url == Undefined, "nothing to report about a route nobody asked for"
    assert st.status.message == "deployment/demo has no available replicas yet"
}

test_status_ready_without_a_route = lambda {
    st = application.status(_build(_min), {deployment = _deploymentUp})
    assert st.status.ready == True and st.status.workloadReady == True
    assert st.status.availableReplicas == 3 and st.status.replicas == 3
    assert st.status.message == ""
}

test_status_waits_for_the_gateway_to_accept = lambda {
    oxr = _build(_min | {route = _gwRoute | {path = "/api"}})
    pending = application.status(oxr, {deployment = _deploymentUp, route = _wrap({})})
    assert pending.status.workloadReady == True
    assert pending.status.routeReady == False and pending.status.ready == False
    assert pending.status.message == "route/demo is not accepted by gateway istio-ingress/platform yet"
    rejected = application.status(oxr, {deployment = _deploymentUp, route = _routeRejected})
    assert rejected.status.ready == False, "a parent that refused the route is not readiness"
    ready = application.status(oxr, {deployment = _deploymentUp, route = _routeAccepted})
    assert ready.status.ready == True and ready.status.routeReady == True
    assert ready.status.url == "https://api.example.org/api"
    assert ready.status.hosts == ["api.example.org"]
}

test_status_istio_route_is_ready_once_it_exists = lambda {
    oxr = _build(_min | {route = _meshRoute})
    st = application.status(oxr, {deployment = _deploymentUp, route = _wrap({})})
    assert st.status.ready == True, "Istio publishes no status on a VirtualService; existence is the only signal"
    assert st.status.route == "istio" and st.status.url == "https://api.example.org", "a root path is not appended to the url"
}

test_status_route_without_a_workload_reports_the_workload = lambda {
    st = application.status(_build(_min | {route = _gwRoute}), {route = _routeAccepted})
    assert st.status.routeReady == True and st.status.ready == False
    assert st.status.message == "deployment/demo has no available replicas yet", "the first missing thing, not the last"
}
