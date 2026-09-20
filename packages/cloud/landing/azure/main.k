import .landing

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "LandingPage"
    metadata.name = "example"
    spec = {
        region = "westeurope"
        resourceGroup = "platform-rg"
        content.html = "<!doctype html><title>example</title>"
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = landing.render(_oxr, _ocds) + [landing.status(_oxr, _ocds)]
