import .bucket

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "Bucket", metadata.name = "example", spec = {region = "us-central1"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = bucket.render(_oxr) + [bucket.status(_oxr, _ocds)]
