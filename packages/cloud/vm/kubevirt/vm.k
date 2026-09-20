# vm (kubevirt) — Crossplane Composition logic (function-kcl module).
# The self-hosted backend: no cloud account, no VPC, no hyperscaler. Typed
# against the KubeVirt schema package, it renders one namespaced
# kubevirt.io/v1 VirtualMachine DIRECTLY — Crossplane v2 composes arbitrary
# namespaced resources, so there is no provider MR wrapper, no
# providerConfigRef and no managementPolicies (deletionPolicy is documented as
# ignored in-cluster: the VirtualMachine's lifetime follows the XR).
# Everything else that describes a cloud fabric goes the same way: zone, spot,
# resourceGroup and the whole network block have no in-cluster equivalent, so
# they are IGNORED rather than failing the render — a self-hosted machine is
# not a worse AWS instance, it is a different thing, and the XRD says so for
# each field. region survives as a free-form site label, exactly as the onprem
# cluster backend treats it.
import k8s.api.core.v1 as corev1
import kubevirt.models.v1.kubevirt_io_v1_virtual_machine as backend

# Logical device names inside the guest. `root` boots; `cloudinit` carries the
# NoCloud datasource disk.
root_disk = "root"
cloudinit_disk = "cloudinit"

# What a machine gets when the XR asks for no userData: cloud-init still needs
# a NoCloud disk to read the injected ssh keys out of, and an empty file is not
# a valid cloud-config.
default_user_data = "#cloud-config\n"

# Abstract size -> guest vCPU count and RAM in GiB, the shapes the XRD already
# documents for each rung. Exported like the cloud backends' machine_for: the
# ladder is part of this backend's contract, so it is asserted directly rather
# than reverse-engineered out of a rendered VM. spec.machineType overrides it
# wholesale.
machine_for = lambda size: str -> {str:int} {
    _shapes = {
        small = {cores = 2, memoryGb = 4}
        medium = {cores = 2, memoryGb = 8}
        large = {cores = 4, memoryGb = 16}
        xlarge = {cores = 8, memoryGb = 32}
    }
    _shapes[size]
}

# Abstract image -> containerdisk reference. The containerdisks org publishes
# one moving tag per release series (verified on quay.io: ubuntu 24.04, ubuntu
# 22.04, debian 12), which is the same "track the family" contract the cloud
# backends get from image families. spec.imageId overrides it verbatim.
image_for = lambda image: str -> str {
    {
        "ubuntu-24-04" = "quay.io/containerdisks/ubuntu:24.04"
        "ubuntu-22-04" = "quay.io/containerdisks/ubuntu:22.04"
        "debian-12" = "quay.io/containerdisks/debian:12"
    }[image]
}

# The DataVolume CDI imports the image into — and therefore the PVC name.
# Derived from the XR name so the disk is identifiable without reading the VM.
root_datavolume = lambda name: str -> str {
    "${name}-root"
}

# The Secret the ssh public key is published into for accessCredentials.
ssh_secret = lambda name: str -> str {
    "${name}-ssh"
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # An instance type owns the guest's CPU and memory outright, and KubeVirt
    # rejects a VirtualMachine that also sets domain.cpu/domain.memory — so
    # machineType suppresses the size ladder instead of layering over it.
    _instancetype = _spec?.machineType
    _machine = machine_for(_spec?.size or "small")
    _image = _spec?.imageId or image_for(_spec?.image or "ubuntu-24-04")
    _ssh = _spec?.sshKey

    # A bare containerDisk would lose all state on restart: its writable layer
    # is an ephemeral overlay in the virt-launcher pod, so the guest boots back
    # to the golden image every time. CDI imports the same image into a PVC
    # through this template instead, and the machine boots from that — which is
    # what makes diskGb mean anything.
    _root = {
        metadata.name = root_datavolume(_name)
        spec = {
            source.registry.url = "docker://${_image}"
            storage = {
                resources.requests.storage = "${_spec?.diskGb or 30}Gi"
                # Unset means the cluster's default StorageClass.
                if _spec?.storageClass:
                    storageClassName = _spec.storageClass
            }
        }
    }

    _items: [any] = [backend.VirtualMachine {
        # No namespace: Crossplane places composed namespaced resources in the
        # XR's own namespace. Naming the VM after the XR is what makes the
        # status id and console path deterministic before observation.
        metadata.name = _name
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _spec?.tags:
            metadata.labels = _spec.tags
        # The portable contract is "a machine you can ssh into", so the VM is
        # started and kept started rather than left Halted for someone to boot.
        spec.runStrategy = "Always"
        spec.dataVolumeTemplates = [_root]
        if _instancetype:
            spec.instancetype = {kind = "VirtualMachineClusterInstancetype", name = _instancetype}
        spec.template.spec = {
            domain = {
                if not _instancetype:
                    cpu.cores = _machine.cores
                    memory.guest = "${_machine.memoryGb}Gi"
                devices = {
                    disks = [
                        {name = root_disk, disk.bus = "virtio", bootOrder = 1}
                        {name = cloudinit_disk, disk.bus = "virtio"}
                    ]
                    # Pod networking, masqueraded: the machine reaches the
                    # cluster and the internet through the virt-launcher pod's
                    # own address, so it is exactly as reachable as a Pod.
                    interfaces = [{name = "default", masquerade = {}}]
                }
            }
            networks = [{name = "default", pod = {}}]
            volumes = [
                {name = root_disk, dataVolume.name = root_datavolume(_name)}
                # Always emitted, even with no userData: noCloud propagation
                # writes the ssh keys into this disk's cloud-init METADATA, so
                # the disk has to exist for a key to land anywhere. The two
                # features do not fight — the keys never touch userData — but a
                # userData that declares its own `users:` or
                # `ssh_authorized_keys:` block is authoritative for that user
                # and will shadow the injected key.
                {name = cloudinit_disk, cloudInitNoCloud.userData = _spec?.userData or default_user_data}
            ]
            if _ssh:
                accessCredentials = [{
                    sshPublicKey = {
                        source.secret.secretName = ssh_secret(_name)
                        propagationMethod.noCloud = {}
                    }
                }]
        }
    }]

    # The key material KubeVirt reads. virt-controller treats every value in
    # the Secret as an authorized_keys entry, so the key name is free — `key`
    # is what the status publishes.
    if _ssh:
        _items += [corev1.Secret {
            metadata = {
                name = ssh_secret(_name)
                annotations = {"krm.kcl.dev/composition-resource-name" = "ssh-key"}
            }
            stringData = {key = _ssh.publicKey}
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
# In-cluster identity is deterministic from the XR name, so name, id and the
# console path are reported immediately; readiness is not.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _st = (ocds["managed"]?.Resource?.status) if ("managed" in ocds) else Undefined
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "VirtualMachine"
        metadata.name = _name
        status = {
            provider = "kubevirt"
            # printableStatus is the VM controller's own verdict on the whole
            # start-up path (disk import, scheduling, boot); absent until the
            # first reconcile, which must read as not ready.
            ready = (_st?.printableStatus or "") == "Running"
            name = _name
            # No cloud account to scope a machine id to, so the namespaced
            # name IS the identity.
            id = "${_ns}/${_name}"
            "cloud-url" = "kubernetes://${_ns}/virtualmachine.kubevirt.io/${_name}"
            # privateIp/publicIp are deliberately absent: the guest's address
            # is reported on the VirtualMachineInstance, which this backend
            # does not compose, so there is nothing observed to read it from.
        }
    }
}
