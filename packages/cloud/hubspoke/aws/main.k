import .hub

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "NetworkHub"
    metadata.name = "example"
    spec = {
        region = "eu-west-1"
        topology = "isolated"
        spokes = [
            {
                name = "shared-services"
                network = "vpc-0aa11bb22cc33dd44"
                subnets = ["subnet-0aa1", "subnet-0aa2"]
                routeTableIds = ["rtb-0shared1"]
                shared = True
            }
            {
                name = "team-a"
                network = "vpc-0bb11bb22cc33dd44"
                subnets = ["subnet-0bb1", "subnet-0bb2"]
                routeTableIds = ["rtb-0teama1"]
            }
        ]
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = hub.render(_oxr) + [hub.status(_oxr, _ocds)]
