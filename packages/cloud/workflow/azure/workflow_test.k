import json
import .workflow

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

_wdl = {
    "$schema" = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
    contentVersion = "1.0.0.0"
    parameters = {
        region = {type = "String", defaultValue = "eu"}
    }
    triggers = {
        manual = {type = "Request", kind = "Http"}
    }
    actions = {
        Reserve = {type = "Http", inputs = {method = "POST", uri = "https://x"}, runAfter = {}}
        Respond = {type = "Response", inputs = {statusCode = 200}, runAfter = {Reserve = ["Succeeded"]}}
    }
}

# NOTE: helper names must not collide with render()'s `oxr`/`ocds` parameters —
# KCL normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Workflow", metadata.name = "demo", spec = {region = "westeurope", resourceGroup = "rg", definition = json.encode(_wdl)} | _spec}
}

_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

_observed = lambda _n {
    {Resource.status.atProvider.id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Logic/workflows/demo${_n}"}
}

test_render_splits_the_definition = lambda {
    items = workflow.render(_build({}))
    assert [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in items] == ["managed", "trigger-manual", "action-Reserve", "action-Respond"]
    wf = items[0]
    assert wf.kind == "AppWorkflow"
    assert wf.metadata.annotations["crossplane.io/external-name"] == "demo", "the Logic App name is pinned to the XR name"
    fp = wf.spec.forProvider
    assert fp.location == "westeurope" and fp.resourceGroupName == "rg"
    assert fp.workflowSchema == _wdl["$schema"] and fp.workflowVersion == "1.0.0.0"
    assert json.decode(fp.workflowParameters.region) == {type = "String", defaultValue = "eu"}, "parameter declarations travel as JSON strings"
}

test_steps_are_named_and_bound = lambda {
    items = workflow.render(_build({}))
    t = _by_name(items, "trigger-manual")
    assert t.kind == "AppTriggerCustom"
    assert t.metadata.annotations["crossplane.io/external-name"] == "manual", "the key is the trigger's name in the workflow"
    assert t.spec.forProvider.logicAppIdSelector.matchControllerRef == True
    assert json.decode(t.spec.forProvider.body) == _wdl.triggers.manual, "the trigger body round-trips"
    a = _by_name(items, "action-Respond")
    assert a.kind == "AppActionCustom"
    assert a.metadata.annotations["crossplane.io/external-name"] == "Respond"
    assert json.decode(a.spec.forProvider.body).runAfter == {Reserve = ["Succeeded"]}, "ordering survives the split through runAfter"
}

test_identity = lambda {
    assert workflow.render(_build({}))[0].spec.forProvider.identity.type == "SystemAssigned", "unset serviceAccount -> own identity"
    _uai = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/wf"
    ident = workflow.render(_build({serviceAccount = _uai}))[0].spec.forProvider.identity
    assert ident.type == "UserAssigned" and ident.identityIds == [_uai]
}

test_tags_and_deletion_policy = lambda {
    items = workflow.render(_build({deletionPolicy = "Orphan", tags = {team = "core"}}))
    assert all i in items {i.spec.managementPolicies == _orphan}, "Orphan must reach every step, or deleting the XR guts the workflow"
    assert items[0].spec.forProvider.tags == {team = "core"}
    assert workflow.render(_build({}))[0].spec.forProvider?.tags == Undefined
}

test_minimal_definition = lambda {
    items = workflow.render(_build({definition = '{"triggers":{},"actions":{}}'}))
    assert len(items) == 1, "an empty definition composes just the Logic App"
    fp = items[0].spec.forProvider
    assert fp?.workflowSchema == Undefined and fp?.workflowVersion == Undefined and fp?.workflowParameters == Undefined
}

test_status_pre_creation = lambda {
    dxr = workflow.status(_build({}), {})
    assert dxr.status.provider == "azure" and dxr.status.ready == False
    assert dxr.status.name == "demo"
    assert dxr.status?.id == Undefined and dxr.status?.identity == Undefined
}

test_status_waits_for_every_step = lambda {
    _wf = {
        Resource.status.atProvider = {id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Logic/workflows/demo", identity.principalId = "pid"}
    }
    partial = workflow.status(_build({}), {managed = _wf, "trigger-manual" = _observed("/triggers/manual"), "action-Reserve" = _observed("/actions/Reserve")})
    assert partial.status.ready == False, "a missing action keeps the workflow not ready"
    full = workflow.status(_build({}), {managed = _wf, "trigger-manual" = _observed("/triggers/manual"), "action-Reserve" = _observed("/actions/Reserve"), "action-Respond" = _observed("/actions/Respond")})
    assert full.status.ready == True
    assert full.status.identity == "pid", "the system-assigned principal is surfaced"
    assert full.status["cloud-url"] == "https://portal.azure.com/#resource/subscriptions/s/resourceGroups/rg/providers/Microsoft.Logic/workflows/demo"
}
