import .network

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "Network", metadata.name = "example", spec = {region = "us-east-1", cidr = "10.0.0.0/16", subnetPrefixLength = 20, availabilityZones = ["us-east-1a", "us-east-1b"]}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = network.render(_oxr) + [network.status(_oxr, _ocds)]
