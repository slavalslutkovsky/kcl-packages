import .application

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "Application", metadata = {name = "example", namespace = "default"}, spec = {image = "ghcr.io/org/api:v1", config = {LOG_LEVEL = "info"}, health = {readinessPath = "/healthz"}, route = {"type" = "gateway-api", hosts = ["api.example.org"], gateway = {name = "platform", namespace = "istio-ingress"}}}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# The application's objects + the desired composite carrying observed status
# back to the XR. render() needs no ocds: everything it emits is derived from
# the spec, and the observed Deployment and route only ever feed status().
items = application.render(_oxr) + [application.status(_oxr, _ocds)]
