# workload-identity (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-iam schema package plus core Kubernetes. The portable
# WorkloadIdentity maps onto IRSA: an IAM Role whose trust policy allows
# sts:AssumeRoleWithWebIdentity from the cluster's OIDC provider, conditioned
# on the ServiceAccount subject (system:serviceaccount:<ns>/<name>), one
# RolePolicyAttachment per accessPolicies entry, and the Kubernetes
# ServiceAccount annotated with the role ARN the AWS SDKs read.
# The role ARN only exists once the role is observed, so the annotated
# ServiceAccount is composed on the second pass, from ocds — the standard
# two-phase function-kcl pattern.
import json
import k8s.api.core.v1 as corev1
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role as role
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment as attachment

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The default audience EKS' OIDC tokens are minted for.
_default_audiences = ["sts.amazonaws.com"]

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

# The Kubernetes subject the cluster's OIDC tokens carry for a ServiceAccount.
ksa_subject = lambda namespace: str, name: str -> str {
    "system:serviceaccount:${namespace}:${name}"
}

# Trust policy: only this cluster's OIDC provider, only this ServiceAccount.
assume_policy = lambda issuer: str, subject: str, audiences: [str] -> str {
    _host = oidc_host(issuer)
    json.encode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = {Federated = issuer}
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {
                StringEquals = {
                    "${_host}:sub" = [subject]
                    "${_host}:aud" = audiences
                }
            }
        }]
    })
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Other clouds' knobs fail loudly instead of being silently dropped.
    assert not _spec?.region, "workload-identity-aws: spec.region is Azure-only — IAM roles are global"
    assert not _spec?.resourceGroup, "workload-identity-aws: spec.resourceGroup is Azure-only"
    assert not _spec?.cluster?.project, "workload-identity-aws: spec.cluster.project is GCP-only — identify the cluster with spec.cluster.oidcIssuer"
    assert not _spec?.cluster?.workloadIdentityPool, "workload-identity-aws: spec.cluster.workloadIdentityPool is GCP-only — identify the cluster with spec.cluster.oidcIssuer"

    # Without the issuer there is nothing to federate against, and a role with
    # no trust policy cannot be created at all.
    _issuer = _spec?.cluster?.oidcIssuer
    assert _issuer, "workload-identity-aws: spec.cluster.oidcIssuer is required — the IAM OIDC provider ARN (or issuer URL) of the cluster whose ServiceAccount tokens may assume this role"

    _ksa = _spec.serviceAccount
    _ksa_ns = _ksa?.namespace or _ns
    _create_ksa = True if _ksa?.create == Undefined else _ksa.create

    # A namespaced composite composes only into its own namespace, so a
    # ServiceAccount elsewhere has to be created by whoever owns that namespace.
    assert not _create_ksa or _ksa_ns == _ns, "workload-identity-aws: serviceAccount.namespace '${_ksa_ns}' differs from this resource's namespace '${_ns}' — set serviceAccount.create=false to bind a ServiceAccount in another namespace"

    _existing = _spec?.identity?.existing
    _grants = _spec?.accessPolicies or []

    # Grants on somebody else's role would silently widen an identity this
    # resource does not own.
    assert not _existing or len(_grants) == 0, "workload-identity-aws: accessPolicies cannot be attached to identity.existing — the owner of ${_existing} attaches its policies"

    # A managed-policy attachment is all-or-nothing: honouring neither scope
    # nor condition, dropping them would grant MORE access than asked for.
    assert all _g in _grants {
        not _g?.scope
    }, "workload-identity-aws: accessPolicies[].scope is not expressible on a policy attachment — put the resource scope inside the policy referenced by role"
    assert all _g in _grants {
        not _g?.condition
    }, "workload-identity-aws: accessPolicies[].condition is not expressible on a policy attachment — put the condition inside the policy referenced by role"
    assert all _g in _grants {
        (_g?.scopeType or "project") == "project"
    }, "workload-identity-aws: accessPolicies[].scopeType is GCP-only — AWS policies carry their own resource scope"

    # 1) The role. external-name pins the IAM role name to identity.name (or
    # the XR name), so the ARN is predictable and stable across recreations.
    # Its trust policy is the whole point: only this KSA may assume it.
    _role_name = _spec?.identity?.name or _name
    _items: [any] = [] if _existing else [role.Role {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _role_name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.assumeRolePolicy = assume_policy(_issuer, ksa_subject(_ksa_ns, _ksa.name), _spec?.cluster?.audiences or _default_audiences)
        if _spec?.displayName:
            spec.forProvider.description = _spec.displayName
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

    # 3) The workload's ServiceAccount, carrying the annotation the AWS SDKs
    # and the EKS pod-identity webhook read. Needs the ARN, so it waits for the
    # first observation unless an existing role was given.
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _arn = _existing or _at?.arn
    if _create_ksa and _arn:
        _items += [corev1.ServiceAccount {
            metadata = {
                name = _ksa.name
                namespace = _ksa_ns
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = "kubernetes-serviceaccount"
                    "eks.amazonaws.com/role-arn" = _arn
                }
            }
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _ns = oxr.metadata?.namespace or "default"
    _ksa = _spec.serviceAccount
    _ksa_ns = _ksa?.namespace or _ns
    _existing = _spec?.identity?.existing
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _arn = _existing or _at?.arn
    _role_name = _at?.id or _spec?.identity?.name or oxr.metadata.name
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "WorkloadIdentity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "aws"
            ready = bool(_arn)
            name = _role_name
            serviceAccount = "${_ksa_ns}/${_ksa.name}"
            subject = ksa_subject(_ksa_ns, _ksa.name)
            "cloud-url" = "https://console.aws.amazon.com/iam/home#/roles/details/${_role_name}"
            if _arn:
                arn = _arn
                principal = _arn
                annotation = _arn
            if _at?.id:
                id = _at.id
        }
    }
}
