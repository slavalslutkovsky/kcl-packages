# instancetemplate (kubevirt) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend, typed against the KubeVirt schema package. KubeVirt's
# native template objects are the instancetype API: the template's SHAPE lives
# in a namespaced VirtualMachineInstancetype (guest vCPUs + memory) and its
# DEVICE defaults in a VirtualMachinePreference (virtio disks and NICs), both
# named after the XR. Every spec.instances entry is a kubevirt.io/v1
# VirtualMachine that references the two by name, so changing the template's
# size reshapes every machine on its next start.
#
# spec.machineType names an existing VirtualMachineClusterInstancetype instead:
# the machines reference it and no namespaced instancetype is composed.
#
# Image, root disk, cloud-init and the ssh key are not instancetype fields;
# they are stamped into each VirtualMachine exactly as the vm-kubevirt backend
# does (CDI-imported root DataVolume, NoCloud disk, accessCredentials).
#
# KubeVirt's admission webhook rejects a VirtualMachine whose instancetype or
# preference does not exist yet, so the machines are composed from the
# reconcile after both are observed.
#
# Like vm-kubevirt, every field describing a cloud fabric (zone, spot,
# network, resourceGroup, deletionPolicy) is IGNORED rather than failing the
# render, and region survives only as a free-form site label.
import k8s.api.core.v1 as corev1
import kubevirt.models.v1.kubevirt_io_v1_virtual_machine as backend
import kubevirt.models.v1beta1.instancetype_kubevirt_io_v1beta1_virtual_machine_instancetype as instancetype
import kubevirt.models.v1beta1.instancetype_kubevirt_io_v1beta1_virtual_machine_preference as preference

# Composition resource names. One per instance, keyed by the instance's name.
instancetype_key = "instancetype"
preference_key = "preference"
ssh_key = "ssh-key"
instance_key = lambda name: str -> str {
    "instance-${name}"
}

# Machine name of one instance: "<template>-<instance>".
instance_name = lambda template: str, name: str -> str {
    "${template}-${name}"
}

# Logical device names inside the guest. `root` boots; `cloudinit` carries the
# NoCloud datasource disk.
root_disk = "root"
cloudinit_disk = "cloudinit"

# What a machine gets when no userData is asked for: cloud-init still needs a
# NoCloud disk to read the injected ssh keys out of.
default_user_data = "#cloud-config\n"

# Abstract size -> guest vCPU count and RAM in GiB (same ladder as vm-kubevirt).
machine_for = lambda size: str -> {str:int} {
    _shapes = {
        small = {cores = 2, memoryGb = 4}
        medium = {cores = 2, memoryGb = 8}
        large = {cores = 4, memoryGb = 16}
        xlarge = {cores = 8, memoryGb = 32}
    }
    _shapes[size]
}

# Abstract image -> containerdisk reference. spec.imageId overrides verbatim.
image_for = lambda image: str -> str {
    {
        "ubuntu-24-04" = "quay.io/containerdisks/ubuntu:24.04"
        "ubuntu-22-04" = "quay.io/containerdisks/ubuntu:22.04"
        "debian-12" = "quay.io/containerdisks/debian:12"
    }[image]
}

# The DataVolume CDI imports the image into for one machine.
root_datavolume = lambda full: str -> str {
    "${full}-root"
}

# The Secret every machine's ssh accessCredentials read from.
ssh_secret = lambda name: str -> str {
    "${name}-ssh"
}

# The instancetype reference every machine carries.
instancetype_ref = lambda oxr -> {str:str} {
    _mt = oxr.spec?.machineType
    {kind = "VirtualMachineClusterInstancetype", name = _mt} if _mt else {kind = "VirtualMachineInstancetype", name = oxr.metadata.name}
}

# True once the objects the machines reference have been observed.
template_observed = lambda oxr, ocds -> bool {
    preference_key in ocds and (bool(oxr.spec?.machineType) or instancetype_key in ocds)
}

