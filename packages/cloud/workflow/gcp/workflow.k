# workflow (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-workflows schema package. The portable Workflow maps
# onto exactly one Workflows Workflow: the family has no other kind, and the
# whole source travels in forProvider.sourceContents. resourceGroup is
# Azure-only and ignored here.
import gcp_workflows.models.v1beta1.workflows_gcpm_upbound_io_v1beta1_workflow as wf

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    [wf.Workflow {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        # The external name is provider-assigned (the full resource path), so
        # the workflow name is a plain parameter; pin it to the XR name.
        spec.forProvider.name = _name
        spec.forProvider.region = _spec.region
        spec.forProvider.sourceContents = _spec.definition
        # The API defaults the Terraform-level lock ON, which makes even an
        # intended Delete hang; the XR's deletionPolicy is the lifecycle knob.
        spec.forProvider.deletionProtection = False
        if _spec?.serviceAccount:
            spec.forProvider.serviceAccount = _spec.serviceAccount
        if _spec?.encryptionKmsKeyId:
            spec.forProvider.cryptoKeyName = _spec.encryptionKmsKeyId
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    _region = (_at?.region) or _spec.region
    _project = _at?.project

    # Deterministic from the region and the pinned name; the project qualifier
    # is only known once the workflow is observed.
    _console = "https://console.cloud.google.com/workflows/workflow/${_region}/${_name}/executions"
    if _project:
        _console = "${_console}?project=${_project}"

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Workflow"
        metadata.name = _name
        status = {
            provider = "gcp"
            # A deployed revision is ACTIVE; UNAVAILABLE means the source or
            # its service account is broken.
            ready = _at?.state == "ACTIVE"
            name = _name
            "cloud-url" = _console
            if _at?.id:
                id = _at.id
            if _at?.revisionId:
                revision = _at.revisionId
            if _at?.serviceAccount:
                identity = _at.serviceAccount
        }
    }
}
