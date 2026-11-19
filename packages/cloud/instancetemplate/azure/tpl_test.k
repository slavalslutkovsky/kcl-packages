import base64
import .tpl

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_subnet = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/v/subnets/vms"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "agents", namespace = "default"}, spec = {
        region = "westeurope"
        resourceGroup = "rg"
        sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAA"}
        network.subnetId = _subnet
    } | _spec}
}

_by_key = lambda items, key: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == key]
}

# ---- render: shape -----------------------------------------------------------
test_no_instances_no_resources = lambda {
    assert tpl.render(_build({}), {}) == [], "the template is logical: nothing is composed without instances"
}

test_instance_minimal = lambda {
    items = tpl.render(_build({instances = [{name = "a"}]}), {})
    assert len(items) == 2, "VM + NIC per instance without publicIp or userData"
    vm = _by_key(items, "vm-a")[0]
    nic = _by_key(items, "nic-a")[0]
    assert vm.kind == "LinuxVirtualMachine", "wrong kind"
    assert vm.metadata.annotations["crossplane.io/external-name"] == "agents-a", "machine named <template>-<instance>"
    fp = vm.spec.forProvider
    assert fp.location == "westeurope", "region -> location"
    assert fp.resourceGroupName == "rg", "resource group"
    assert fp.size == "Standard_B2s", "size defaults to small"
    assert fp.adminUsername == "dev", "admin user from sshKey"
    assert fp.sourceImageReference.offer == "ubuntu-24_04-lts", "image defaults to ubuntu-24-04"
    assert fp.osDisk.diskSizeGb == 30, "disk defaults to 30 GiB"
    assert nic.kind == "NetworkInterface", "wrong kind"
    assert nic.metadata.annotations["crossplane.io/external-name"] == "agents-a-nic", "NIC name"
    assert nic.spec.forProvider.ipConfiguration[0].subnetId == _subnet, "subnet by ID"
}

test_selectors_scoped_per_instance = lambda {
    items = tpl.render(_build({network.publicIp = True, instances = [{name = "a"}, {name = "b"}]}), {})
    _sel = _by_key(items, "vm-a")[0].spec.forProvider.networkInterfaceIdsSelector
    assert _sel.matchControllerRef == True, "controller-scoped"
    assert _sel.matchLabels == {"cloud.example.org/instance" = "agents-a"}, "VM selects only its own NIC"
    assert _by_key(items, "nic-a")[0].metadata.labels == {"cloud.example.org/instance" = "agents-a"}, "NIC carries the instance label"
    assert _by_key(items, "nic-b")[0].metadata.labels == {"cloud.example.org/instance" = "agents-b"}, "each NIC labelled with its own instance"
    _pip_sel = _by_key(items, "nic-a")[0].spec.forProvider.ipConfiguration[0].publicIpAddressIdSelector
    assert _pip_sel.matchLabels == {"cloud.example.org/instance" = "agents-a"}, "NIC selects only its own PublicIP"
    assert _by_key(items, "public-ip-a")[0].metadata.labels == {"cloud.example.org/instance" = "agents-a"}, "PublicIP carries the instance label"
    assert len(_by_key(items, "public-ip-b")) == 1, "one PublicIP per instance"
}

test_machine_and_image = lambda {
    fp = _by_key(tpl.render(_build({size = "medium", imageId = "/subscriptions/s/images/golden", diskGb = 64, spot = True, instances = [{name = "a"}]}), {}), "vm-a")[0].spec.forProvider
    assert fp.size == "Standard_D2s_v5", "size ladder"
    assert fp.sourceImageId == "/subscriptions/s/images/golden", "imageId wins"
    assert not fp?.sourceImageReference, "no marketplace reference next to an image ID"
    assert fp.osDisk.diskSizeGb == 64, "diskGb"
    assert fp.priority == "Spot", "spot -> priority Spot"
    assert fp.evictionPolicy == "Deallocate", "spot machines deallocate on eviction"
}

test_user_data_per_instance = lambda {
    items = tpl.render(_build({userData = "base", instances = [{name = "a"}, {name = "b", userData = "own"}]}), {})
    sa = _by_key(items, "custom-data-a")[0]
    sb = _by_key(items, "custom-data-b")[0]
    assert sa.metadata.name == "agents-a-custom-data", "one Secret per instance"
    assert sa.data.customData == base64.encode(base64.encode("base")), "template userData, double-encoded"
    assert sb.data.customData == base64.encode(base64.encode("own")), "per-instance userData wins"
    assert _by_key(items, "vm-b")[0].spec.forProvider.customDataSecretRef.name == "agents-b-custom-data", "VM reads its own Secret"
}

test_tags_merge = lambda {
    fp = _by_key(tpl.render(_build({tags = {team = "platform"}, instances = [{name = "a", tags = {role = "canary"}}]}), {}), "vm-a")[0].spec.forProvider
    assert fp.tags == {team = "platform", role = "canary"}, "instance tags merge over template tags"
}

test_deletion_policy = lambda {
    items = tpl.render(_build({deletionPolicy = "Orphan", network.publicIp = True, instances = [{name = "a"}]}), {})
    assert all i in items {
        i.spec.managementPolicies == _orphan
    }, "Orphan applies to every managed resource"
}

# ---- status ------------------------------------------------------------------
test_status = lambda {
    _spec = {instances = [{name = "a"}, {name = "b"}]}
    pending = tpl.status(_build(_spec), {})
    assert pending.status.provider == "azure", "provider"
    assert pending.status.ready == False, "nothing observed -> not ready"
    assert not pending.status?.templateId, "logical template: no template id"
    _obs = {
        "vm-a" = {Resource.status.atProvider = {id = "/subscriptions/s/vm/agents-a", privateIpAddress = "10.0.0.4", publicIpAddress = "20.1.1.1"}}
        "vm-b" = {Resource.status.atProvider.id = "/subscriptions/s/vm/agents-b"}
    }
    dxr = tpl.status(_build(_spec), _obs)
    assert dxr.status.ready == True, "every instance observed -> ready"
    assert dxr.status.instances[0] == {name = "agents-a", ready = True, id = "/subscriptions/s/vm/agents-a", privateIp = "10.0.0.4", publicIp = "20.1.1.1"}, "observed details"
    assert dxr.status.instances[1] == {name = "agents-b", ready = True, id = "/subscriptions/s/vm/agents-b"}, "no IPs unless observed"
}
