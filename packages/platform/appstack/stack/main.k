import .appstack

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "AppStack", metadata.name = "example", spec = {provider = "gcp", region = "us-central1", api.image = "gcr.io/p/api:v1", worker.image = "gcr.io/p/worker:v1"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Child composite resources + the desired composite carrying observed status
# back to the XR. render() takes ocds because the cross-child wiring (network
# placement, injected database/cache coordinates) is derived from the children's
# observed status, which only exists on later reconciles.
items = appstack.render(_oxr, _ocds) + [appstack.status(_oxr, _ocds)]
