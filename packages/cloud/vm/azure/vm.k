# vm (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-compute and azure-network schema packages. The
# portable VirtualMachine maps onto a LinuxVirtualMachine plus a composed
# NetworkInterface (and a PublicIP when network.publicIp is set). Azure needs
# spec.resourceGroup and a full network.subnetId (the NIC cannot exist without
# one), and Linux VMs disable password logins, so spec.sshKey is REQUIRED.
# The provider schema exposes customData only as a Kubernetes secret ref, so
# spec.userData is delivered base64-encoded through the VM's userData field
# (readable from the Azure Instance Metadata Service) instead.
# network.securityGroupIds is AWS-only and fails the render instead of
# silently launching a machine with different reachability than asked for.
import base64
import azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_linux_virtual_machine as vmachine
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface as netif
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_public_ip as publicip

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract size -> Azure VM size. spec.machineType overrides.
machine_for = lambda size: str -> str {
    {
        small = "Standard_B2s"
        medium = "Standard_D2s_v5"
        large = "Standard_D4s_v5"
        xlarge = "Standard_D8s_v5"
    }[size]
}

# Abstract image -> marketplace source image reference. spec.imageId overrides.
image_ref = lambda image: str -> {str:str} {
    _refs = {
        "ubuntu-24-04" = {publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest"}
        "ubuntu-22-04" = {publisher = "Canonical", offer = "0001-com-ubuntu-server-jammy", sku = "22_04-lts-gen2", version = "latest"}
        "debian-12" = {publisher = "Debian", offer = "debian-12", sku = "12-gen2", version = "latest"}
    }
    _refs[image]
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _net = _spec?.network

    assert _spec?.region, "vm-azure: spec.region is required (the Azure location of the machine)"
    assert _spec?.resourceGroup, "vm-azure: spec.resourceGroup is required (the Resource Group the machine, NIC and public IP live in)"
    assert _spec?.sshKey, "vm-azure: spec.sshKey is required — Azure Linux VMs disable password authentication"
    assert _net?.subnetId, "vm-azure: network.subnetId (a full subnet resource ID) is required — the composed NetworkInterface cannot exist without one"
    assert not _net?.securityGroupIds, "vm-azure: network.securityGroupIds is AWS-only — attach an NSG to the subnet instead"

    # 1) The machine. external-name pins the Azure VM name to the XR name.
    # The NIC is bound via selector, so no observed state is needed.
    _items: [any] = [vmachine.LinuxVirtualMachine {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.size = _spec?.machineType or machine_for(_spec?.size or "small")
        spec.forProvider.adminUsername = _spec.sshKey.user
        spec.forProvider.adminSshKey = [{
            username = _spec.sshKey.user
            publicKey = _spec.sshKey.publicKey
        }]
        spec.forProvider.networkInterfaceIdsSelector.matchControllerRef = True
        spec.forProvider.osDisk = {
            caching = "ReadWrite"
            storageAccountType = "Standard_LRS"
            diskSizeGb = _spec?.diskGb or 30
        }
        if _spec?.imageId:
            spec.forProvider.sourceImageId = _spec.imageId
        else:
            spec.forProvider.sourceImageReference = image_ref(_spec?.image or "ubuntu-24-04")
        if _spec?.userData:
            spec.forProvider.userData = base64.encode(_spec.userData)
        if _spec?.spot:
            spec.forProvider.priority = "Spot"
            spec.forProvider.evictionPolicy = "Deallocate"
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) The primary interface, bound to the subnet by ID and to the composed
    # PublicIP (when requested) via selector.
    _items += [netif.NetworkInterface {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "nic"
            "crossplane.io/external-name" = "${_name}-nic"
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.ipConfiguration = [{
            name = "primary"
            subnetId = _net.subnetId
            privateIpAddressAllocation = "Dynamic"
            if _net?.publicIp:
                publicIpAddressIdSelector.matchControllerRef = True
        }]
    }]

    # 3) The public address, only when asked for.
    if _net?.publicIp:
        _items += [publicip.PublicIP {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "public-ip"
                "crossplane.io/external-name" = "${_name}-pip"
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.location = _spec.region
            spec.forProvider.resourceGroupName = _spec.resourceGroup
            spec.forProvider.allocationMethod = "Static"
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "VirtualMachine"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            ready = (_at?.id or "") != ""
            name = oxr.metadata.name
            if _at:
                if _at?.privateIpAddress:
                    privateIp = _at.privateIpAddress
                if _at?.publicIpAddress:
                    publicIp = _at.publicIpAddress
                if _at?.id:
                    id = _at.id
                    "cloud-url" = "https://portal.azure.com/#@/resource${_at.id}"
        }
    }
}
