import .kms

# function-kcl injects option("params"); fall back to an example for local runs.
# The XRD requires spec.region for the cloud backends; openbao ignores it, so the
# example says where this key actually lives.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "example", spec = {region = "in-cluster"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = kms.render(_oxr) + [kms.status(_oxr, _ocds)]
