import .workload_identity as wi

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "WorkloadIdentity"
    metadata = {name = "example", namespace = "default"}
    spec = {
        serviceAccount = {name = "example"}
        cluster.project = "my-project"
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = wi.render(_oxr, _ocds) + [wi.status(_oxr, _ocds)]
