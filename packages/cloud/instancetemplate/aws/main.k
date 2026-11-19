import .tpl

# function-kcl injects option("params"); fall back to an example for local runs.
# The fallback carries an observed LaunchTemplate id so `kcl run` also renders
# the instances, which are only composed once the template exists.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "example", namespace = "default"}, spec = {region = "us-east-1", imageId = "ami-0123456789abcdef0", instances = [{name = "a"}]}}
_observed = {"template" = {Resource.status.atProvider.id = "lt-0123456789abcdef0"}}
_params = option("params") or {oxr = _example, ocds = _observed}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = tpl.render(_oxr, _ocds) + [tpl.status(_oxr, _ocds)]
