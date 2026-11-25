import base64
import .tpl

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "InstanceTemplate", metadata = {name = "agents", namespace = "default"}, spec = {region = "us-east-1", imageId = "ami-0abc"} | _spec}
}

# ocds with the LaunchTemplate observed — instances are composed from here on.
_lt = {template.Resource.status.atProvider.id = "lt-0123"}

_by_key = lambda items, key: str {
    [i for i in items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == key]
}

_lt_fp = lambda _spec {
    _by_key(tpl.render(_build(_spec), {}), "template")[0].spec.forProvider
}

# ---- render: template --------------------------------------------------------
test_template_minimal = lambda {
    items = tpl.render(_build({}), {})
    assert len(items) == 1, "no sshKey and no observed template -> just the LaunchTemplate"
    assert items[0].apiVersion == "ec2.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "LaunchTemplate", "wrong kind"
    fp = items[0].spec.forProvider
    assert fp.name == "agents", "template name pinned to the XR name"
    assert fp.region == "us-east-1", "region"
    assert fp.imageId == "ami-0abc", "imageId -> template AMI"
    assert fp.instanceType == "t3.medium", "size defaults to small"
    assert fp.updateDefaultVersion == True, "spec changes must become the $Default the instances launch from"
}

test_machine_type = lambda {
    assert tpl.machine_for("medium") == "m5.large", "medium -> m5.large"
    assert _lt_fp({size = "xlarge"}).instanceType == "m5.2xlarge", "size ladder"
    assert _lt_fp({size = "small", machineType = "c7i.large"}).instanceType == "c7i.large", "machineType wins"
}

test_user_data_base64 = lambda {
    assert _lt_fp({userData = "#!/bin/sh\necho hi"}).userData == base64.encode("#!/bin/sh\necho hi"), "launch templates take user data base64-encoded"
    assert not _lt_fp({})?.userData, "no userData unless asked"
}

test_spot = lambda {
    assert _lt_fp({spot = True}).instanceMarketOptions.marketType == "spot", "spot -> instanceMarketOptions"
    assert not _lt_fp({})?.instanceMarketOptions, "on-demand by default"
}

test_network_interface = lambda {
    fp = _lt_fp({network = {subnetId = "subnet-1", securityGroupIds = ["sg-1"], publicIp = True}})
    nic = fp.networkInterfaces[0]
    assert nic.deviceIndex == 0, "primary interface"
    assert nic.subnetId == "subnet-1", "subnetId on the interface"
    assert nic.securityGroups == ["sg-1"], "security groups move onto the interface"
    assert nic.associatePublicIpAddress == "true", "publicIp -> associatePublicIpAddress"
    assert not fp?.vpcSecurityGroupIds, "EC2 rejects top-level security groups next to an interface"
}

test_security_groups_only = lambda {
    fp = _lt_fp({network.securityGroupIds = ["sg-1"]})
    assert fp.vpcSecurityGroupIds == ["sg-1"], "without a subnet or public IP, groups stay top-level"
    assert not fp?.networkInterfaces, "no explicit interface needed"
}

test_tags = lambda {
    fp = _lt_fp({tags = {team = "platform"}})
    assert fp.tags == {team = "platform"}, "tags on the template itself"
    assert [s.resourceType for s in fp.tagSpecifications] == ["instance", "volume"], "anything launched from the template is tagged"
    assert all s in fp.tagSpecifications {
        s.tags == {team = "platform"}
    }, "tag specifications carry the template tags"
}

# ---- render: ssh key ---------------------------------------------------------
test_ssh_key = lambda {
    items = tpl.render(_build({sshKey = {user = "ubuntu", publicKey = "ssh-ed25519 AAAA"}}), {})
    kp = _by_key(items, "ssh-key")[0]
    assert kp.kind == "KeyPair", "sshKey composes a KeyPair"
    assert kp.metadata.annotations["crossplane.io/external-name"] == "agents", "key name pinned to the XR name"
    assert kp.spec.forProvider.publicKey == "ssh-ed25519 AAAA", "public key material"
    assert _by_key(items, "template")[0].spec.forProvider.keyName == "agents", "the template references that key name"
}

