# Unit tests for tenant-account: the cluster-side ProviderConfig and admission
# policy, and the client-side CloudFormation template.
import .lib
import runtime

_platform = {roleArn = "arn:aws:iam::111122223333:role/crossplane-provider-aws"}
_a = {namespace = "tenant-a", accountId = "444455556666", externalId = "tenant-a-7f3c9e21"}
_mk = lambda accounts: [any] -> lib.Values {
  lib.Values {platform = _platform, accounts = accounts}
}
_by_kind = lambda items: [any], kind: str -> [any] {
  [_i for _i in items if _i.kind == kind]
}
_fails = lambda f: any -> str {
  _msg = runtime.catch(f)
  assert _msg, "expected a render failure"
  _msg
}
_stmts = lambda tpl: {str:}, policy: str -> {str:} {
  {_s.Sid: _s for _p in tpl.Resources.ProvisionerRole.Properties.Policies if _p.PolicyName == policy for _s in _p.PolicyDocument.Statement}
}

# The ProviderConfig lives in the tenant namespace, assumes the client role
# with the external id, and authenticates as the platform (IRSA by default).
test_provider_config = lambda {
  _pc = lib.render(_mk([_a]))[0]
  assert _pc.apiVersion == "aws.m.upbound.io/v1beta1" and _pc.kind == "ProviderConfig", "namespaced aws family ProviderConfig"
  assert _pc.metadata.namespace == "tenant-a" and _pc.metadata.name == "aws", "default name aws, in the tenant namespace"
  assert _pc.metadata.labels[lib.account_label] == "444455556666", "account label"
  assert _pc.spec.credentials.source == "IRSA", "IRSA by default"
  assert len(_pc.spec.assumeRoleChain) == 1, "one hop"
  assert _pc.spec.assumeRoleChain[0].roleARN == "arn:aws:iam::444455556666:role/platform-provisioner", "client role ARN"
  assert _pc.spec.assumeRoleChain[0].externalID == "tenant-a-7f3c9e21", "external id"
  _custom = lib.render(lib.Values {platform = _platform | {credentials = {source = "PodIdentity"}, roleName = "vendor-x"}, accounts = [_a | {name = "aws-prod", roleName = "own-name"}]})[0]
  assert _custom.spec.credentials.source == "PodIdentity", "credentials passed through"
  assert _custom.metadata.name == "aws-prod", "name sets the ProviderConfig name"
  assert _custom.spec.assumeRoleChain[0].roleARN == "arn:aws:iam::444455556666:role/own-name", "per-account roleName wins"
}

# One policy + binding for all accounts: the binding selects exactly the
# tenant namespaces; the allowed-name map carries each namespace's configs.
test_admission = lambda {
  items = lib.render(_mk([_a, _a | {name = "aws-dev"}, {namespace = "tenant-b", accountId = "777788889999", externalId = "b-ext"}]))
  assert len(_by_kind(items, "ProviderConfig")) == 3, "one ProviderConfig per account"
  _vap = _by_kind(items, "ValidatingAdmissionPolicy")
  _bind = _by_kind(items, "ValidatingAdmissionPolicyBinding")
  assert len(_vap) == 1 and len(_bind) == 1, "one policy, one binding"
  assert _vap[0].spec.matchConstraints.resourceRules[0].resources == ["buckets"] and _vap[0].spec.matchConstraints.resourceRules[0].apiGroups == ["cloud.example.org"], "Buckets only"
  assert _vap[0].spec.variables[0].expression == '{"tenant-a": ["aws", "aws-dev"], "tenant-b": ["aws"]}[object.metadata.namespace]', _vap[0].spec.variables[0].expression
  assert "object.spec.providerConfigName in variables.allowed" in _vap[0].spec.validations[0].expression, "must be one of the namespace's names"
  assert _bind[0].spec.policyName == lib.policy_name and _bind[0].spec.validationActions == ["Deny"], "enforced"
  assert _bind[0].spec.matchResources.namespaceSelector.matchExpressions[0].values == ["tenant-a", "tenant-b"], "exactly the tenant namespaces, once each"
}

# Values are validated before anything renders. One case per test: a caught
# schema check failure leaks into the next assert of the same test run.
test_values_duplicate = lambda {
  assert "duplicated: [tenant-a/aws]" in _fails(lambda {
    _mk([_a, _a | {accountId = "999999999999"}])
  })
}
test_values_account_id = lambda {
  assert "accountId must be 12 digits" in _fails(lambda {
    _mk([_a | {accountId = "1234"}])
  })
}
test_values_external_id = lambda {
  assert "externalId must be" in _fails(lambda {
    _mk([_a | {externalId = "has space"}])
  })
}
test_values_platform_role = lambda {
  assert "platform.roleArn must be an IAM role ARN" in _fails(lambda {
    lib.Values {platform = {roleArn = "arn:aws:iam::111122223333:user/x"}, accounts = [_a]}
  })
}
test_values_no_accounts = lambda {
  assert "at least one client account" in _fails(lambda {
    _mk([])
  })
}

