import .organization

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "Organization"
    metadata.name = "example"
    spec = {
        orgId = "3c1f9d2e-7b4a-4a1d-9f83-6ad2e0b5c714"
        folders = [{name = "platform"}, {name = "workloads"}, {name = "prod", parent = "workloads"}]
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = organization.render(_oxr) + [organization.status(_oxr, _ocds)]
