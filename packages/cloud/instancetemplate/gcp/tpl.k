# instancetemplate (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-compute schema package. The portable InstanceTemplate
# maps onto a (global) Compute InstanceTemplate, and every spec.instances entry
# becomes an InstanceFromTemplate bound to it by controller-ref selector — GCP
# resolves the template at create time, so no observed state is needed first.
#
# Mapping matches the vm-gcp backend: the abstract image becomes a public image
# family, sshKey the "ssh-keys" metadata entry, userData the "startup-script"
# entry, spot the SPOT provisioning model and tags the labels. Instances land
# in their own zone, else spec.zone, else "<region>-a".
#
# Per-instance overrides are written as FULL replacements of the template's
# map fields: an InstanceFromTemplate that sets `metadata` or `labels` replaces
# the template's map wholesale, so an instance overriding userData re-emits the
# ssh-keys entry too, and instance tags are merged over the template's here.
#
# GCP instance templates are immutable: the provider refuses an in-place
# update of the composed InstanceTemplate. Change a template by creating a new
# InstanceTemplate XR; existing instances are unaffected either way.
#
# network.securityGroupIds is AWS-only and fails the render instead of
# silently launching machines with different reachability than asked for.
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_template as itemplate
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_from_template as fromtemplate

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Composition resource names. One per instance, keyed by the instance's name.
template_key = "template"
instance_key = lambda name: str -> str {
    "instance-${name}"
}

# Provider-side machine name of one instance: "<template>-<instance>".
instance_name = lambda template: str, name: str -> str {
    "${template}-${name}"
}

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

# Instance metadata for a given boot script: ssh-keys and startup-script, each
# only when asked for.
metadata_for = lambda spec, user_data {
    {
        if spec?.sshKey:
            "ssh-keys" = "${spec.sshKey.user}:${spec.sshKey.publicKey}"
        if user_data:
            "startup-script" = user_data
    }
}

# The template.
template = lambda oxr, mp {
    _spec = oxr.spec
    _net = _spec?.network
    _metadata = metadata_for(_spec, _spec?.userData)
    itemplate.InstanceTemplate {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = template_key}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            name = oxr.metadata.name
            machineType = _spec?.machineType or machine_for(_spec?.size or "small")
            disk = [{
                boot = True
                autoDelete = True
                sourceImage = _spec?.imageId or image_for(_spec?.image or "ubuntu-24-04")
                diskSizeGb = _spec?.diskGb or 30
            }]
            networkInterface = [{
                if _net?.subnetId:
                    subnetwork = _net.subnetId
                else:
                    network = "default"
                if _net?.publicIp:
                    # An empty access config allocates an ephemeral public address.
                    accessConfig = [{}]
            }]
            if _metadata:
                metadata = _metadata
            if _spec?.spot:
                scheduling = {
                    preemptible = True
                    automaticRestart = False
                    provisioningModel = "SPOT"
                    instanceTerminationAction = "STOP"
                }
            if _spec?.tags:
                labels = _spec.tags
        }
    }
}

# One machine created from the template.
machine = lambda oxr, inst, mp {
    _spec = oxr.spec
    fromtemplate.InstanceFromTemplate {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = instance_key(inst.name)}
        if mp:
            spec.managementPolicies = mp
        spec.forProvider = {
            name = instance_name(oxr.metadata.name, inst.name)
            zone = inst?.zone or _spec?.zone or "${_spec.region}-a"
            sourceInstanceTemplateSelector.matchControllerRef = True
            if inst?.userData:
                metadata = metadata_for(_spec, inst.userData)
            if inst?.tags:
                labels = (_spec?.tags or {}) | inst.tags
        }
    }
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    _insts = _spec?.instances or []

    assert _spec?.region, "instancetemplate-gcp: spec.region is required"
    assert not _spec?.network?.securityGroupIds, "instancetemplate-gcp: network.securityGroupIds is AWS-only — control reachability with GCP firewall rules on the network instead"
    assert len({i.name = True for i in _insts}) == len(_insts), "instancetemplate-gcp: spec.instances names must be unique"

    [template(oxr, _mp)] + [machine(oxr, i, _mp) for i in _insts]
}

# Observed state of one instance, as reported in status.instances.
instance_status = lambda oxr, ocds, inst {
    _key = instance_key(inst.name)
    _at = (ocds[_key]?.Resource?.status?.atProvider) if _key in ocds else Undefined
    _nics = _at?.networkInterface or []
    _nic0 = _nics[0] if len(_nics) > 0 else Undefined
    _acs = _nic0?.accessConfig or []
    _ac0 = _acs[0] if len(_acs) > 0 else Undefined
    _id = (_at?.instanceId) or (_at?.id)
    {
        name = instance_name(oxr.metadata.name, inst.name)
        ready = (_id or "") != ""
        if _id:
            id = _id
        if _nic0?.networkIp:
            privateIp = _nic0.networkIp
        if _ac0?.natIp:
            publicIp = _ac0.natIp
    }
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds[template_key]?.Resource?.status?.atProvider) if template_key in ocds else Undefined
    _id = (_at?.selfLink) or (_at?.id)
    _insts = [instance_status(oxr, ocds, i) for i in oxr.spec?.instances or []]
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "InstanceTemplate"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = (_id or "") != "" and all i in _insts {
                i.ready
            }
            templateName = _name
            if _id:
                templateId = _id
                "cloud-url" = "https://console.cloud.google.com/compute/instanceTemplates/details/${_name}"
            instances = _insts
        }
    }
}
