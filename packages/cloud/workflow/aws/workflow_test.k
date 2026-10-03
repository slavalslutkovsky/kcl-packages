import json
import .workflow

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_asl = '{"StartAt":"Done","States":{"Done":{"Type":"Succeed"}}}'

# NOTE: helper names must not collide with render()'s `oxr`/`ocds` parameters —
# KCL normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Workflow", metadata.name = "demo", spec = {region = "eu-west-1", definition = _asl} | _spec}
}

_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

test_render_minimal = lambda {
    items = workflow.render(_build({}))
    assert len(items) == 2, "state machine + composed execution role"
    m = _by_name(items, "managed")
    assert m.apiVersion == "sfn.aws.m.upbound.io/v1beta1" and m.kind == "StateMachine"
    assert m.metadata.annotations["crossplane.io/external-name"] == "demo", "the state machine name is pinned to the XR name"
    fp = m.spec.forProvider
    assert fp.region == "eu-west-1"
    assert fp.definition == _asl, "the ASL definition must travel verbatim"
    assert fp.roleArnSelector.matchControllerRef == True, "the composed role binds by controller ref"
    assert fp?.roleArn == Undefined and fp?.encryptionConfiguration == Undefined and fp?.tags == Undefined
}

test_composed_role = lambda {
    r = _by_name(workflow.render(_build({})), "role")
    assert r.kind == "Role"
    trust = json.decode(r.spec.forProvider.assumeRolePolicy)
    assert trust.Statement[0].Principal.Service == "states.amazonaws.com", "only Step Functions may assume the role"
}

test_existing_role_skips_composing_one = lambda {
    items = workflow.render(_build({serviceAccount = "arn:aws:iam::1:role/wf"}))
    assert len(items) == 1, "an existing role must not be duplicated"
    fp = items[0].spec.forProvider
    assert fp.roleArn == "arn:aws:iam::1:role/wf"
    assert fp?.roleArnSelector == Undefined, "a selector would override the explicit ARN"
}

test_kms = lambda {
    fp = workflow.render(_build({encryptionKmsKeyId = "arn:aws:kms:eu-west-1:1:key/a"}))[0].spec.forProvider
    assert fp.encryptionConfiguration.type == "CUSTOMER_MANAGED_KMS_KEY"
    assert fp.encryptionConfiguration.kmsKeyId == "arn:aws:kms:eu-west-1:1:key/a"
}

test_tags_and_deletion_policy_reach_every_mr = lambda {
    items = workflow.render(_build({deletionPolicy = "Orphan", tags = {team = "core"}}))
    assert all i in items {i.spec.managementPolicies == _orphan}, "Orphan must reach the role too"
    assert all i in items {i.spec.forProvider.tags == {team = "core"}}
    _deleted = workflow.render(_build({}))
    assert all i in _deleted {i.spec.managementPolicies != _orphan}
}

test_status_pre_creation = lambda {
    dxr = workflow.status(_build({}), {})
    assert dxr.status.provider == "aws" and dxr.status.ready == False
    assert dxr.status.name == "demo", "the name is deterministic from spec"
    assert dxr.status?.arn == Undefined and dxr.status?["cloud-url"] == Undefined
}

test_status_observed = lambda {
    _arn = "arn:aws:states:eu-west-1:1:stateMachine:demo"
    _at = {arn = _arn, region = "eu-west-1", status = "ACTIVE", revisionId = "r1", roleArn = "arn:aws:iam::1:role/demo-x"}
    dxr = workflow.status(_build({}), {managed.Resource.status.atProvider = _at})
    assert dxr.status.ready == True
    assert dxr.status.arn == _arn and dxr.status.id == _arn
    assert dxr.status.revision == "r1"
    assert dxr.status.identity == "arn:aws:iam::1:role/demo-x", "the execution role is the identity to grant permissions to"
    assert dxr.status["cloud-url"] == "https://eu-west-1.console.aws.amazon.com/states/home?region=eu-west-1#/statemachines/view/${_arn}"
    deleting = workflow.status(_build({}), {managed.Resource.status.atProvider = _at | {status = "DELETING"}})
    assert deleting.status.ready == False
}
