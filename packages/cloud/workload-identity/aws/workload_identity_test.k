import json
import .workload_identity as wi

_orphan = ["Observe", "Create", "Update", "LateInitialize"]
_issuer = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"
_host = "oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLE"

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "WorkloadIdentity"
        metadata = {name = "demo", namespace = "apps"}
        spec = _spec | {serviceAccount = _spec?.serviceAccount or {name = "demo-sa"}, cluster = _spec?.cluster or {oidcIssuer = _issuer}}
    }
}

# ocds carrying an observed role.
_observed = {
    managed = {
        Resource = {
            status = {
                atProvider = {
                    arn = "arn:aws:iam::123456789012:role/demo"
                    id = "demo"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------
test_render_minimal = lambda {
    items = wi.render(_build({}), {})
    assert len(items) == 1, "a minimal spec must emit exactly the role"
    assert items[0].apiVersion == "iam.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Role", "the identity is an IAM role"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the role name is pinned to the XR name"
}

test_trust_policy = lambda {
    doc = json.decode(wi.render(_build({}), {})[0].spec.forProvider.assumeRolePolicy)
    stmt = doc.Statement[0]
    assert len(doc.Statement) == 1, "only the cluster's OIDC provider may assume the role"
    assert stmt.Action == "sts:AssumeRoleWithWebIdentity", "IRSA federates a web identity"
    assert stmt.Principal.Federated == _issuer, "the issuer is the federated principal"
    assert stmt.Condition.StringEquals["${_host}:sub"] == ["system:serviceaccount:apps:demo-sa"], "only the bound ServiceAccount may assume it"
    assert stmt.Condition.StringEquals["${_host}:aud"] == ["sts.amazonaws.com"], "the EKS default audience is required by default"
}

test_trust_policy_issuer_url_and_audiences = lambda {
    _spec = {
        cluster = {oidcIssuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/OTHER", audiences = ["sts.amazonaws.com", "extra"]}
    }
    doc = json.decode(wi.render(_build(_spec), {})[0].spec.forProvider.assumeRolePolicy)
    keys = doc.Statement[0].Condition.StringEquals
    assert "oidc.eks.eu-west-1.amazonaws.com/id/OTHER:sub" in keys, "an issuer URL is reduced to the condition-key host"
    assert keys["oidc.eks.eu-west-1.amazonaws.com/id/OTHER:aud"] == ["sts.amazonaws.com", "extra"], "explicit audiences win"
}

test_identity_name_display_name_and_tags = lambda {
    fp = wi.render(_build({displayName = "External Secrets", identity.name = "external-secrets", tags = {team = "platform"}}), {})[0]
    assert fp.metadata.annotations["crossplane.io/external-name"] == "external-secrets", "identity.name pins the role name"
    assert fp.spec.forProvider.description == "External Secrets", "displayName becomes the role description"
    assert fp.spec.forProvider.tags == {team = "platform"}, "tags carried"
}

# ---- render: grants ---------------------------------------------------------
test_grants = lambda {
    items = wi.render(_build({accessPolicies = [
        {role = "AmazonS3ReadOnlyAccess"}
        {role = "arn:aws:iam::123456789012:policy/custom"}
    ]}), {})
    assert len(items) == 3, "one attachment per grant"
    assert items[1].kind == "RolePolicyAttachment", "grants are policy attachments"
    assert items[1].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "grant-0", "grants are numbered"
    assert items[1].spec.forProvider.policyArn == "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess", "a bare name is an AWS-managed policy"
    assert items[1].spec.forProvider.roleSelector.matchControllerRef == True, "attachments bind to the composed role"
    assert items[2].spec.forProvider.policyArn == "arn:aws:iam::123456789012:policy/custom", "an ARN passes through"
}

# ---- render: existing identity ----------------------------------------------
test_existing_identity = lambda {
    items = wi.render(_build({identity.existing = "arn:aws:iam::123456789012:role/shared"}), {})
    assert len(items) == 1, "an existing role is not created; only the annotated ServiceAccount is composed"
    assert items[0].apiVersion == "v1" and items[0].kind == "ServiceAccount", "the Kubernetes ServiceAccount needs no observation when the ARN is given"
    assert items[0].metadata.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/shared", "the annotation points at the existing role"
}

# ---- render: the Kubernetes ServiceAccount ----------------------------------
test_kubernetes_service_account = lambda {
    items = wi.render(_build({}), _observed)
    assert len(items) == 2, "the annotated ServiceAccount appears once the role is observed"
    ksa = items[1]
    assert ksa.apiVersion == "v1" and ksa.kind == "ServiceAccount", "core Kubernetes ServiceAccount"
    assert ksa.metadata.name == "demo-sa", "named after spec.serviceAccount.name"
    assert ksa.metadata.namespace == "apps", "composed into the XR's namespace"
    assert ksa.metadata.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/demo", "the AWS SDKs read the role off this annotation"
}

test_service_account_not_created = lambda {
    items = wi.render(_build({
        serviceAccount = {name = "demo-sa", create = False}
    }), _observed)
    assert len(items) == 1, "create=false must leave the ServiceAccount to its owner"
    doc = json.decode(items[0].spec.forProvider.assumeRolePolicy)
    assert doc.Statement[0].Condition.StringEquals["${_host}:sub"] == ["system:serviceaccount:apps:demo-sa"], "the trust is still scoped to that ServiceAccount"
}

test_service_account_other_namespace = lambda {
    _spec = {
        serviceAccount = {name = "flux", namespace = "flux-system", create = False}
    }
    doc = json.decode(wi.render(_build(_spec), {})[0].spec.forProvider.assumeRolePolicy)
    assert doc.Statement[0].Condition.StringEquals["${_host}:sub"] == ["system:serviceaccount:flux-system:flux"], "the subject follows the ServiceAccount's namespace"
}

# ---- render: deletion policy ------------------------------------------------
test_deletion_policy = lambda {
    _orphaned = wi.render(_build({deletionPolicy = "Orphan", accessPolicies = [{role = "ReadOnlyAccess"}]}), {})
    assert _orphaned[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the role"
    assert _orphaned[1].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies on the attachments"
    _deleted = wi.render(_build({}), {})[0].spec.managementPolicies
    assert not (_deleted == _orphan), "Delete must not set the orphan policies"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = wi.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "WorkloadIdentity", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.serviceAccount == "apps/demo-sa", "the bound KSA is reported before creation"
    assert dxr.status.subject == "system:serviceaccount:apps:demo-sa", "the trusted subject is known before creation"
    assert dxr.status?.arn == Undefined, "no ARN before the role exists"
}

test_status_observed = lambda {
    dxr = wi.status(_build({}), _observed)
    assert dxr.status.ready == True, "an observed ARN must mark the binding ready"
    assert dxr.status.arn == "arn:aws:iam::123456789012:role/demo", "ARN must be surfaced"
    assert dxr.status.principal == "arn:aws:iam::123456789012:role/demo", "the principal is the role ARN"
    assert dxr.status.annotation == "arn:aws:iam::123456789012:role/demo", "the annotation value is the ARN"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.aws.amazon.com/iam/home#/roles/details/demo", "cloud-url must point at the role"
}

test_status_existing_identity = lambda {
    dxr = wi.status(_build({identity.existing = "arn:aws:iam::123456789012:role/shared"}), {})
    assert dxr.status.ready == True, "an existing role is ready immediately"
    assert dxr.status.annotation == "arn:aws:iam::123456789012:role/shared", "the annotation is the existing ARN"
}
