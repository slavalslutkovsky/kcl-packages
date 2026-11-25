# instancetemplate (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-compute and azure-network schema packages.
#
# Azure has no launch-template object for standalone VMs (the closest native
# constructs — scale-set models and Template Specs — are not a template a
# single VM can be created from), so this backend's template is LOGICAL: the
# XR itself is the template, nothing template-shaped is composed in Azure, and
# every spec.instances entry is rendered from its fields into the same set of
# resources the vm-azure backend composes for one machine:
#   LinuxVirtualMachine + NetworkInterface (+ PublicIP) (+ customData Secret).
#
# Several machines live under one XR, so `matchControllerRef` alone would bind
# a VM to EVERY NIC this XR controls. Each NIC / PublicIP therefore carries an
# instance label and the selectors match on it as well.
#
# Requirements mirror vm-azure: spec.resourceGroup, a full network.subnetId
# and spec.sshKey (Linux VMs disable password logins) are required, and
# network.securityGroupIds (AWS-only) fails the render. userData becomes
# customData, handed over through a Secret per instance.
import base64
import azure_compute.models.v1beta1.compute_azurem_upbound_io_v1beta1_linux_virtual_machine as vmachine
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface as netif
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_public_ip as publicip

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Label tying a NIC / PublicIP to the machine whose selector must pick it.
instance_label = "cloud.example.org/instance"

# Composition resource names, one set per instance.
vm_key = lambda name: str -> str {
    "vm-${name}"
}
nic_key = lambda name: str -> str {
    "nic-${name}"
}
public_ip_key = lambda name: str -> str {
    "public-ip-${name}"
}
custom_data_key = lambda name: str -> str {
    "custom-data-${name}"
}

# Provider-side machine name of one instance: "<template>-<instance>".
instance_name = lambda template: str, name: str -> str {
    "${template}-${name}"
}

# Where an instance's customData payload is handed to the provider. The Secret
# lives in the XR's namespace, which is also the namespaced MR's.
custom_data_secret_key = "customData"
custom_data_secret = lambda full: str -> str {
    "${full}-custom-data"
}

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

# Every resource of one machine stamped from the template.
machine = lambda oxr, inst, mp -> [any] {
    _spec = oxr.spec
    _net = _spec.network
    _full = instance_name(oxr.metadata.name, inst.name)
    _sel = {matchControllerRef = True, matchLabels = {"${instance_label}" = _full}}
    _user_data = inst?.userData or _spec?.userData
    _tags = (_spec?.tags or {}) | (inst?.tags or {})

    # 1) The machine. external-name pins the Azure VM name.
    _items: [any] = [vmachine.LinuxVirtualMachine {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = vm_key(inst.name)
            "crossplane.io/external-name" = _full
        }
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.size = _spec?.machineType or machine_for(_spec?.size or "small")
        spec.forProvider.adminUsername = _spec.sshKey.user
        spec.forProvider.adminSshKey = [{
            username = _spec.sshKey.user
            publicKey = _spec.sshKey.publicKey
        }]
        spec.forProvider.networkInterfaceIdsSelector = _sel
        spec.forProvider.osDisk = {
            caching = "ReadWrite"
            storageAccountType = "Standard_LRS"
            diskSizeGb = _spec?.diskGb or 30
        }
        if _spec?.imageId:
            spec.forProvider.sourceImageId = _spec.imageId
        else:
            spec.forProvider.sourceImageReference = image_ref(_spec?.image or "ubuntu-24-04")
        if _user_data:
            spec.forProvider.customDataSecretRef = {name = custom_data_secret(_full), key = custom_data_secret_key}
        if _spec?.spot:
            spec.forProvider.priority = "Spot"
            spec.forProvider.evictionPolicy = "Deallocate"
        if _tags:
            spec.forProvider.tags = _tags
    }]

    # 2) The primary interface, bound to the subnet by ID and to this
    # machine's PublicIP (when requested) via the labelled selector.
    _items += [netif.NetworkInterface {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = nic_key(inst.name)
            "crossplane.io/external-name" = "${_full}-nic"
        }
        metadata.labels = {"${instance_label}" = _full}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.ipConfiguration = [{
            name = "primary"
            subnetId = _net.subnetId
            privateIpAddressAllocation = "Dynamic"
            if _net?.publicIp:
                publicIpAddressIdSelector = _sel
        }]
    }]

    # 3) The public address, only when asked for.
    if _net?.publicIp:
        _items += [publicip.PublicIP {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = public_ip_key(inst.name)
                "crossplane.io/external-name" = "${_full}-pip"
            }
            metadata.labels = {"${instance_label}" = _full}
            if mp:
                spec.managementPolicies = mp
            spec.forProvider.location = _spec.region
            spec.forProvider.resourceGroupName = _spec.resourceGroup
            spec.forProvider.allocationMethod = "Static"
        }]

    # 4) The customData payload. Upjet reads the decoded Secret value as the
    # field itself, and the field is base64 — hence the double encoding. A
    # Secret has no Ready condition, so it is declared ready outright.
    if _user_data:
        _items += [{
            apiVersion = "v1"
            kind = "Secret"
            metadata = {
                name = custom_data_secret(_full)
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = custom_data_key(inst.name)
                    "krm.kcl.dev/ready" = "True"
                }
            }
            type = "Opaque"
            data = {"${custom_data_secret_key}" = base64.encode(base64.encode(_user_data))}
        }]

    _items
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _net = _spec?.network
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _insts = _spec?.instances or []

    assert _spec?.region, "instancetemplate-azure: spec.region is required (the Azure location of the machines)"
    assert _spec?.resourceGroup, "instancetemplate-azure: spec.resourceGroup is required (the Resource Group the machines, NICs and public IPs live in)"
    assert _spec?.sshKey, "instancetemplate-azure: spec.sshKey is required — Azure Linux VMs disable password authentication"
    assert _net?.subnetId, "instancetemplate-azure: network.subnetId (a full subnet resource ID) is required — the composed NetworkInterfaces cannot exist without one"
    assert not _net?.securityGroupIds, "instancetemplate-azure: network.securityGroupIds is AWS-only — attach an NSG to the subnet instead"
    assert len({i.name = True for i in _insts}) == len(_insts), "instancetemplate-azure: spec.instances names must be unique"

    sum([machine(oxr, i, _mp) for i in _insts], [])
}

# Observed state of one instance, as reported in status.instances.
instance_status = lambda oxr, ocds, inst {
    _key = vm_key(inst.name)
    _at = (ocds[_key]?.Resource?.status?.atProvider) if _key in ocds else Undefined
    {
        name = instance_name(oxr.metadata.name, inst.name)
        ready = (_at?.id or "") != ""
        if _at?.id:
            id = _at.id
        if _at?.privateIpAddress:
            privateIp = _at.privateIpAddress
        if _at?.publicIpAddress:
            publicIp = _at.publicIpAddress
    }
}

# Build the desired composite carrying observed status back to the XR. The
# template is logical, so there is no templateName/templateId/cloud-url: it
# "exists" as soon as the XR does, and readiness is the instances'.
status = lambda oxr, ocds {
    _insts = [instance_status(oxr, ocds, i) for i in oxr.spec?.instances or []]
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "InstanceTemplate"
        metadata.name = oxr.metadata.name
        status = {
            provider = "azure"
            ready = all i in _insts {
                i.ready
            }
            instances = _insts
        }
    }
}
