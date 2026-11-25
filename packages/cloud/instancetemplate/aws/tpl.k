# instancetemplate (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-ec2 schema package. The portable InstanceTemplate maps
# onto an EC2 LaunchTemplate (plus one KeyPair when spec.sshKey is set), and
# every spec.instances entry becomes an EC2 Instance launched FROM that
# template (`launchTemplate.id`, version $Default).
#
# AWS has no account-independent image families, so spec.imageId (an AMI ID)
# is REQUIRED and the render fails without it rather than guessing an AMI.
#
# Two things live on each Instance instead of the template:
#   - the root volume size: a launch template sizes a volume by device name,
#     and the root device name (/dev/sda1, /dev/xvda, ...) depends on the AMI;
#     Instance.rootBlockDevice targets the root device whatever it is called.
#   - the full tag set: the template's tagSpecifications tag anything launched
#     from it, but the Instance MR owns its tags afterwards, so it carries the
#     merged set (template tags | instance tags | Name) to avoid a perpetual
#     diff that strips the launch-time tags.
#
# Instances need the template's id, which only exists once the LaunchTemplate
# is observed, so they are composed from the second reconcile on.
import base64
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_instance as instance
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_key_pair as keypair
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_launch_template as launchtemplate

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Composition resource names. One per instance, keyed by the instance's name.
template_key = "template"
ssh_key = "ssh-key"
instance_key = lambda name: str -> str {
    "instance-${name}"
}

# Provider-side machine name of one instance: "<template>-<instance>".
instance_name = lambda template: str, name: str -> str {
    "${template}-${name}"
}

# Abstract size -> EC2 instance type. spec.machineType overrides.
machine_for = lambda size: str -> str {
    {
        small = "t3.medium"
        medium = "m5.large"
        large = "m5.xlarge"
        xlarge = "m5.2xlarge"
    }[size]
}

# The LaunchTemplate id once observed, else Undefined.
observed_template_id = lambda ocds -> str {
    (ocds[template_key]?.Resource?.status?.atProvider?.id) if template_key in ocds else Undefined
}

# The template. updateDefaultVersion makes every spec change the new $Default,
# which is the version the instances launch from.
launch_template = lambda oxr, mp {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _net = _spec?.network
    # A subnet or a public address needs an explicit interface; security groups
    # then belong to that interface — EC2 rejects them at the top level too.
    _nic = _net?.subnetId or _net?.publicIp
    _tags = _spec?.tags or {}
    launchtemplate.LaunchTemplate {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = template_key}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            region = _spec.region
            name = _name
            imageId = _spec.imageId
            instanceType = _spec?.machineType or machine_for(_spec?.size or "small")
            updateDefaultVersion = True
            if _spec?.sshKey:
                keyName = _name
            if _spec?.userData:
                # Launch templates take user data base64-encoded, unlike Instance.
                userData = base64.encode(_spec.userData)
            if _spec?.spot:
                instanceMarketOptions.marketType = "spot"
            if _nic:
                networkInterfaces = [{
                    deviceIndex = 0
                    deleteOnTermination = "true"
                    if _net?.subnetId:
                        subnetId = _net.subnetId
                    if _net?.securityGroupIds:
                        securityGroups = _net.securityGroupIds
                    if _net?.publicIp:
                        associatePublicIpAddress = "true"
                }]
            elif _net?.securityGroupIds:
                vpcSecurityGroupIds = _net.securityGroupIds
            if _tags:
                tags = _tags
                tagSpecifications = [
                    {resourceType = "instance", tags = _tags}
                    {resourceType = "volume", tags = _tags}
                ]
        }
    }
}

# One machine launched from the template. Per-instance userData overrides the
# template's (Instance.userData wins over the launch template's).
machine = lambda oxr, inst, lt_id: str, mp {
    _spec = oxr.spec
    _full = instance_name(oxr.metadata.name, inst.name)
    instance.Instance {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = instance_key(inst.name)}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.region = _spec.region
        spec.forProvider.launchTemplate = {id = lt_id, version = "$Default"}
        spec.forProvider.rootBlockDevice.volumeSize = _spec?.diskGb or 30
        if inst?.userData:
            spec.forProvider.userData = inst.userData
        spec.forProvider.tags = (_spec?.tags or {}) | (inst?.tags or {}) | {Name = _full}
    }
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _insts = _spec?.instances or []

    assert _spec?.region, "instancetemplate-aws: spec.region is required"
    assert _spec?.imageId, "instancetemplate-aws: spec.imageId (an AMI ID) is required — AWS has no account-independent image families, so the abstract spec.image cannot be resolved to an AMI here"
    assert len({i.name = True for i in _insts}) == len(_insts), "instancetemplate-aws: spec.instances names must be unique"

    _items: [any] = [launch_template(oxr, _mp)]

    # SSH access: a KeyPair whose AWS key name is pinned to the XR name, which
    # is the keyName the template already references.
    if _spec?.sshKey:
        _items += [keypair.KeyPair {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = ssh_key
                "crossplane.io/external-name" = _name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _spec.region
            spec.forProvider.publicKey = _spec.sshKey.publicKey
        }]

    _lt_id = observed_template_id(ocds)
    if _lt_id:
        _items += [machine(oxr, i, _lt_id, _mp) for i in _insts]

    _items
}

# Observed state of one instance, as reported in status.instances.
instance_status = lambda oxr, ocds, inst {
    _key = instance_key(inst.name)
    _at = (ocds[_key]?.Resource?.status?.atProvider) if _key in ocds else Undefined
    {
        name = instance_name(oxr.metadata.name, inst.name)
        ready = (_at?.id or "") != ""
        if _at?.id:
            id = _at.id
        if _at?.privateIp:
            privateIp = _at.privateIp
        if _at?.publicIp:
            publicIp = _at.publicIp
    }
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _region = oxr.spec?.region
    _lt_id = observed_template_id(ocds)
    _insts = [instance_status(oxr, ocds, i) for i in oxr.spec?.instances or []]
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "InstanceTemplate"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = (_lt_id or "") != "" and all i in _insts {
                i.ready
            }
            templateName = oxr.metadata.name
            if _lt_id:
                templateId = _lt_id
                "cloud-url" = "https://${_region}.console.aws.amazon.com/ec2/home?region=${_region}#LaunchTemplateDetails:launchTemplateId=${_lt_id}"
            instances = _insts
        }
    }
}
