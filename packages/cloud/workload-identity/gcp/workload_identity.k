# workload-identity (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-cloudplatform schema package plus core Kubernetes.
# The portable WorkloadIdentity maps onto GKE Workload Identity: a Service
# Account, a ServiceAccountIAMMember granting
# roles/iam.workloadIdentityUser to serviceAccount:<pool>[<ns>/<ksa>], and one
# IAM member per accessPolicies entry at the project, folder or organization
# level. The Kubernetes ServiceAccount itself is composed too, annotated with
# the service-account e-mail GKE reads.
# The grant member string (serviceAccount:<email>) and the annotation value
# only exist once the service account is observed, so both are composed on the
# second pass, from ocds — the standard two-phase function-kcl pattern.
import k8s.api.core.v1 as corev1
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account as sa
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_service_account_i_a_m_member as samember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_project_i_a_m_member as projectmember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_folder_i_a_m_member as foldermember
import gcp_cloudplatform.models.v1beta1.cloudplatform_gcpm_upbound_io_v1beta1_organization_i_a_m_member as orgmember

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The pool member a GKE-hosted KSA authenticates as.
ksa_member = lambda pool: str, namespace: str, name: str -> str {
    "serviceAccount:${pool}[${namespace}/${name}]"
}

# IAM members outside the SA itself are addressed by resource level; the
# resource kind (and the field naming the target) differs per level.
grant = lambda idx: int, g: any, member: str, name: str, mp: any -> any {
    _st = g?.scopeType or "project"
    _ann = {"krm.kcl.dev/composition-resource-name" = "grant-${idx}"}
    _cond = {
        expression = g.condition.expression
        # The GCP API requires a title; default one per grant.
        title = g.condition?.title or "${name}-grant-${idx}"
        if g.condition?.description:
            description = g.condition.description
    } if g?.condition else Undefined

    # A shared `_out` cannot hold three different schema types (KCL narrows it
    # to the first branch's type), so the level picks the value directly.
    (orgmember.OrganizationIAMMember {
        metadata.annotations = _ann
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.orgId = g.scope
        spec.forProvider.role = g.role
        spec.forProvider.member = member
        if _cond:
            spec.forProvider.condition = _cond
    } if _st == "organization" else foldermember.FolderIAMMember {
        metadata.annotations = _ann
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.folder = g.scope
        spec.forProvider.role = g.role
        spec.forProvider.member = member
        if _cond:
            spec.forProvider.condition = _cond
    } if _st == "folder" else projectmember.ProjectIAMMember {
        metadata.annotations = _ann
        if mp:
            spec.managementPolicies = mp
        spec.forProvider.role = g.role
        spec.forProvider.member = member
        if g?.scope:
            spec.forProvider.project = g.scope
        if _cond:
            spec.forProvider.condition = _cond
    })
}

# The workload identity pool the cluster's KSA tokens come from.
pool = lambda spec: any -> str {
    _c = spec?.cluster
    _p = _c?.workloadIdentityPool or ("${_c.project}.svc.id.goog" if _c?.project else Undefined)
    assert _p, "workload-identity-gcp: spec.cluster.project (or spec.cluster.workloadIdentityPool) is required — it names the pool the cluster's ServiceAccount tokens are trusted from"
    _p
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _ns = oxr.metadata?.namespace or "default"
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Other clouds' knobs fail loudly instead of being silently dropped.
    assert not _spec?.region, "workload-identity-gcp: spec.region is Azure-only — GCP service accounts are global"
    assert not _spec?.resourceGroup, "workload-identity-gcp: spec.resourceGroup is Azure-only"
    assert not _spec?.cluster?.oidcIssuer, "workload-identity-gcp: spec.cluster.oidcIssuer is AWS/Azure-only — GKE trust goes through the workload identity pool, so set spec.cluster.project (or workloadIdentityPool) instead"
    assert not _spec?.cluster?.audiences, "workload-identity-gcp: spec.cluster.audiences is AWS/Azure-only — the GKE pool member carries no audience"

    _ksa = _spec.serviceAccount
    _ksa_ns = _ksa?.namespace or _ns
    _create_ksa = True if _ksa?.create == Undefined else _ksa.create
    _pool = pool(_spec)

    # A namespaced composite composes only into its own namespace, so a
    # ServiceAccount elsewhere has to be created by whoever owns that namespace.
    assert not _create_ksa or _ksa_ns == _ns, "workload-identity-gcp: serviceAccount.namespace '${_ksa_ns}' differs from this resource's namespace '${_ns}' — set serviceAccount.create=false to bind a ServiceAccount in another namespace"

    _existing = _spec?.identity?.existing
    _grants = _spec?.accessPolicies or []

    # Grants on somebody else's service account would silently widen an
    # identity this resource does not own.
    assert not _existing or len(_grants) == 0, "workload-identity-gcp: accessPolicies cannot be granted on identity.existing — the owner of ${_existing} grants its roles"
    assert all _g in _grants {
        (_g?.scopeType or "project") == "project" or bool(_g?.scope)
    }, "workload-identity-gcp: accessPolicies[].scope is required for scopeType folder/organization (the folder or organization id)"

    _account_id = _spec?.identity?.name or _name

    # 1) The service account. external-name pins the accountId (GCP: 6-30
    # chars, lowercase letters/digits/hyphens), so the e-mail is stable across
    # recreations.
    _items: [any] = [] if _existing else [sa.ServiceAccount {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _account_id
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.displayName = _spec?.displayName or _name
    }]

    # 2) The binding: the KSA may impersonate the service account. When the
    # service account is composed here it is referenced by controller ref; an
    # existing one by its fully-qualified name.
    _items += [samember.ServiceAccountIAMMember {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "binding"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.role = "roles/iam.workloadIdentityUser"
        spec.forProvider.member = ksa_member(_pool, _ksa_ns, _ksa.name)
        if _existing:
            spec.forProvider.serviceAccountId = "projects/-/serviceAccounts/${_existing}"
        else:
            spec.forProvider.serviceAccountIdSelector.matchControllerRef = True
    }]

    # 3) Grants: one IAM member per accessPolicies entry, at its scope level.
    # member is the observed serviceAccount:<email>, so these appear once the
    # service account exists.
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _member = _at?.member or ("serviceAccount:${_at.email}" if _at?.email else Undefined)
    if _member:
        _items += [grant(_i, _g, _member, _name, _mp) for _i, _g in _grants]

    # 4) The workload's ServiceAccount, carrying the annotation GKE reads to
    # map it onto the service account. Needs the e-mail, so it waits for the
    # first observation unless an existing identity was given.
    _email = _existing or _at?.email
    if _create_ksa and _email:
        _items += [corev1.ServiceAccount {
            metadata = {
                name = _ksa.name
                namespace = _ksa_ns
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = "kubernetes-serviceaccount"
                    "iam.gke.io/gcp-service-account" = _email
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
    _email = _existing or _at?.email
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "WorkloadIdentity"
        metadata.name = oxr.metadata.name
        status = {
            provider = "gcp"
            ready = bool(_email)
            name = _spec?.identity?.name or oxr.metadata.name
            serviceAccount = "${_ksa_ns}/${_ksa.name}"
            subject = ksa_member(pool(_spec), _ksa_ns, _ksa.name)
            if _email:
                email = _email
                annotation = _email
                principal = "serviceAccount:${_email}"
            if _at?.id:
                id = _at.id
            if _at?.uniqueId and _at?.project:
                "cloud-url" = "https://console.cloud.google.com/iam-admin/serviceaccounts/details/${_at.uniqueId}?project=${_at.project}"
        }
    }
}
