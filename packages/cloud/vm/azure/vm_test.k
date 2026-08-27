import base64
import .vm

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_subnet = "/subscriptions/sub-1/resourceGroups/platform-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/vms"
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "VirtualMachine", metadata.name = "demo", spec = {
        region = "westeurope"
        resourceGroup = "platform-rg"
        sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAA key"}
        network.subnetId = _subnet
    } | _spec}
}

# ocds carrying an observed machine.
_vm_id = "/subscriptions/sub-1/resourceGroups/platform-rg/providers/Microsoft.Compute/virtualMachines/demo"
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    id = _vm_id
                    privateIpAddress = "10.1.0.5"
                    publicIpAddress = "20.1.2.3"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = vm.render(_build({}), {})
    assert len(items) == 2, "minimal spec must emit the machine and its NIC"
    assert items[0].apiVersion == "compute.azure.m.upbound.io/v1beta1", "wrong VM apiVersion"
    assert items[0].kind == "LinuxVirtualMachine", "wrong VM kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "VM name must be pinned to the XR name"
    assert items[0].spec.forProvider.location == "westeurope", "region -> location"
    assert items[0].spec.forProvider.resourceGroupName == "platform-rg", "resource group carried"
    assert items[1].kind == "NetworkInterface", "companion is the NIC"
}

# ---- render: size / machine type ----------------------------------------------
test_size_ladder = lambda {
    assert vm.machine_for("small") == "Standard_B2s", "small -> Standard_B2s"
    assert vm.machine_for("medium") == "Standard_D2s_v5", "medium -> Standard_D2s_v5"
    assert vm.machine_for("large") == "Standard_D4s_v5", "large -> Standard_D4s_v5"
    assert vm.machine_for("xlarge") == "Standard_D8s_v5", "xlarge -> Standard_D8s_v5"
    fp = vm.render(_build({size = "xlarge"}), {})[0].spec.forProvider
    assert fp.size == "Standard_D8s_v5", "size must map through the ladder"
}

test_machine_type_override = lambda {
    fp = vm.render(_build({size = "small", machineType = "Standard_F16s_v2"}), {})[0].spec.forProvider
    assert fp.size == "Standard_F16s_v2", "machineType must override the size mapping"
}

# ---- render: image / disk ---------------------------------------------------------
test_image_references = lambda {
    assert vm.image_ref("ubuntu-24-04") == {publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest"}, "ubuntu-24-04 reference"
    assert vm.image_ref("ubuntu-22-04") == {publisher = "Canonical", offer = "0001-com-ubuntu-server-jammy", sku = "22_04-lts-gen2", version = "latest"}, "ubuntu-22-04 reference"
    assert vm.image_ref("debian-12") == {publisher = "Debian", offer = "debian-12", sku = "12-gen2", version = "latest"}, "debian-12 reference"
    fp = vm.render(_build({image = "debian-12"}), {})[0].spec.forProvider
    assert fp.sourceImageReference.offer == "debian-12", "abstract image must map to the marketplace reference"
    _default = vm.render(_build({}), {})[0].spec.forProvider
    assert _default.sourceImageReference.offer == "ubuntu-24_04-lts", "image defaults to ubuntu-24-04"
}

test_image_id_override = lambda {
    fp = vm.render(_build({imageId = "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Compute/images/golden"}), {})[0].spec.forProvider
    assert fp.sourceImageId == "/subscriptions/sub-1/resourceGroups/rg/providers/Microsoft.Compute/images/golden", "imageId -> sourceImageId"
    assert not fp?.sourceImageReference, "an explicit imageId must not also set a marketplace reference"
}

test_disk = lambda {
    fp = vm.render(_build({diskGb = 50}), {})[0].spec.forProvider
    assert fp.osDisk.diskSizeGb == 50, "diskGb must size the OS disk"
    assert fp.osDisk.caching == "ReadWrite", "OS disk caching"
    assert fp.osDisk.storageAccountType == "Standard_LRS", "OS disk storage account type"
    _default = vm.render(_build({}), {})[0].spec.forProvider
    assert _default.osDisk.diskSizeGb == 30, "OS disk defaults to 30 GiB"
}

# ---- render: ssh key / user data ---------------------------------------------------
test_ssh_key = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert fp.adminUsername == "dev", "sshKey.user -> adminUsername"
    assert len(fp.adminSshKey) == 1, "exactly one admin SSH key"
    assert fp.adminSshKey[0].username == "dev", "key authorized for the admin user"
    assert fp.adminSshKey[0].publicKey == "ssh-ed25519 AAAA key", "public key carried"
}

