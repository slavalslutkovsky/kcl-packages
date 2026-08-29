# registry (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-artifact schema package. The portable Registry maps onto
# one Artifact Registry repository in DOCKER format, plus (when anonymous pull
# is asked for) an IAM member granting allUsers the reader role. Retention is
# expressed with the repository's own cleanup policies, so no extra MR is
# needed.
import gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository as backend
import gcp_artifact.models.v1beta1.artifact_gcpm_upbound_io_v1beta1_registry_repository_i_a_m_member as iam

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

_seconds_per_day = 86400

# Artifact Registry hosts every docker repository of a location behind one
# regional endpoint; the repository name is the first path segment after the
# project.
docker_host = lambda location: str -> str {
    "${location}-docker.pkg.dev"
}

# atProvider.id is projects/<project>/locations/<location>/repositories/<name>.
project_of = lambda id: str -> str {
    _parts = id.split("/")
    _parts[1] if len(_parts) > 1 else ""
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _location = _spec.region

    _scan = _spec?.scanOnPush
    if _scan == Undefined:
        _scan = True

    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel; both mean
    # "no retention asked for", and neither day count nor image count can be 0.
    _untagged = _spec?.untaggedRetentionDays or Undefined
    _keep = _spec?.keepLastImages or Undefined

    # Cleanup policies are a set: a DELETE policy for untagged versions past
    # their age, and a KEEP policy pinning the most recent pushes. KEEP wins
    # over DELETE in Artifact Registry, so the two compose without ordering.
    _policies = []
    if _untagged != Undefined:
        _policies += [{
            id = "delete-untagged"
            action = "DELETE"
            condition = {
                tagState = "UNTAGGED"
                olderThan = "${_untagged * _seconds_per_day}s"
            }
        }]

    if _keep != Undefined:
        _policies += [{
            id = "keep-recent"
            action = "KEEP"
            mostRecentVersions = {keepCount = _keep}
        }]

    # external-name pins the repository id to the XR name: it is part of every
    # image reference (and of the IAM binding below), so it cannot be the random
    # name Crossplane generates for the composed resource.
    _items: [any] = [backend.RegistryRepository {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if (_spec?.deletionPolicy or "Delete") == "Orphan":
            spec.managementPolicies = _orphan_policies
        spec.forProvider.location = _location
        spec.forProvider.format = "DOCKER"
        spec.forProvider.mode = "STANDARD_REPOSITORY"
        spec.forProvider.dockerConfig = {immutableTags = _spec?.immutableTags or False}
        # INHERITED follows the project's Artifact Analysis setting — the only
        # way to opt IN from the repository; DISABLED opts out unconditionally.
        spec.forProvider.vulnerabilityScanningConfig = {enablementConfig = "INHERITED" if _scan else "DISABLED"}
        if _policies:
            spec.forProvider.cleanupPolicies = _policies
            spec.forProvider.cleanupPolicyDryRun = False
        if _spec?.encryptionKeyId:
            spec.forProvider.kmsKeyName = _spec.encryptionKeyId
        if _spec?.tags:
            spec.forProvider.labels = _spec.tags
    }]

    # Anonymous pull. IAMMember carries no repositorySelector, but the
    # repository's external name is the XR name, so the binding is deterministic.
    if _spec?.publicAccess or False:
        _items += [iam.RegistryRepositoryIAMMember {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "public-reader"}
            if (_spec?.deletionPolicy or "Delete") == "Orphan":
                spec.managementPolicies = _orphan_policies
            spec.forProvider.location = _location
            spec.forProvider.repository = _name
            spec.forProvider.role = "roles/artifactregistry.reader"
            spec.forProvider.member = "allUsers"
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
# The repository path needs the project number/id, which the XR does not carry
# (it comes from the ProviderConfig) — so it is derived from the observed id.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _location = (_at?.location) or oxr.spec.region
    _host = docker_host(_location)
    _project = project_of(_at?.id or "")

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Registry"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = (_at?.id or "") != ""
            registryName = _name
            region = _location
            endpoint = _host
            if _project:
                repository = "${_host}/${_project}/${_name}"
                url = "oci://${_host}/${_project}/${_name}"
                "cloud-url" = "https://console.cloud.google.com/artifacts/docker/${_project}/${_location}/${_name}"
            else:
                "cloud-url" = "https://console.cloud.google.com/artifacts"
            if _at?.id:
                id = _at.id
        }
    }
}
