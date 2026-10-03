import .vm

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec, _ns: str = "default" {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "VirtualMachine", metadata = {name = "demo", namespace = _ns}, spec = {region = "in-cluster"} | _spec}
}

# The VirtualMachine spec from a render().
_vs = lambda _spec {
    vm.render(_build(_spec))[0].spec
}

# The VirtualMachineInstance template spec — where the guest is described.
_ts = lambda _spec {
    vm.render(_build(_spec))[0].spec.template.spec
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = vm.render(_build({}))
    assert len(items) == 1, "a machine with no sshKey must emit exactly one VirtualMachine"
    assert items[0].apiVersion == "kubevirt.io/v1", "must be the KubeVirt CRD, composed directly"
    assert items[0].kind == "VirtualMachine", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.name == "demo", "the VM must be named after the XR — the status id and console path are derived from it"
    assert items[0].metadata?.namespace == Undefined, "no namespace: Crossplane places the VM in the XR's namespace"
    assert items[0].spec.runStrategy == "Always", "the portable contract is a running machine, not a Halted one"
}

# ---- render: size / instance type -------------------------------------------
test_size_ladder = lambda {
    assert vm.machine_for("small") == {cores = 2, memoryGb = 4}, "small -> 2 vCPU / 4Gi"
    assert vm.machine_for("medium") == {cores = 2, memoryGb = 8}, "medium -> 2 vCPU / 8Gi"
    assert vm.machine_for("large") == {cores = 4, memoryGb = 16}, "large -> 4 vCPU / 16Gi"
    assert vm.machine_for("xlarge") == {cores = 8, memoryGb = 32}, "xlarge -> 8 vCPU / 32Gi"
}

test_size_maps_onto_the_domain = lambda {
    _d = _ts({})?.domain
    assert _d.cpu.cores == 2, "size defaults to small -> 2 cores"
    assert _d.memory.guest == "4Gi", "size defaults to small -> 4Gi of guest memory"
    _large = _ts({size = "large"}).domain
    assert _large.cpu.cores == 4, "size must map through the ladder to domain.cpu.cores"
    assert _large.memory.guest == "16Gi", "size must map through the ladder to domain.memory.guest"
}

# KubeVirt rejects a VM that sets both an instance type and domain cpu/memory:
# the instance type owns them.
test_machine_type_is_an_instancetype = lambda {
    _s = _vs({size = "xlarge", machineType = "u1.2xlarge"})
    assert _s.instancetype.kind == "VirtualMachineClusterInstancetype", "machineType must reference a cluster-scoped instance type"
    assert _s.instancetype.name == "u1.2xlarge", "machineType must be the instance type name"
    assert _s.template.spec.domain?.cpu == Undefined, "an instance type owns the guest CPU — domain.cpu must be omitted"
    assert _s.template.spec.domain?.memory == Undefined, "an instance type owns the guest memory — domain.memory must be omitted"
    assert _vs({})?.instancetype == Undefined, "no instance type unless machineType asks for one"
}

# ---- render: image / root disk ----------------------------------------------
test_image_containerdisks = lambda {
    assert vm.image_for("ubuntu-24-04") == "quay.io/containerdisks/ubuntu:24.04", "ubuntu-24-04 containerdisk"
    assert vm.image_for("ubuntu-22-04") == "quay.io/containerdisks/ubuntu:22.04", "ubuntu-22-04 containerdisk"
    assert vm.image_for("debian-12") == "quay.io/containerdisks/debian:12", "debian-12 containerdisk"
}

# The root disk is a CDI import into a PVC, not a containerDisk: a bare
# containerDisk overlay is thrown away on every restart.
test_root_data_volume = lambda {
    _dvs = _vs({}).dataVolumeTemplates
    assert len(_dvs) == 1, "exactly one DataVolume — the root disk"
    assert _dvs[0].metadata.name == vm.root_datavolume("demo"), "the DataVolume must be named after the XR"
    assert _dvs[0].spec.source.registry.url == "docker://quay.io/containerdisks/ubuntu:24.04", "image defaults to ubuntu-24-04, imported from the registry"
    assert _dvs[0].spec.storage.resources.requests.storage == "30Gi", "diskGb defaults to a 30Gi PVC"
    assert _dvs[0].spec.storage?.storageClassName == Undefined, "no storageClass -> the cluster default StorageClass"
}

