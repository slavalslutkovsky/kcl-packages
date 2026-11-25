import .tpl

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "agents", namespace = "lab"}, spec = {region = "in-cluster"} | _spec}
}

# ocds with the template objects observed — machines are composed from here on.
_obs = {instancetype.Resource = {}, preference.Resource = {}}

_by_key = lambda items, key: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == key]
}

_vm = lambda _spec, name: str {
    _by_key(tpl.render(_build(_spec), _obs), "instance-${name}")[0]
}

# ---- render: template objects ------------------------------------------------
test_template_objects = lambda {
    items = tpl.render(_build({size = "large"}), {})
    assert len(items) == 2, "instancetype + preference, nothing else without sshKey"
    it = _by_key(items, "instancetype")[0]
    assert it.apiVersion == "instancetype.kubevirt.io/v1beta1", "instancetype API"
    assert it.kind == "VirtualMachineInstancetype", "namespaced instancetype"
    assert it.metadata.name == "agents", "named after the XR"
    assert it.spec.cpu.guest == 4, "large -> 4 vCPU"
    assert it.spec.memory.guest == "16Gi", "large -> 16Gi"
    pref = _by_key(items, "preference")[0]
    assert pref.kind == "VirtualMachinePreference", "namespaced preference"
    assert pref.metadata.name == "agents", "named after the XR"
    assert pref.spec.devices.preferredDiskBus == "virtio", "virtio disks"
    assert pref.spec.devices.preferredInterfaceModel == "virtio", "virtio NICs"
}

test_machine_type_uses_cluster_instancetype = lambda {
    items = tpl.render(_build({machineType = "u1.large", instances = [{name = "a"}]}), {preference.Resource = {}})
    assert len(_by_key(items, "instancetype")) == 0, "machineType -> no namespaced instancetype composed"
    vm = _by_key(items, "instance-a")[0]
    assert vm.spec.instancetype.kind == "VirtualMachineClusterInstancetype", "references the cluster instancetype"
    assert vm.spec.instancetype.name == "u1.large", "by name"
}

test_ssh_secret = lambda {
    items = tpl.render(_build({sshKey = {user = "u", publicKey = "ssh-ed25519 AAAA"}}), {})
    sec = _by_key(items, "ssh-key")[0]
    assert sec.metadata.name == "agents-ssh", "one Secret for the template"
    assert sec.stringData.key == "ssh-ed25519 AAAA", "public key material"
}

# ---- render: machines --------------------------------------------------------
test_machines_wait_for_template = lambda {
    items = tpl.render(_build({instances = [{name = "a"}]}), {instancetype.Resource = {}})
    assert len(_by_key(items, "instance-a")) == 0, "no machine until the preference is observed too"
}

test_machine_from_template = lambda {
    vm = _vm({diskGb = 40, storageClass = "fast", sshKey = {user = "u", publicKey = "k"}, instances = [{name = "a"}]}, "a")
    assert vm.apiVersion == "kubevirt.io/v1", "a KubeVirt VirtualMachine"
    assert vm.metadata.name == "agents-a", "named <template>-<instance>"
    assert vm.spec.runStrategy == "Always", "machines are started"
    assert vm.spec.instancetype.kind == "VirtualMachineInstancetype", "references the template's instancetype"
    assert vm.spec.instancetype.name == "agents", "by name"
    assert vm.spec.preference.kind == "VirtualMachinePreference", "references the template's preference"
    assert vm.spec.preference.name == "agents", "by name"
    _dom = vm.spec.template.spec.domain
    assert not _dom?.cpu, "the instancetype owns cpu — KubeVirt rejects a VM that sets both"
    assert not _dom?.memory, "the instancetype owns memory"
    assert not _dom.devices.disks[0].disk?.bus, "the preference picks the disk bus"
    dv = vm.spec.dataVolumeTemplates[0]
    assert dv.metadata.name == "agents-a-root", "one root disk per machine"
    assert dv.spec.source.registry.url == "docker://quay.io/containerdisks/ubuntu:24.04", "image defaults to ubuntu-24-04"
    assert dv.spec.storage.resources.requests.storage == "40Gi", "diskGb sizes the PVC"
    assert dv.spec.storage.storageClassName == "fast", "storageClass"
    assert vm.spec.template.spec.accessCredentials[0].sshPublicKey.source.secret.secretName == "agents-ssh", "shared ssh Secret"
}

test_user_data_and_labels = lambda {
    _spec = {userData = "#cloud-config\nbase: 1", tags = {team = "platform"}, instances = [{name = "a"}, {name = "b", userData = "#cloud-config\nown: 1", tags = {role = "canary"}}]}
    a = _vm(_spec, "a")
    b = _vm(_spec, "b")
    assert a.spec.template.spec.volumes[1].cloudInitNoCloud.userData == "#cloud-config\nbase: 1", "template userData"
    assert b.spec.template.spec.volumes[1].cloudInitNoCloud.userData == "#cloud-config\nown: 1", "per-instance userData wins"
    assert a.metadata.labels == {team = "platform"}, "template tags -> labels"
    assert b.metadata.labels == {team = "platform", role = "canary"}, "instance tags merge over template tags"
    assert _vm({instances = [{name = "c"}]}, "c").spec.template.spec.volumes[1].cloudInitNoCloud.userData == "#cloud-config\n", "minimal cloud-config so ssh key propagation has a NoCloud disk"
}

# ---- status ------------------------------------------------------------------
test_status = lambda {
    _spec = {instances = [{name = "a"}]}
    pending = tpl.status(_build(_spec), {})
    assert pending.status.provider == "kubevirt", "provider"
    assert pending.status.ready == False, "template not observed -> not ready"
    assert pending.status.templateId == "lab/agents", "deterministic template id"
    assert pending.status["cloud-url"] == "kubernetes://lab/virtualmachineinstancetype.instancetype.kubevirt.io/agents", "points at the instancetype"
    assert pending.status.instances == [{name = "agents-a", ready = False, id = "lab/agents-a"}], "one entry per machine"
    running = tpl.status(_build(_spec), _obs | {"instance-a" = {Resource.status.printableStatus = "Running"}})
    assert running.status.ready == True, "template observed and every machine Running -> ready"
    starting = tpl.status(_build(_spec), _obs | {"instance-a" = {Resource.status.printableStatus = "Provisioning"}})
    assert starting.status.ready == False, "a machine still provisioning -> not ready"
}
