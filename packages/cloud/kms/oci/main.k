import .kms

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "EncryptionKey", metadata.name = "example", spec = {region = "il-jerusalem-1", compartmentId = "ocid1.compartment.oc1..exampleuniqueid"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
# Unlike the other backends render() also takes the observed resources: the OCI
# Key can only be created against its vault's management endpoint, which exists
# once the vault is observed (see kms.k).
items = kms.render(_oxr, _ocds) + [kms.status(_oxr, _ocds)]
