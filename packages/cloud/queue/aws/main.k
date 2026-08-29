import .queue

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "Queue", metadata.name = "example", spec = {region = "us-east-1"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to
# the XR. render also takes ocds: the redrive policy needs the observed DLQ ARN.
items = queue.render(_oxr, _ocds) + [queue.status(_oxr, _ocds)]
