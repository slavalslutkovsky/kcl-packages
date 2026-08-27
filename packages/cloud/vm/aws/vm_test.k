import .vm

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "VirtualMachine", metadata.name = "demo", spec = {region = "us-east-1", imageId = "ami-0abc"} | _spec}
}

# ocds carrying an observed instance.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    id = "i-0123456789abcdef0"
                    privateIp = "10.0.1.5"
                    publicIp = "54.1.2.3"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = vm.render(_build({}), {})
    assert len(items) == 1, "minimal spec must emit exactly one Instance"
    assert items[0].apiVersion == "ec2.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Instance", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].spec.forProvider.region == "us-east-1", "region carried"
    assert items[0].spec.forProvider.ami == "ami-0abc", "imageId must become the AMI"
}

# ---- render: size / machine type ----------------------------------------------
test_size_ladder = lambda {
    assert vm.machine_for("small") == "t3.medium", "small -> t3.medium"
    assert vm.machine_for("medium") == "m5.large", "medium -> m5.large"
    assert vm.machine_for("large") == "m5.xlarge", "large -> m5.xlarge"
    assert vm.machine_for("xlarge") == "m5.2xlarge", "xlarge -> m5.2xlarge"
    fp = vm.render(_build({size = "large"}), {})[0].spec.forProvider
    assert fp.instanceType == "m5.xlarge", "size must map through the ladder"
}

test_machine_type_override = lambda {
    fp = vm.render(_build({size = "small", machineType = "c6i.4xlarge"}), {})[0].spec.forProvider
    assert fp.instanceType == "c6i.4xlarge", "machineType must override the size mapping"
}

# ---- render: disk / user data / spot ------------------------------------------
test_disk_default = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert fp.rootBlockDevice.volumeSize == 30, "root disk defaults to 30 GiB"
}

test_disk_gb = lambda {
    fp = vm.render(_build({diskGb = 100}), {})[0].spec.forProvider
    assert fp.rootBlockDevice.volumeSize == 100, "diskGb must size the root block device"
}

test_user_data = lambda {
    fp = vm.render(_build({userData = "#!/bin/sh\necho hi"}), {})[0].spec.forProvider
    assert fp.userData == "#!/bin/sh\necho hi", "userData must be carried verbatim"
    _plain = vm.render(_build({}), {})[0].spec.forProvider
    assert not _plain?.userData, "no userData unless asked"
}

test_spot = lambda {
    fp = vm.render(_build({spot = True}), {})[0].spec.forProvider
    assert fp.instanceMarketOptions.marketType == "spot", "spot must set the spot market type"
    _plain = vm.render(_build({spot = False}), {})[0].spec.forProvider
    assert not _plain?.instanceMarketOptions, "no market options unless spot is asked"
}

# ---- render: network -----------------------------------------------------------
test_network_defaults = lambda {
    fp = vm.render(_build({}), {})[0].spec.forProvider
    assert not fp?.subnetId, "no subnet unless asked (default VPC)"
    assert not fp?.vpcSecurityGroupIds, "no security groups unless asked"
    assert not fp?.associatePublicIpAddress, "no public IP unless asked"
}

test_network_options = lambda {
    fp = vm.render(_build({
        network = {
            subnetId = "subnet-01"
            securityGroupIds = ["sg-01", "sg-02"]
            publicIp = True
        }
    }), {})[0].spec.forProvider
    assert fp.subnetId == "subnet-01", "subnetId carried"
    assert fp.vpcSecurityGroupIds == ["sg-01", "sg-02"], "security group IDs carried"
    assert fp.associatePublicIpAddress == True, "publicIp -> associatePublicIpAddress"
}

# ---- render: ssh key ------------------------------------------------------------
test_ssh_key = lambda {
    items = vm.render(_build({
        sshKey = {user = "ubuntu", publicKey = "ssh-ed25519 AAAA key"}
    }), {})
    assert len(items) == 2, "sshKey must compose a KeyPair next to the Instance"
    assert items[1].kind == "KeyPair", "companion is an EC2 KeyPair"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "ssh-key", "key pair resource name"
    assert items[1].metadata.annotations["crossplane.io/external-name"] == "demo", "AWS key name pinned to the XR name"
    assert items[1].spec.forProvider.publicKey == "ssh-ed25519 AAAA key", "public key carried"
    assert items[1].spec.forProvider.region == "us-east-1", "key pair lives in the machine's region"
    assert items[0].spec.forProvider.keyName == "demo", "instance references the pinned key name"
}

test_no_ssh_key = lambda {
    items = vm.render(_build({}), {})
    assert len(items) == 1, "no KeyPair unless sshKey is set"
    assert not items[0].spec.forProvider?.keyName, "no keyName without an sshKey"
}

# ---- render: tags ---------------------------------------------------------------
test_tags = lambda {
    fp = vm.render(_build({
        tags = {team = "platform"}
    }), {})[0].spec.forProvider
    assert fp.tags == {team = "platform"}, "tags carried"
}

# ---- render: deletion policy -----------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = vm.render(_build({deletionPolicy = "Orphan", sshKey = {user = "u", publicKey = "k"}}), {})
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the instance"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the key pair"
    _deleted = vm.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status ----------------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = vm.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "VirtualMachine", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.name == "demo", "name is the XR name"
    assert not dxr.status?.id, "no id before the instance exists"
    assert not dxr.status?.privateIp, "no private IP before the instance exists"
}

test_status_observed = lambda {
    dxr = vm.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed instance id must mark the machine ready"
    assert dxr.status.privateIp == "10.0.1.5", "private IP must be surfaced"
    assert dxr.status.publicIp == "54.1.2.3", "public IP must be surfaced"
    assert dxr.status.id == "i-0123456789abcdef0", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#InstanceDetails:instanceId=i-0123456789abcdef0", "cloud-url must point at the instance in its region"
}