test_root_data_volume_sizing = lambda {
    _dv = _vs({diskGb = 50, storageClass = "local-path"}).dataVolumeTemplates[0]
    assert _dv.spec.storage.resources.requests.storage == "50Gi", "diskGb must size the root PVC"
    assert _dv.spec.storage.storageClassName == "local-path", "storageClass must pick the PVC's StorageClass"
}

test_image_mapping_and_override = lambda {
    _debian = _vs({image = "debian-12"}).dataVolumeTemplates[0]
    assert _debian.spec.source.registry.url == "docker://quay.io/containerdisks/debian:12", "abstract image must map to the containerdisk"
    _pinned = _vs({image = "debian-12", imageId = "registry.internal/golden/ubuntu:1.2.3"}).dataVolumeTemplates[0]
    assert _pinned.spec.source.registry.url == "docker://registry.internal/golden/ubuntu:1.2.3", "imageId must override the abstract image verbatim"
}

# The machine boots off the imported PVC, so the disk device and the volume
# must agree on the logical name.
test_boot_disk_wiring = lambda {
    _t = _ts({})
    _boot = [_d for _d in _t.domain.devices.disks if _d.bootOrder == 1]
    assert len(_boot) == 1, "exactly one disk may claim the boot order"
    assert _boot[0].name == vm.root_disk, "the root disk must be the boot device"
    _vols = [_v for _v in _t.volumes if _v.name == vm.root_disk]
    assert len(_vols) == 1, "the boot disk needs exactly one matching volume"
    assert _vols[0].dataVolume.name == vm.root_datavolume("demo"), "the boot volume must reference the imported DataVolume"
}

# ---- render: networking -----------------------------------------------------

# Pod networking only: masquerade puts the guest behind the virt-launcher
# pod's own address.
test_pod_networking = lambda {
    _t = _ts({})
    _ifs = _t.domain.devices.interfaces
    assert len(_ifs) == 1, "pod networking only -> exactly one interface"
    assert _ifs[0].name == "default", "the interface must be named after the network it attaches to"
    assert _ifs[0].masquerade == {}, "the interface must be masqueraded, not bridged to a fabric that does not exist here"
    assert len(_t.networks) == 1, "pod networking only -> exactly one network"
    assert _t.networks[0].name == "default", "the network name must match the interface's"
    assert _t.networks[0]?.pod != Undefined, "the network must be the stock pod network"
    assert _t.networks[0]?.multus == Undefined, "no multus attachment — there is no separate fabric to bridge onto"
}

# ---- render: ssh key / cloud-init -------------------------------------------

# noCloud propagation writes the keys into the cloud-init METADATA of the
# NoCloud disk, so the disk must exist even when nothing asked for userData.
test_cloud_init_default = lambda {
    _cis = [_v for _v in _ts({}).volumes if _v.name == vm.cloudinit_disk]
    assert len(_cis) == 1, "a NoCloud disk must always be present for key propagation"
    assert _cis[0].cloudInitNoCloud.userData == vm.default_user_data, "no userData -> a minimal #cloud-config, which is still a valid one"
}

test_cloud_init_user_data = lambda {
    _ud = "#cloud-config\npackage_update: true\n"
    _cis = [_v for _v in _ts({userData = _ud}).volumes if _v.name == vm.cloudinit_disk]
    assert _cis[0].cloudInitNoCloud.userData == _ud, "userData must be carried verbatim"
}

