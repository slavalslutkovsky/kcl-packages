import .iam

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "Identity", metadata.name = "example", spec = {region = "westeurope", resourceGroup = "example-rg"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = iam.render(_oxr, _ocds) + [iam.status(_oxr, _ocds)]
