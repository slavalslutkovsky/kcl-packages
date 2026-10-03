import .hub

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "NetworkHub"
    metadata.name = "example"
    spec = {
        region = "europe-west1"
        spokes = [
            {name = "shared-services", network = "projects/example/global/networks/shared-vpc", shared = True}
            {name = "team-a", network = "projects/example/global/networks/team-a-vpc"}
        ]
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = hub.render(_oxr, _ocds) + [hub.status(_oxr, _ocds)]