test_user_data = lambda {
    fp = vm.render(_build({userData = "#!/bin/sh\necho hi"}), {})[0].spec.forProvider
    assert fp.userData == base64.encode("#!/bin/sh\necho hi"), "userData must be delivered base64-encoded"
    _plain = vm.render(_build({}), {})[0].spec.forProvider
    assert not _plain?.userData, "no user data unless asked"
}

# ---- render: spot / tags -------------------------------------------------------------
test_spot = lambda {
    fp = vm.render(_build({spot = True}), {})[0].spec.forProvider
    assert fp.priority == "Spot", "spot -> Spot priority"
    assert fp.evictionPolicy == "Deallocate", "spot machines deallocate on eviction"
    _plain = vm.render(_build({spot = False}), {})[0].spec.forProvider
    assert not _plain?.priority, "no priority unless spot is asked"
    assert not _plain?.evictionPolicy, "no eviction policy unless spot is asked"
}

test_tags = lambda {
    fp = vm.render(_build({
        tags = {team = "platform"}
    }), {})[0].spec.forProvider
    assert fp.tags == {team = "platform"}, "tags carried"
}

# ---- render: network wiring -----------------------------------------------------------
test_nic = lambda {
    items = vm.render(_build({}), {})
    nic = items[1]
    assert nic.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "nic", "NIC resource name"
    assert nic.metadata.annotations["crossplane.io/external-name"] == "demo-nic", "NIC Azure name pinned deterministically"
    assert nic.spec.forProvider.location == "westeurope", "NIC lives in the machine's region"
    assert nic.spec.forProvider.resourceGroupName == "platform-rg", "NIC lives in the machine's resource group"
    ipc = nic.spec.forProvider.ipConfiguration[0]
    assert ipc.name == "primary", "primary IP configuration"
    assert ipc.subnetId == _subnet, "subnetId carried"
    assert ipc.privateIpAddressAllocation == "Dynamic", "dynamic private address"
    assert not ipc?.publicIpAddressIdSelector, "no public IP binding unless asked"
    assert items[0].spec.forProvider.networkInterfaceIdsSelector.matchControllerRef == True, "VM binds to the composed NIC via selector"
}

test_public_ip_off = lambda {
    items = vm.render(_build({}), {})
    assert len(items) == 2, "no PublicIP unless network.publicIp is set"
}

test_public_ip_on = lambda {
    items = vm.render(_build({
        network = {subnetId = _subnet, publicIp = True}
    }), {})
    assert len(items) == 3, "publicIp must compose a PublicIP"
    pip = items[2]
    assert pip.kind == "PublicIP", "companion is a PublicIP"
    assert pip.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "public-ip", "PublicIP resource name"
    assert pip.metadata.annotations["crossplane.io/external-name"] == "demo-pip", "PublicIP Azure name pinned deterministically"
    assert pip.spec.forProvider.allocationMethod == "Static", "static allocation"
    assert pip.spec.forProvider.location == "westeurope", "PublicIP lives in the machine's region"
    assert pip.spec.forProvider.resourceGroupName == "platform-rg", "PublicIP lives in the machine's resource group"
    ipc = items[1].spec.forProvider.ipConfiguration[0]
    assert ipc.publicIpAddressIdSelector.matchControllerRef == True, "NIC binds to the composed PublicIP via selector"
}

# ---- render: deletion policy ------------------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = vm.render(_build({deletionPolicy = "Orphan", network = {subnetId = _subnet, publicIp = True}}), {})
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the machine"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the NIC"
    assert _orphaned[2].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the public IP"
    _deleted = vm.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = vm.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "VirtualMachine", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "azure", "provider must be azure"
    assert dxr.status.name == "demo", "name is the XR name"
    assert not dxr.status?.id, "no id before the machine exists"
    assert not dxr.status?["cloud-url"], "no portal URL before the machine exists"
}

test_status_observed = lambda {
    dxr = vm.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed machine id must mark it ready"
    assert dxr.status.privateIp == "10.1.0.5", "private IP must be surfaced"
    assert dxr.status.publicIp == "20.1.2.3", "public IP must be surfaced"
    assert dxr.status.id == _vm_id, "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://portal.azure.com/#@/resource${_vm_id}", "cloud-url must point at the machine in the portal"
}

test_status_observed_no_public_ip = lambda {
    _priv = {
        managed.Resource.status.atProvider = {id = _vm_id, privateIpAddress = "10.1.0.9"}
    }
    dxr = vm.status(_build({}), _priv)
    assert dxr.status.ready == True, "id alone marks the machine ready"
    assert dxr.status.privateIp == "10.1.0.9", "private IP surfaced"
    assert not dxr.status?.publicIp, "no public IP unless Azure reports one"
}