test_ssh_key = lambda {
    _items = vm.render(_build({
        sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAA key"}
    }))
    assert len(_items) == 2, "sshKey must add the key Secret alongside the VM"
    _sec = _items[1]
    assert _sec.apiVersion == "v1" and _sec.kind == "Secret", "the key must be published as a core Secret"
    assert _sec.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "ssh-key", "the Secret needs its own resource name"
    assert _sec.metadata.name == vm.ssh_secret("demo"), "the Secret must be named after the XR"
    assert _sec.stringData == {key = "ssh-ed25519 AAAA key"}, "the public key must be published under `key`"

    _ac = _items[0].spec.template.spec.accessCredentials
    assert len(_ac) == 1, "one access credential — the ssh key"
    assert _ac[0].sshPublicKey.source.secret.secretName == vm.ssh_secret("demo"), "accessCredentials must read the composed Secret"
    assert _ac[0].sshPublicKey.propagationMethod.noCloud == {}, "propagation must go through the NoCloud datasource, not the guest agent"
}

test_no_ssh_key = lambda {
    assert _ts({})?.accessCredentials == Undefined, "no accessCredentials block unless a key is given"
}

# ---- render: labels ---------------------------------------------------------
test_labels = lambda {
    assert vm.render(_build({
        tags = {team = "platform"}
    }))[0].metadata.labels == {team = "platform"}, "tags -> labels on the VirtualMachine"
    assert vm.render(_build({}))[0].metadata?.labels == Undefined, "no labels unless asked for"
}

# ---- render: cloud-only fields ----------------------------------------------

# zone, spot, the whole network block, resourceGroup and deletionPolicy all
# describe a cloud fabric this backend does not have. The XRD documents them as
# ignored in-cluster, so their presence must not change the render — and
# deletionPolicy in particular must not grow managementPolicies, which the
# KubeVirt CRD has no field for.
test_cloud_only_fields_ignored = lambda {
    _plain = vm.render(_build({}))
    _cloudy = vm.render(_build({
        zone = "us-central1-a"
        spot = True
        resourceGroup = "platform-rg"
        deletionPolicy = "Orphan"
        network = {subnetId = "subnet-0123456789abcdef0", securityGroupIds = ["sg-0123456789abcdef0"], publicIp = True}
    }))
    assert _plain == _cloudy, "zone, spot, network.*, resourceGroup and deletionPolicy must be ignored in-cluster"
}

# ---- status -----------------------------------------------------------------

# Identity is derived from the XR, so it is known before the VM converges —
# but readiness is not.
test_status_pre_creation = lambda {
    dxr = vm.status(_build({}, "team-a"), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "VirtualMachine", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "an unobserved VM must not be ready"
    assert dxr.status.provider == "kubevirt", "provider must be kubevirt"
    assert dxr.status.name == "demo", "name is the VM name"
    assert dxr.status.id == "team-a/demo", "id is the namespaced name — there is no cloud id to scope"
    assert dxr.status["cloud-url"] == "kubernetes://team-a/virtualmachine.kubevirt.io/demo", "cloud-url must locate the VirtualMachine"
    assert dxr.status?.privateIp == Undefined, "the guest address lives on the VMI, which this backend does not compose"
    assert dxr.status?.publicIp == Undefined, "no public address in-cluster — expose the machine with a Service"
}

test_status_running = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {printableStatus = "Running", created = True, ready = True}
            }
        }
    }
    dxr = vm.status(_build({}), ocds)
    assert dxr.status.ready == True, "a Running VM must make the composite ready"
}

# Every other printableStatus — Provisioning while CDI imports the disk,
# Starting, ErrorUnschedulable — is not a running machine.
test_status_not_running = lambda {
    _provisioning = {
        managed.Resource.status = {printableStatus = "Provisioning", created = True}
    }
    assert vm.status(_build({}), _provisioning).status.ready == False, "a VM still importing its disk must not be ready"
    _stopped = {
        managed.Resource.status = {printableStatus = "Stopped"}
    }
    assert vm.status(_build({}), _stopped).status.ready == False, "a Stopped VM must not be ready"
    _empty = {
        managed.Resource = {}
    }
    assert vm.status(_build({}), _empty).status.ready == False, "an observed VM with no status yet must not be ready"
}
