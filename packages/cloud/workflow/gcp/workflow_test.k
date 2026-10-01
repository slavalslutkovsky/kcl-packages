import .workflow

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_src = "main:\n  steps:\n    - done:\n        return: ok\n"

# NOTE: helper names must not collide with render()'s `oxr`/`ocds` parameters —
# KCL normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Workflow", metadata.name = "demo", spec = {region = "europe-west1", definition = _src} | _spec}
}

_fp = lambda _spec {
    workflow.render(_build(_spec))[0].spec.forProvider
}

test_render_minimal = lambda {
    items = workflow.render(_build({}))
    assert len(items) == 1, "gcp composes exactly one Workflow"
    assert items[0].apiVersion == "workflows.gcp.m.upbound.io/v1beta1" and items[0].kind == "Workflow"
    fp = items[0].spec.forProvider
    assert fp.name == "demo", "the workflow name is pinned to the XR name"
    assert fp.region == "europe-west1"
    assert fp.sourceContents == _src, "the source must travel verbatim"
    assert fp.deletionProtection == False, "the API-level lock must be off, or deletes hang"
    assert fp?.serviceAccount == Undefined, "unset serviceAccount leaves the project default"
    assert fp?.cryptoKeyName == Undefined and fp?.labels == Undefined
}

test_optional_fields = lambda {
    fp = _fp({serviceAccount = "wf@p.iam.gserviceaccount.com", encryptionKmsKeyId = "projects/p/locations/europe-west1/keyRings/r/cryptoKeys/k", tags = {team = "core"}})
    assert fp.serviceAccount == "wf@p.iam.gserviceaccount.com"
    assert fp.cryptoKeyName == "projects/p/locations/europe-west1/keyRings/r/cryptoKeys/k", "CMEK -> cryptoKeyName"
    assert fp.labels == {team = "core"}, "tags -> labels"
}

test_deletion_policy = lambda {
    assert workflow.render(_build({deletionPolicy = "Orphan"}))[0].spec.managementPolicies == _orphan
    assert workflow.render(_build({}))[0].spec.managementPolicies != _orphan
}

test_status_pre_creation = lambda {
    dxr = workflow.status(_build({}), {})
    assert dxr.kind == "Workflow" and dxr.status.provider == "gcp"
    assert dxr.status.ready == False, "nothing observed yet"
    assert dxr.status.name == "demo"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/workflows/workflow/europe-west1/demo/executions"
    assert dxr.status?.id == Undefined and dxr.status?.identity == Undefined
}

test_status_observed = lambda {
    _at = {
        id = "projects/p/locations/europe-west1/workflows/demo"
        project = "p"
        region = "europe-west1"
        revisionId = "000002-abc"
        serviceAccount = "projects/p/serviceAccounts/123-compute@developer.gserviceaccount.com"
        state = "ACTIVE"
    }
    dxr = workflow.status(_build({}), {managed.Resource.status.atProvider = _at})
    assert dxr.status.ready == True, "an ACTIVE workflow is ready"
    assert dxr.status.id == "projects/p/locations/europe-west1/workflows/demo"
    assert dxr.status.revision == "000002-abc"
    assert dxr.status.identity == "projects/p/serviceAccounts/123-compute@developer.gserviceaccount.com", "the effective identity is surfaced even when defaulted"
    assert dxr.status["cloud-url"].endswith("/executions?project=p"), "the observed project qualifies the console url"
    unavailable = workflow.status(_build({}), {managed.Resource.status.atProvider = _at | {state = "UNAVAILABLE"}})
    assert unavailable.status.ready == False, "an UNAVAILABLE workflow is not ready"
}
