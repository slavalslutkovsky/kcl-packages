import .serverless

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "ServerlessApp", metadata = {name = "example", namespace = "default"}, spec = {image = "ghcr.io/acme/hello:1.2.0", region = "in-cluster"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = serverless.render(_oxr) + [serverless.status(_oxr, _ocds)]