# Client template: the role trusts only the platform role with the external
# id; without accessRoles it gets bucket permissions and no IAM at all.
test_client_buckets_only = lambda {
  _t = lib.render_client(_mk([_a]), "")[0]
  _role = _t.Resources.ProvisionerRole
  assert _role.Type == "AWS::IAM::Role" and _role.Properties.RoleName == "platform-provisioner", "role named as the ProviderConfig assumes"
  _trust = _role.Properties.AssumeRolePolicyDocument.Statement
  assert len(_trust) == 1 and _trust[0].Principal == {AWS = _platform.roleArn} and _trust[0].Action == "sts:AssumeRole", "platform role only"
  assert _trust[0].Condition == {
    StringEquals = {"sts:ExternalId" = "tenant-a-7f3c9e21"}
  }, "external id required"
  assert [_p.PolicyName for _p in _role.Properties.Policies] == ["buckets"], "no IAM without accessRoles"
  assert "AccessBoundary" not in _t.Resources and "AccessBoundaryArn" not in _t.Outputs, "no boundary without accessRoles"
  _b = _stmts(_t, "buckets")
  assert _b.Buckets.Resource == "arn:aws:s3:::*" and _b.ForceDestroy.Resource == "arn:aws:s3:::*/*", "S3 resources"
  _acts = _b.Buckets.Action + _b.ForceDestroy.Action
  _data = [_act for _act in _acts if _act in ["s3:GetObject", "s3:PutObject", "s3:*", "s3:Get*", "s3:Put*"]]
  assert _data == [], "no object reads or writes, got ${_data}"
}

# accessRoles: every IAM write is gated on the boundary (condition key or the
# boundary tag), confined to the tenant's role-name prefix; the boundary
# itself carries no IAM and no bucket configuration writes.
test_client_access_roles = lambda {
  _t = lib.render_client(_mk([_a | {accessRoles = True}]), "tenant-a")[0]
  _arn = "arn:aws:iam::444455556666:policy/platform-provisioner-access-boundary"
  assert lib.boundary_arn(lib.Platform {**_platform}, lib.Account {**_a}) == _arn, "boundary ARN"
  _s = _stmts(_t, "access-roles")
  assert all _sid, _st in _s {
    _st.Resource == "arn:aws:iam::444455556666:role/tenant-a-*"
  }, "tenant role prefix only"
  assert _s.CreateCapped.Condition.StringEquals == {"iam:PermissionsBoundary" = _arn, "aws:RequestTag/${lib.boundary_tag}" = _arn}, "create only capped and tagged"
  assert _s.InlinePoliciesOfCapped.Condition.StringEquals == {"iam:PermissionsBoundary" = _arn}, "inline policies only on capped roles"
  assert _s.LifecycleOfTagged.Condition.StringEquals == {"aws:ResourceTag/${lib.boundary_tag}" = _arn}, "updates/deletes only on tagged roles"
  assert _s.UntagOfTagged.Condition["ForAllValues:StringNotEquals"] == {"aws:TagKeys" = [lib.boundary_tag]}, "the boundary tag cannot be removed"
  _writes = [_act for _sid, _st in _s if _sid != "Read" for _act in _st.Action]
  _ungated = [_act for _sid, _st in _s if _sid != "Read" and not _st?.Condition for _act in _st.Action]
  assert _writes and _ungated == [], "every IAM write is conditioned, ungated: ${_ungated}"
  assert all _act in _s.Read.Action {
    _act.startswith("iam:Get") or _act.startswith("iam:List")
  }, "unconditioned statement is read-only"
  _bp = _t.Resources.AccessBoundary
  assert _bp.Type == "AWS::IAM::ManagedPolicy" and _bp.Properties.ManagedPolicyName == "platform-provisioner-access-boundary", "boundary policy named as the ARN says"
  _bacts = _bp.Properties.PolicyDocument.Statement[0].Action
  _bad = [_act for _act in _bacts if _act.startswith("iam:") or _act.startswith("s3:PutBucket") or _act in ["s3:*", "s3:Put*", "*"]]
  assert _bad == [], "boundary: no IAM, no bucket configuration writes, got ${_bad}"
  assert _t.Outputs.AccessBoundaryArn.Value == {Ref = "AccessBoundary"}, "boundary ARN output"
}

# The partition follows the platform role (GovCloud / China), and the
# namespace filter picks one tenant or fails naming the known ones.
test_client_partition_and_filter = lambda {
  _gov = lib.Values {platform = {roleArn = "arn:aws-us-gov:iam::111122223333:role/xp"}, accounts = [_a | {accessRoles = True}, {namespace = "tenant-b", accountId = "777788889999", externalId = "b-ext"}]}
  assert lib.render(_gov)[0].spec.assumeRoleChain[0].roleARN == "arn:aws-us-gov:iam::444455556666:role/platform-provisioner", "partition from the platform role"
  _t = lib.render_client(_gov, "tenant-a")
  assert len(_t) == 1 and _stmts(_t[0], "buckets").Buckets.Resource == "arn:aws-us-gov:s3:::*", "one tenant, gov partition"
  assert len(lib.render_client(_gov, "")) == 2, "no filter: every account"
  assert "have: [tenant-a, tenant-b]" in _fails(lambda {
    lib.render_client(_gov, "tenant-c")
  })
}
