import .tpl

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "agents", namespace = "default"}, spec = {region = "us-central1"} | _spec}
}

_by_key = lambda items, key: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == key]
}

_tfp = lambda _spec {
    _by_key(tpl.render(_build(_spec), {}), "template")[0].spec.forProvider
}

_ifp = lambda _spec, name: str {
    _by_key(tpl.render(_build(_spec), {}), "instance-${name}")[0].spec.forProvider
}

# ---- render: template --------------------------------------------------------
test_template_minimal = lambda {
    items = tpl.render(_build({}), {})
    assert len(items) == 1, "no instances -> just the InstanceTemplate"
    assert items[0].apiVersion == "compute.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "InstanceTemplate", "wrong kind"
    fp = items[0].spec.forProvider
    assert fp.name == "agents", "template name pinned to the XR name"
    assert fp.machineType == "e2-medium", "size defaults to small"
    assert fp.disk[0].boot == True, "one boot disk"
    assert fp.disk[0].autoDelete == True, "the boot disk dies with the instance"
    assert fp.disk[0].sourceImage == "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64", "image defaults to ubuntu-24-04"
    assert fp.disk[0].diskSizeGb == 30, "disk defaults to 30 GiB"
    assert fp.networkInterface[0].network == "default", "no subnet -> the default network"
    assert not fp?.metadata, "metadata omitted when empty"
    assert not fp?.scheduling, "on-demand by default"
}

test_machine_and_image = lambda {
    fp = _tfp({size = "large", image = "debian-12", diskGb = 80})
    assert fp.machineType == "e2-standard-4", "size ladder"
    assert fp.disk[0].sourceImage == "projects/debian-cloud/global/images/family/debian-12", "abstract image -> family"
    assert fp.disk[0].diskSizeGb == 80, "diskGb"
    _o = _tfp({machineType = "n2-standard-16", imageId = "projects/p/global/images/golden"})
    assert _o.machineType == "n2-standard-16", "machineType wins"
    assert _o.disk[0].sourceImage == "projects/p/global/images/golden", "imageId wins"
}

test_network = lambda {
    nic = _tfp({network = {subnetId = "projects/p/regions/us-central1/subnetworks/apps", publicIp = True}}).networkInterface[0]
    assert nic.subnetwork == "projects/p/regions/us-central1/subnetworks/apps", "subnetId -> subnetwork"
    assert not nic?.network, "explicit subnetwork does not also pin the default network"
    assert len(nic.accessConfig) == 1, "publicIp -> ephemeral access config"
}

test_metadata_spot_labels = lambda {
    fp = _tfp({sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAA"}, userData = "#!/bin/sh", spot = True, tags = {team = "platform"}})
    assert fp.metadata["ssh-keys"] == "dev:ssh-ed25519 AAAA", "sshKey -> ssh-keys"
    assert fp.metadata["startup-script"] == "#!/bin/sh", "userData -> startup-script"
    assert fp.scheduling.provisioningModel == "SPOT", "spot -> SPOT"
    assert fp.scheduling.preemptible == True, "spot -> preemptible"
    assert fp.scheduling.automaticRestart == False, "spot machines must not auto-restart"
    assert fp.labels == {team = "platform"}, "tags -> labels"
}

# ---- render: instances -------------------------------------------------------
test_instances_from_template = lambda {
    items = tpl.render(_build({instances = [{name = "a"}, {name = "b", zone = "us-central1-c"}]}), {})
    assert len(items) == 3, "template + one InstanceFromTemplate per entry, no observation needed"
    a = _by_key(items, "instance-a")[0]
    assert a.kind == "InstanceFromTemplate", "wrong kind"
    assert a.spec.forProvider.name == "agents-a", "machine named <template>-<instance>"
    assert a.spec.forProvider.zone == "us-central1-a", "zone defaults to <region>-a"
    assert a.spec.forProvider.sourceInstanceTemplateSelector.matchControllerRef == True, "bound to this XR's template"
    assert not a.spec.forProvider?.metadata, "no override -> template metadata applies"
    assert not a.spec.forProvider?.labels, "no override -> template labels apply"
    assert _by_key(items, "instance-b")[0].spec.forProvider.zone == "us-central1-c", "per-instance zone wins"
}

test_template_zone = lambda {
    assert _ifp({zone = "us-central1-f", instances = [{name = "a"}]}, "a").zone == "us-central1-f", "spec.zone is the instances' default zone"
}

test_instance_user_data_keeps_ssh = lambda {
    fp = _ifp({sshKey = {user = "dev", publicKey = "k"}, userData = "#!/bin/sh\nbase", instances = [{name = "a", userData = "#!/bin/sh\nown"}]}, "a")
    assert fp.metadata["startup-script"] == "#!/bin/sh\nown", "per-instance userData replaces the startup-script"
    assert fp.metadata["ssh-keys"] == "dev:k", "metadata replaces the template's wholesale, so ssh-keys is re-emitted"
}

test_instance_labels_merge = lambda {
    fp = _ifp({tags = {team = "platform", tier = "x"}, instances = [{name = "a", tags = {tier = "canary"}}]}, "a")
    assert fp.labels == {team = "platform", tier = "canary"}, "instance tags merge over template tags"
}

test_deletion_policy = lambda {
    items = tpl.render(_build({deletionPolicy = "Orphan", instances = [{name = "a"}]}), {})
    assert all i in items {
        i.spec.managementPolicies == _orphan
    }, "Orphan applies to the template and every instance"
}

# ---- status ------------------------------------------------------------------
test_status_pending = lambda {
    dxr = tpl.status(_build({instances = [{name = "a"}]}), {})
    assert dxr.status.provider == "gcp", "provider"
    assert dxr.status.ready == False, "nothing observed -> not ready"
    assert dxr.status.templateName == "agents", "template name known up front"
    assert not dxr.status?.templateId, "no id before observation"
    assert dxr.status.instances == [{name = "agents-a", ready = False}], "one entry per instance"
}

test_status_observed = lambda {
    _obs = {
        template.Resource.status.atProvider = {id = "projects/p/global/instanceTemplates/agents", selfLink = "https://www.googleapis.com/compute/v1/projects/p/global/instanceTemplates/agents"}
        "instance-a" = {Resource.status.atProvider = {instanceId = "123", networkInterface = [{networkIp = "10.128.0.7", accessConfig = [{natIp = "34.1.2.3"}]}]}}
    }
    dxr = tpl.status(_build({instances = [{name = "a"}]}), _obs)
    assert dxr.status.ready == True, "template + every instance observed -> ready"
    assert dxr.status.templateId == "https://www.googleapis.com/compute/v1/projects/p/global/instanceTemplates/agents", "selfLink preferred as the template id"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/compute/instanceTemplates/details/agents", "console URL"
    assert dxr.status.instances[0] == {name = "agents-a", ready = True, id = "123", privateIp = "10.128.0.7", publicIp = "34.1.2.3"}, "observed instance details"
}
