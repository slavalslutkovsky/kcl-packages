# iam (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-cloudplatform schema package. The portable Identity
# maps onto a Service Account; each accessPolicies entry becomes a
# ProjectIAMMember (with optional IAM condition) and trust.identities become
# ServiceAccountIAMMembers granting roles/iam.serviceAccountTokenCreator.
# The grant member string (serviceAccount:<email>) only exists once the
# service account is observed, so grants are composed on the second pass,
# from ocds — the standard two-phase function-kcl pattern.
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account as sa
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_member as projectmember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account_i_a_m_member as samember

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # AWS-only knobs and inexpressible trust fail loudly instead of silently
    # changing what the identity can do or who can use it.
    assert not _spec?.inlinePolicy, "iam-gcp: spec.inlinePolicy is AWS-only — express fine-grained access as accessPolicies[].condition"
    assert not _spec?.permissionsBoundary, "iam-gcp: spec.permissionsBoundary is AWS-only"
    assert not _spec?.trust?.services, "iam-gcp: trust.services is AWS-only — GCP services act through their own agents, not by assuming yours"
    assert not _spec?.trust?.federated, "iam-gcp: trust.federated is not expressible here — pass workload-identity members (principal://…, serviceAccount:…) via trust.identities instead"

    # 1) The service account. external-name pins the accountId to the XR name
    # (GCP: 6-30 chars, lowercase letters/digits/hyphens), so the e-mail is
    # stable across recreations.
    _items: [any] = [sa.ServiceAccount {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.displayName = _spec?.displayName or _name
    }]

    # 2) Impersonation trust: who may mint tokens for this service account.
    # Bound via matchControllerRef, so no observed state is needed.
    _items += [samember.ServiceAccountIAMMember {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "trust-${_i}"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.role = "roles/iam.serviceAccountTokenCreator"
        spec.forProvider.member = _id
        spec.forProvider.serviceAccountIdSelector.matchControllerRef = True
    } for _i, _id in (_spec?.trust?.identities or [])]

    # 3) Grants: one ProjectIAMMember per accessPolicies entry. member is the
    # observed serviceAccount:<email>, so these appear once the SA exists.
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _member = _at?.member
    if _member:
        _items += [projectmember.ProjectIAMMember {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "grant-${_i}"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.role = _g.role
            spec.forProvider.member = _member
            if _g?.scope:
                spec.forProvider.project = _g.scope
            if _g?.condition:
                spec.forProvider.condition = {
                    expression = _g.condition.expression
                    # The GCP API requires a title; default one per grant.
                    title = _g.condition?.title or "${_name}-grant-${_i}"
                    if _g.condition?.description:
                        description = _g.condition.description
                }
        } for _i, _g in (_spec?.accessPolicies or [])]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Identity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            ready = (_at?.email or "") != ""
            name = oxr.metadata.name
            if _at:
                if _at?.email:
                    email = _at.email
                    principal = (_at?.member) or "serviceAccount:${_at.email}"
                if _at?.id:
                    id = _at.id
                if _at?.uniqueId and _at?.project:
                    "cloud-url" = "https://console.cloud.google.com/iam-admin/serviceaccounts/details/${_at.uniqueId}?project=${_at.project}"
        }
    }
}
