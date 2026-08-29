import json
import .iam

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Identity", metadata.name = "demo", spec = _spec}
}

_trusted = lambda _extra {
    _build({trust.services = ["ec2.amazonaws.com"]} | _extra)
}

# The parsed assume-role policy document of a render()'s Role.
_assume = lambda _spec {
    json.decode(iam.render(_build(_spec), {})[0].spec.forProvider.assumeRolePolicy)
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = iam.render(_trusted({}), {})
    assert len(items) == 1, "trust-only spec must emit exactly one Role"
    assert items[0].apiVersion == "iam.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Role", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "role name must be pinned to the XR name"
}

# ---- render: trust policy ---------------------------------------------------
test_trust_service = lambda {
    doc = _assume({trust.services = ["ec2.amazonaws.com", "eks.amazonaws.com"]})
    assert doc.Version == "2012-10-17", "policy version"
    assert len(doc.Statement) == 1, "one statement for services"
    assert doc.Statement[0].Principal.Service == ["ec2.amazonaws.com", "eks.amazonaws.com"], "service principals carried"
    assert doc.Statement[0].Action == "sts:AssumeRole", "services assume via sts:AssumeRole"
}

test_trust_identities = lambda {
    doc = _assume({trust.identities = ["arn:aws:iam::111122223333:role/admin"]})
    assert len(doc.Statement) == 1, "one statement for identities"
    assert doc.Statement[0].Principal.AWS == ["arn:aws:iam::111122223333:role/admin"], "principal ARNs carried"
}

test_trust_federated = lambda {
    doc = _assume({
        trust.federated = {
            issuer = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
            subjects = ["repo:my-org/my-repo:ref:refs/heads/main"]
            audiences = ["sts.amazonaws.com"]
        }
    })
    s = doc.Statement[0]
    assert s.Action == "sts:AssumeRoleWithWebIdentity", "federation assumes via web identity"
    assert s.Principal.Federated == "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com", "issuer is the federated principal"
    assert s.Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:my-org/my-repo:ref:refs/heads/main"], "subjects become the :sub condition on the provider host"
    assert s.Condition.StringEquals["token.actions.githubusercontent.com:aud"] == ["sts.amazonaws.com"], "audiences become the :aud condition"
}

test_trust_all_statements = lambda {
    doc = _assume({
        trust = {
            services = ["ec2.amazonaws.com"]
            identities = ["arn:aws:iam::111122223333:role/admin"]
            federated = {issuer = "https://token.actions.githubusercontent.com", subjects = ["repo:x"]}
        }
    })
    assert len(doc.Statement) == 3, "each trust flavour is its own statement"
}

test_oidc_host = lambda {
    assert iam.oidc_host("arn:aws:iam::1:oidc-provider/accounts.google.com") == "accounts.google.com", "host from provider ARN"
    assert iam.oidc_host("https://accounts.google.com") == "accounts.google.com", "host from issuer URL"
}

# ---- render: grants (access control) ----------------------------------------
test_policy_arn = lambda {
    assert iam.policy_arn("AmazonS3ReadOnlyAccess") == "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess", "names resolve to AWS-managed policy ARNs"
    assert iam.policy_arn("arn:aws:iam::1:policy/mine") == "arn:aws:iam::1:policy/mine", "ARNs pass through"
}

test_grants = lambda {
    items = iam.render(_trusted({accessPolicies = [{role = "AmazonS3ReadOnlyAccess"}, {role = "arn:aws:iam::1:policy/mine"}]}), {})
    assert len(items) == 3, "one attachment per grant"
    assert items[1].kind == "RolePolicyAttachment", "grants are attachments"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    assert items[1].spec.forProvider.policyArn == "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess", "policy name resolved"
    assert items[1].spec.forProvider.roleSelector.matchControllerRef == True, "attachment binds to the composed role"
    assert items[2].spec.forProvider.policyArn == "arn:aws:iam::1:policy/mine", "policy ARN carried"
}

test_inline_policy = lambda {
    _doc = '{"Version": "2012-10-17", "Statement": []}'
    items = iam.render(_trusted({inlinePolicy = _doc}), {})
    assert len(items) == 2, "inlinePolicy adds one RolePolicy"
    assert items[1].kind == "RolePolicy", "inline policy MR kind"
    assert items[1].spec.forProvider.policy == _doc, "policy document carried verbatim"
    assert items[1].spec.forProvider.roleSelector.matchControllerRef == True, "inline policy binds to the composed role"
}

test_permissions_boundary = lambda {
    fp = iam.render(_trusted({permissionsBoundary = "arn:aws:iam::1:policy/boundary"}), {})[0].spec.forProvider
    assert fp.permissionsBoundary == "arn:aws:iam::1:policy/boundary", "boundary carried"
    off = iam.render(_trusted({}), {})[0].spec.forProvider
    assert not off?.permissionsBoundary, "no boundary unless asked for"
}

test_display_name_and_tags = lambda {
    fp = iam.render(_trusted({displayName = "CI deployer", tags = {team = "platform"}}), {})[0].spec.forProvider
    assert fp.description == "CI deployer", "displayName -> role description"
    assert fp.tags == {team = "platform"}, "tags carried"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = iam.render(_trusted({deletionPolicy = "Orphan", accessPolicies = [{role = "AmazonS3ReadOnlyAccess"}]}), {})
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the role"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the grants"
    _deleted = iam.render(_trusted({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = iam.status(_trusted({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Identity", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status?.arn == Undefined, "no arn before the role exists"
    assert dxr.status["cloud-url"] == "https://console.aws.amazon.com/iam/home#/roles/details/demo", "cloud-url is known ahead of creation"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:iam::111122223333:role/demo"
                        id = "demo"
                    }
                }
            }
        }
    }
    dxr = iam.status(_trusted({}), ocds)
    assert dxr.status.ready == True, "an observed arn must mark the identity ready"
    assert dxr.status.arn == "arn:aws:iam::111122223333:role/demo", "arn must be surfaced"
    assert dxr.status.principal == "arn:aws:iam::111122223333:role/demo", "principal is the role ARN"
    assert dxr.status.name == "demo", "observed role name must be surfaced"
    assert dxr.status.id == "demo", "observed id must be surfaced"
}
