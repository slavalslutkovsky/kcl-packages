# iam (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-iam schema package. The portable Identity maps onto an
# IAM Role: spec.trust becomes the assume-role (trust) policy, each
# accessPolicies entry a RolePolicyAttachment, inlinePolicy a RolePolicy and
# permissionsBoundary the role's boundary. Attachments cannot carry a scope or
# a condition, so those fields FAIL the render here instead of silently
# attaching broader access than was asked for.
import json
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as role
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment as attachment
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy as rolepolicy

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# A grant role that is not an ARN is an AWS-managed policy name.
policy_arn = lambda r: str -> str {
    r if r.startswith("arn:") else "arn:aws:iam::aws:policy/${r}"
}

# The host used in OIDC condition keys ("<host>:sub"): the part of the IAM
# OIDC provider ARN after "oidc-provider/", or the issuer URL without scheme.
oidc_host = lambda issuer: str -> str {
    _h = issuer
    if "oidc-provider/" in _h:
        _h = _h.split("oidc-provider/")[1]

    if _h.startswith("https://"):
        _h = _h[8::]

    _h
}

# spec.trust -> assume-role policy document (JSON). A role with no trust is
# unusable AND uncreatable (AWS requires the document), so an empty trust
# block fails the render rather than producing a dangling identity.
assume_policy = lambda trust: any -> str {
    _stmts: [any] = []
    if trust?.services:
        _stmts += [{Effect = "Allow", Principal = {Service = trust.services}, Action = "sts:AssumeRole"}]

    if trust?.identities:
        _stmts += [{Effect = "Allow", Principal = {AWS = trust.identities}, Action = "sts:AssumeRole"}]

    if trust?.federated:
        _f = trust.federated
        _host = oidc_host(_f.issuer)
        _keys = {"${_host}:sub" = _f.subjects}
        if _f?.audiences:
            _keys |= {"${_host}:aud" = _f.audiences}

        _stmts += [{
            Effect = "Allow"
            Principal = {Federated = _f.issuer}
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {StringEquals = _keys}
        }]

    assert len(_stmts) > 0, "iam-aws: spec.trust must allow at least one principal (services, identities or federated) — an AWS role cannot exist without a trust policy"
    json.encode({Version = "2012-10-17", Statement = _stmts})
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _grants = _spec?.accessPolicies or []

    # A managed-policy attachment is all-or-nothing: honouring neither scope
    # nor condition, dropping them would grant MORE access than asked for.
    assert all _g in _grants {
        not _g?.scope
    }, "iam-aws: accessPolicies[].scope is not expressible on a policy attachment — put the resource scope inside spec.inlinePolicy instead"
    assert all _g in _grants {
        not _g?.condition
    }, "iam-aws: accessPolicies[].condition is not expressible on a policy attachment — put the condition inside spec.inlinePolicy instead"

    # 1) The role. external-name pins the IAM role name to the XR name so the
    # principal ARN is predictable before the role is first observed.
    _items: [any] = [role.Role {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.assumeRolePolicy = assume_policy(_spec?.trust)
        if _spec?.displayName:
            spec.forProvider.description = _spec.displayName
        if _spec?.permissionsBoundary:
            spec.forProvider.permissionsBoundary = _spec.permissionsBoundary
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) One attachment per grant, bound to the role via matchControllerRef.
    _items += [attachment.RolePolicyAttachment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "grant-${_i}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.policyArn = policy_arn(_g.role)
        spec.forProvider.roleSelector.matchControllerRef = True
    } for _i, _g in _grants]

    # 3) Inline policy for scoped/conditional access.
    if _spec?.inlinePolicy:
        _items += [rolepolicy.RolePolicy {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "inline-policy"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.policy = _spec.inlinePolicy
            spec.forProvider.roleSelector.matchControllerRef = True
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = (_at?.id) or oxr.metadata.name
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Identity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = (_at?.arn or "") != ""
            name = _name
            "cloud-url" = "https://console.aws.amazon.com/iam/home#/roles/details/${_name}"
            if _at:
                if _at?.arn:
                    arn = _at.arn
                    principal = _at.arn
                if _at?.id:
                    id = _at.id
        }
    }
}
