import .apigateway

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "ApiGateway", metadata.name = "example", spec = {backendUrl = "https://backend.example.com", region = "europe-west1", project = "example-project", hostname = "api.example.com", apigeeInstance = "example-instance", description = "example gateway"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = apigateway.render(_oxr) + [apigateway.status(_oxr, _ocds)]