# ---- render: instances -------------------------------------------------------
test_instances_wait_for_template = lambda {
    items = tpl.render(_build({instances = [{name = "a"}]}), {})
    assert len(_by_key(items, "instance-a")) == 0, "instances need the template id, so none before it is observed"
}

test_instances_from_template = lambda {
    items = tpl.render(_build({diskGb = 60, tags = {team = "platform"}, instances = [{name = "a"}, {name = "b", tags = {role = "canary"}, userData = "#!/bin/sh"}]}), _lt)
    a = _by_key(items, "instance-a")[0]
    b = _by_key(items, "instance-b")[0]
    assert a.kind == "Instance", "each entry is an EC2 Instance"
    assert a.spec.forProvider.launchTemplate.id == "lt-0123", "launched from the observed template"
    assert a.spec.forProvider.launchTemplate.version == "$Default", "from its default version"
    assert a.spec.forProvider.rootBlockDevice.volumeSize == 60, "diskGb sizes each root volume"
    assert a.spec.forProvider.tags == {team = "platform", Name = "agents-a"}, "template tags plus the Name tag"
    assert not a.spec.forProvider?.userData, "no per-instance userData -> the template's applies"
    assert b.spec.forProvider.tags == {team = "platform", role = "canary", Name = "agents-b"}, "instance tags merge over template tags"
    assert b.spec.forProvider.userData == "#!/bin/sh", "per-instance userData overrides the template's, unencoded"
}

# ---- render: deletion policy -------------------------------------------------
test_deletion_policy = lambda {
    items = tpl.render(_build({deletionPolicy = "Orphan", sshKey = {user = "u", publicKey = "k"}, instances = [{name = "a"}]}), _lt)
    assert all i in items {
        i.spec.managementPolicies == _orphan
    }, "Orphan applies to the template, key and every instance"
    _deleted = tpl.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status ------------------------------------------------------------------
test_status_pending = lambda {
    dxr = tpl.status(_build({instances = [{name = "a"}]}), {})
    assert dxr.kind == "InstanceTemplate", "dxr kind echoes the composite"
    assert dxr.status.provider == "aws", "provider"
    assert dxr.status.ready == False, "nothing observed -> not ready"
    assert dxr.status.templateName == "agents", "template name is known up front"
    assert not dxr.status?.templateId, "no id before observation"
    assert dxr.status.instances == [{name = "agents-a", ready = False}], "one entry per instance, not ready"
}

test_status_observed = lambda {
    _obs = _lt | {"instance-a" = {Resource.status.atProvider = {id = "i-1", privateIp = "10.0.0.5", publicIp = "3.3.3.3"}}}
    dxr = tpl.status(_build({instances = [{name = "a"}]}), _obs)
    assert dxr.status.ready == True, "template and every instance observed -> ready"
    assert dxr.status.templateId == "lt-0123", "template id"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#LaunchTemplateDetails:launchTemplateId=lt-0123", "console URL of the template"
    assert dxr.status.instances[0] == {name = "agents-a", ready = True, id = "i-1", privateIp = "10.0.0.5", publicIp = "3.3.3.3"}, "observed instance details"
}

test_status_partial = lambda {
    dxr = tpl.status(_build({instances = [{name = "a"}, {name = "b"}]}), _lt | {"instance-a" = {Resource.status.atProvider.id = "i-1"}})
    assert dxr.status.ready == False, "one instance still pending -> not ready"
}

test_status_no_instances = lambda {
    dxr = tpl.status(_build({}), _lt)
    assert dxr.status.ready == True, "a template with no instances is ready once observed"
    assert dxr.status.instances == [], "empty list"
}
