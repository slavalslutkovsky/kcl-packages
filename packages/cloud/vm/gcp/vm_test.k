import .vm

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "VirtualMachine", metadata.name = "demo", spec = {region = "us-central1"} | _spec}
}

# ocds carrying an observed instance.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    instanceId = "1234567890123456789"
                    id = "projects/my-project/zones/us-central1-a/instances/demo"
                    networkInterface = [{
                        networkIp = "10.128.0.7"
                        accessConfig = [{natIp = "34.1.2.3"}]
                    }]
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = vm.render(_build({}), {})
    assert len(items) == 1, "minimal spec must emit exactly one Instance"
    assert items[0].apiVersion == "compute.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Instance", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "instance name must be pinned to the XR name"
}

# ---- render: zone ---------------------------------------------------------------
test_zone_default = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert fp.zone == "us-central1-a", "zone defaults to <region>-a"
}

test_zone_override = lambda {
    fp = vm.render(_build({zone = "us-central1-f"}), {})[0].spec.forProvider
    assert fp.zone == "us-central1-f", "explicit zone wins"
}

# ---- render: size / machine type -------------------------------------------------
test_size_ladder = lambda {
    assert vm.machine_for("small") == "e2-medium", "small -> e2-medium"
    assert vm.machine_for("medium") == "e2-standard-2", "medium -> e2-standard-2"
    assert vm.machine_for("large") == "e2-standard-4", "large -> e2-standard-4"
    assert vm.machine_for("xlarge") == "e2-standard-8", "xlarge -> e2-standard-8"
    fp = vm.render(_build({size = "medium"}), {})[0].spec.forProvider
    assert fp.machineType == "e2-standard-2", "size must map through the ladder"
}

test_machine_type_override = lambda {
    fp = vm.render(_build({size = "small", machineType = "n2-standard-16"}), {})[0].spec.forProvider
    assert fp.machineType == "n2-standard-16", "machineType must override the size mapping"
}

# ---- render: image / disk ---------------------------------------------------------
test_image_families = lambda {
    assert vm.image_for("ubuntu-24-04") == "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64", "ubuntu-24-04 family"
    assert vm.image_for("ubuntu-22-04") == "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts", "ubuntu-22-04 family"
    assert vm.image_for("debian-12") == "projects/debian-cloud/global/images/family/debian-12", "debian-12 family"
    fp = vm.render(_build({image = "debian-12"}), {})[0].spec.forProvider
    assert fp.bootDisk.initializeParams.image == "projects/debian-cloud/global/images/family/debian-12", "abstract image must map to the family"
}

test_image_default = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert fp.bootDisk.initializeParams.image == "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64", "image defaults to ubuntu-24-04"
}

test_image_id_override = lambda {
    fp = vm.render(_build({image = "debian-12", imageId = "projects/my-project/global/images/golden-1"}), {})[0].spec.forProvider
    assert fp.bootDisk.initializeParams.image == "projects/my-project/global/images/golden-1", "imageId must override the abstract image"
}

test_disk_gb = lambda {
    fp = vm.render(_build({diskGb = 50}), {})[0].spec.forProvider
    assert fp.bootDisk.initializeParams.size == 50, "diskGb must size the boot disk"
    _default = vm.render(_build({}), {})[0].spec.forProvider
    assert _default.bootDisk.initializeParams.size == 30, "boot disk defaults to 30 GiB"
}

# ---- render: network -----------------------------------------------------------
test_network_default = lambda {
    nic = vm.render(_build({}), {})[0].spec.forProvider.networkInterface[0]
    assert nic.network == "default", "no subnet -> the default network"
    assert not nic?.subnetwork, "no subnetwork unless asked"
    assert not nic?.accessConfig, "no public address unless asked"
}

test_network_subnet = lambda {
    nic = vm.render(_build({network.subnetId = "projects/p/regions/us-central1/subnetworks/apps"}), {})[0].spec.forProvider.networkInterface[0]
    assert nic.subnetwork == "projects/p/regions/us-central1/subnetworks/apps", "subnetId -> subnetwork"
    assert not nic?.network, "an explicit subnetwork must not also pin the default network"
}

test_network_public_ip = lambda {
    nic = vm.render(_build({network.publicIp = True}), {})[0].spec.forProvider.networkInterface[0]
    assert len(nic.accessConfig) == 1, "publicIp -> one (ephemeral) access config"
}

# ---- render: ssh key / user data --------------------------------------------------
test_metadata_omitted = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert not fp?.metadata, "metadata must be omitted entirely when empty"
}

test_ssh_key = lambda {
    fp = vm.render(_build({
        sshKey = {user = "dev", publicKey = "ssh-ed25519 AAAA key"}
    }), {})[0].spec.forProvider
    assert fp.metadata["ssh-keys"] == "dev:ssh-ed25519 AAAA key", "sshKey -> metadata ssh-keys as <user>:<key>"
}

test_user_data = lambda {
    fp = vm.render(_build({userData = "#!/bin/sh\necho hi"}), {})[0].spec.forProvider
    assert fp.metadata["startup-script"] == "#!/bin/sh\necho hi", "userData -> metadata startup-script"
}

# ---- render: spot / labels ---------------------------------------------------------
test_spot = lambda {
    fp = vm.render(_build({spot = True}), {})[0].spec.forProvider
    assert fp.scheduling.preemptible == True, "spot -> preemptible"
    assert fp.scheduling.automaticRestart == False, "spot machines must not auto-restart"
    assert fp.scheduling.provisioningModel == "SPOT", "spot -> the SPOT provisioning model"
    assert fp.scheduling.instanceTerminationAction == "STOP", "spot machines stop on reclaim"
    _plain = vm.render(_build({spot = False}), {})[0].spec.forProvider
    assert not _plain?.scheduling, "no scheduling block unless spot is asked"
}

test_labels = lambda {
    fp = vm.render(_build({
        tags = {team = "platform"}
    }), {})[0].spec.forProvider
    assert fp.labels == {team = "platform"}, "tags -> GCP labels"
}

# ---- render: deletion policy --------------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = vm.render(_build({deletionPolicy = "Orphan"}), {})
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    _deleted = vm.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status ----------------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = vm.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "VirtualMachine", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.name == "demo", "name is the XR name"
    assert not dxr.status?.id, "no id before the instance exists"
    assert not dxr.status?["cloud-url"], "no console URL before the instance exists"
}

test_status_observed = lambda {
    dxr = vm.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed instance id must mark the machine ready"
    assert dxr.status.privateIp == "10.128.0.7", "private IP is the first interface's networkIp"
    assert dxr.status.publicIp == "34.1.2.3", "public IP is the first access config's natIp"
    assert dxr.status.id == "1234567890123456789", "instanceId preferred as the id"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/compute/instancesDetail/zones/us-central1-a/instances/demo", "cloud-url must point at the instance in its zone"
}

test_status_observed_no_public_ip = lambda {
    _priv = {
        managed.Resource.status.atProvider = {id = "x", networkInterface = [{networkIp = "10.0.0.2"}]}
    }
    dxr = vm.status(_build({}), _priv)
    assert dxr.status.ready == True, "id alone marks the machine ready"
    assert dxr.status.privateIp == "10.0.0.2", "private IP surfaced"
    assert not dxr.status?.publicIp, "no public IP without an access config"
    assert dxr.status.id == "x", "falls back to atProvider.id when instanceId is absent"
}
