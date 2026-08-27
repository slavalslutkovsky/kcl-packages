import .vm

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "VirtualMachine", metadata.name = "example", spec = {
    region = "westeurope"
    resourceGroup = "example-rg"
    sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample example"}
    network.subnetId = "/subscriptions/0b1f6471-1bf0-4dda-aec3-111122223333/resourceGroups/example-rg/providers/Microsoft.Network/virtualNetworks/example-vnet/subnets/vms"
}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = vm.render(_oxr, _ocds) + [vm.status(_oxr, _ocds)]
