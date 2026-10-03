import .residency

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "Residency", metadata.name = "example", spec = {provider = "gcp", locations = [{name = "il"}], keys = [{name = "app-data"}]}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Child EncryptionKeys + the desired composite carrying observed status back to
# the XR. render() ignores ocds (the keys are independent); status() copies
# each key's published coordinates.
items = residency.render(_oxr) + [residency.status(_oxr, _ocds)]
