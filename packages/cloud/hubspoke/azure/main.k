import .hub

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "NetworkHub"
    metadata.name = "example"
    spec = {
        region = "westeurope"
        resourceGroup = "platform-rg"
        hubCidr = "10.200.0.0/23"
        spokes = [{
            name = "team-a"
            network = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/team-a-rg/providers/Microsoft.Network/virtualNetworks/team-a-vnet"
        }]
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = hub.render(_oxr, _ocds) + [hub.status(_oxr, _ocds)]
