import .tpl

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "example", namespace = "default"}, spec = {region = "us-central1", instances = [{name = "a"}]}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = tpl.render(_oxr, _ocds) + [tpl.status(_oxr, _ocds)]