# One machine created from the template.
machine = lambda oxr, inst {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _full = instance_name(_name, inst.name)
    _image = _spec?.imageId or image_for(_spec?.image or "ubuntu-24-04")
    _labels = (_spec?.tags or {}) | (inst?.tags or {})

    # CDI imports the image into a PVC through this template, which is what
    # makes the root disk survive a restart (a bare containerDisk would not).
    _root = {
        metadata.name = root_datavolume(_full)
        spec = {
            source.registry.url = "docker://${_image}"
            storage = {
                resources.requests.storage = "${_spec?.diskGb or 30}Gi"
                if _spec?.storageClass:
                    storageClassName = _spec.storageClass
            }
        }
    }

    backend.VirtualMachine {
        # No namespace: Crossplane places composed namespaced resources in the
        # XR's own namespace.
        metadata.name = _full
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = instance_key(inst.name)}
        if _labels:
            metadata.labels = _labels
        spec.runStrategy = "Always"
        spec.instancetype = instancetype_ref(oxr)
        spec.preference = {kind = "VirtualMachinePreference", name = _name}
        spec.dataVolumeTemplates = [_root]
        spec.template.spec = {
            # No cpu/memory and no disk/interface models: the instancetype owns
            # the former outright (KubeVirt rejects a VM that sets both) and the
            # preference fills in the latter.
            domain.devices = {
                disks = [
                    {name = root_disk, disk = {}, bootOrder = 1}
                    {name = cloudinit_disk, disk = {}}
                ]
                interfaces = [{name = "default", masquerade = {}}]
            }
            networks = [{name = "default", pod = {}}]
            volumes = [
                {name = root_disk, dataVolume.name = root_datavolume(_full)}
                {name = cloudinit_disk, cloudInitNoCloud.userData = inst?.userData or _spec?.userData or default_user_data}
            ]
            if _spec?.sshKey:
                accessCredentials = [{
                    sshPublicKey = {
                        source.secret.secretName = ssh_secret(_name)
                        propagationMethod.noCloud = {}
                    }
                }]
        }
    }
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _insts = _spec?.instances or []
    _shape = machine_for(_spec?.size or "small")

    assert len({i.name = True for i in _insts}) == len(_insts), "instancetemplate-kubevirt: spec.instances names must be unique"

    _items: [any] = []

    # 1) The shape — unless machineType points at a cluster-wide instancetype.
    if not _spec?.machineType:
        _items += [instancetype.VirtualMachineInstancetype {
            metadata.name = _name
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = instancetype_key}
            spec.cpu.guest = _shape.cores
            spec.memory.guest = "${_shape.memoryGb}Gi"
        }]

    # 2) Device defaults: paravirtualized disks and NICs, as vm-kubevirt
    # hard-codes per device.
    _items += [preference.VirtualMachinePreference {
        metadata.name = _name
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = preference_key}
        spec.devices = {
            preferredDiskBus = "virtio"
            preferredInterfaceModel = "virtio"
        }
    }]

    # 3) The shared key material. virt-controller treats every value as an
    # authorized_keys entry.
    if _spec?.sshKey:
        _items += [corev1.Secret {
            metadata = {
                name = ssh_secret(_name)
                annotations = {"krm.kcl.dev/composition-resource-name" = ssh_key}
            }
            stringData = {key = _spec.sshKey.publicKey}
        }]

    # 4) The machines, once what they reference exists.
    if template_observed(oxr, ocds):
        _items += [machine(oxr, i) for i in _insts]

    _items
}

# Observed state of one instance, as reported in status.instances. The guest
# IP lives on the VirtualMachineInstance, which is not composed, so none is
# reported — same as vm-kubevirt.
instance_status = lambda oxr, ocds, inst {
    _key = instance_key(inst.name)
    _full = instance_name(oxr.metadata.name, inst.name)
    _st = (ocds[_key]?.Resource?.status) if _key in ocds else Undefined
    {
        name = _full
        ready = (_st?.printableStatus or "") == "Running"
        id = "${oxr.metadata?.namespace or 'default'}/${_full}"
    }
}

# Build the desired composite carrying observed status back to the XR. The
# template's identity is deterministic from the XR (both objects are named
# after it), so it is reported immediately; readiness is not. The console path
# points at the composed instancetype, or at the preference when machineType
# delegates the shape to a cluster instancetype.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _insts = [instance_status(oxr, ocds, i) for i in oxr.spec?.instances or []]
    _kind = "virtualmachinepreference" if oxr.spec?.machineType else "virtualmachineinstancetype"
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "InstanceTemplate"
        metadata.name = _name
        status = {
            provider = "kubevirt"
            ready = template_observed(oxr, ocds) and all i in _insts {
                i.ready
            }
            templateName = _name
            templateId = "${_ns}/${_name}"
            "cloud-url" = "kubernetes://${_ns}/${_kind}.instancetype.kubevirt.io/${_name}"
            instances = _insts
        }
    }
}
