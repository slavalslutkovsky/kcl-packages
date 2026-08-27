# vm (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-compute schema package. The portable VirtualMachine
# maps onto a Compute Instance: the abstract image becomes a public image
# family, sshKey the "ssh-keys" metadata entry, userData the "startup-script"
# entry, spot the SPOT provisioning model and tags the instance labels.
# GCP places the machine in a zone, defaulting to "<region>-a".
# network.securityGroupIds is AWS-only and fails the render instead of
# silently launching a machine with different reachability than asked for.
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance as instance

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract size -> Compute Engine machine type. spec.machineType overrides.
machine_for = lambda size: str -> str {
    {
        small = "e2-medium"
        medium = "e2-standard-2"
        large = "e2-standard-4"
        xlarge = "e2-standard-8"
    }[size]
}

# Abstract image -> public image family self-link. spec.imageId overrides.
image_for = lambda image: str -> str {
    {
        "ubuntu-24-04" = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
        "ubuntu-22-04" = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts"
        "debian-12" = "projects/debian-cloud/global/images/family/debian-12"
    }[image]
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _net = _spec?.network

    assert _spec?.region, "vm-gcp: spec.region is required"
    assert not _net?.securityGroupIds, "vm-gcp: network.securityGroupIds is AWS-only — control reachability with GCP firewall rules on the network instead"

    _zone = _spec?.zone or "${_spec.region}-a"

    # ssh-keys and startup-script both live in instance metadata; omit the
    # block entirely when neither is asked for.
    _metadata = {
        if _spec?.sshKey:
            "ssh-keys" = "${_spec.sshKey.user}:${_spec.sshKey.publicKey}"
        if _spec?.userData:
            "startup-script" = _spec.userData
    }

    # The instance. external-name pins the GCP instance name to the XR name so
    # the console URL and machine identity are predictable before observation.
    [instance.Instance {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.zone = _zone
        spec.forProvider.machineType = _spec?.machineType or machine_for(_spec?.size or "small")
        spec.forProvider.bootDisk.initializeParams = {
            image = _spec?.imageId or image_for(_spec?.image or "ubuntu-24-04")
            size = _spec?.diskGb or 30
        }
        spec.forProvider.networkInterface = [{
            if _net?.subnetId:
                subnetwork = _net.subnetId
            else:
                network = "default"
            if _net?.publicIp:
                # An empty access config allocates an ephemeral public address.
                accessConfig = [{}]
        }]
        if _metadata:
            spec.forProvider.metadata = _metadata
        if _spec?.spot:
            spec.forProvider.scheduling = {
                preemptible = True
                automaticRestart = False
                provisioningModel = "SPOT"
                instanceTerminationAction = "STOP"
            }
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _nics = _at?.networkInterface or []
    _nic0 = _nics[0] if len(_nics) > 0 else Undefined
    _acs = _nic0?.accessConfig or []
    _ac0 = _acs[0] if len(_acs) > 0 else Undefined
    _id = (_at?.instanceId) or (_at?.id)
    _zone = _spec?.zone or "${_spec?.region}-a"
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "VirtualMachine"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            ready = (_id or "") != ""
            name = oxr.metadata.name
            if _nic0?.networkIp:
                privateIp = _nic0.networkIp
            if _ac0?.natIp:
                publicIp = _ac0.natIp
            if _id:
                id = _id
                "cloud-url" = "https://console.cloud.google.com/compute/instancesDetail/zones/${_zone}/instances/${oxr.metadata.name}"
        }
    }
}
