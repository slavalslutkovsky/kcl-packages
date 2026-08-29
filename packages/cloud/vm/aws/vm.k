# vm (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-ec2 schema package. The portable VirtualMachine maps
# onto an EC2 Instance (plus a KeyPair when spec.sshKey is set). AWS has no
# account-independent image families, so spec.imageId (an AMI ID) is REQUIRED
# here and the render fails without it rather than guessing an AMI. spot maps
# to instanceMarketOptions, network.publicIp to associatePublicIpAddress and
# diskGb to the root block device size.
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_instance as instance
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_key_pair as keypair

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract size -> EC2 instance type. spec.machineType overrides.
machine_for = lambda size: str -> str {
    {
        small = "t3.medium"
        medium = "m5.large"
        large = "m5.xlarge"
        xlarge = "m5.2xlarge"
    }[size]
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _net = _spec?.network

    assert _spec?.region, "vm-aws: spec.region is required"
    assert _spec?.imageId, "vm-aws: spec.imageId (an AMI ID) is required — AWS has no account-independent image families, so the abstract spec.image cannot be resolved to an AMI here"

    # 1) The instance. keyName is a plain string (no selector on the schema),
    # so the composed KeyPair pins its AWS key name to the XR name and the
    # instance references that same string.
    _items: [any] = [instance.Instance {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _spec.region
        spec.forProvider.ami = _spec.imageId
        spec.forProvider.instanceType = _spec?.machineType or machine_for(_spec?.size or "small")
        spec.forProvider.rootBlockDevice.volumeSize = _spec?.diskGb or 30
        if _net?.subnetId:
            spec.forProvider.subnetId = _net.subnetId
        if _net?.securityGroupIds:
            spec.forProvider.vpcSecurityGroupIds = _net.securityGroupIds
        if _net?.publicIp:
            spec.forProvider.associatePublicIpAddress = True
        if _spec?.sshKey:
            spec.forProvider.keyName = _name
        if _spec?.userData:
            spec.forProvider.userData = _spec.userData
        if _spec?.spot:
            spec.forProvider.instanceMarketOptions.marketType = "spot"
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) SSH access: a KeyPair whose AWS key name is pinned to the XR name so
    # the instance's keyName is deterministic before the key is first observed.
    if _spec?.sshKey:
        _items += [keypair.KeyPair {
            metadata.annotations = {
                "krm.kcl.dev/composition-resource-name" = "ssh-key"
                "crossplane.io/external-name" = _name
            }
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _spec.region
            spec.forProvider.publicKey = _spec.sshKey.publicKey
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _region = oxr.spec?.region
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "VirtualMachine"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = (_at?.id or "") != ""
            name = oxr.metadata.name
            if _at:
                if _at?.privateIp:
                    privateIp = _at.privateIp
                if _at?.publicIp:
                    publicIp = _at.publicIp
                if _at?.id:
                    id = _at.id
                    "cloud-url" = "https://${_region}.console.aws.amazon.com/ec2/home?region=${_region}#InstanceDetails:instanceId=${_at.id}"
        }
    }
}
