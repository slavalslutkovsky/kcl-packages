# Unit tests for the registry (gcp) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
import .registry

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Registry", metadata.name = "demo", spec = {region = "us-central1"} | extra}
}

# The Artifact Registry repository forProvider block for the given spec.
_fp = lambda extra: any -> any {
    registry.render(_build(extra))[0].spec.forProvider
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# The cleanup policy with the given id, else Undefined.
_policy = lambda extra: any, id: str -> any {
    _hits = [_p for _p in (_fp(extra)?.cleanupPolicies or []) if _p.id == id]
    _hits[0] if _hits else Undefined
}

# 1) Minimal spec: one DOCKER standard repository, scanning inherited from the
#    project, tags mutable, no cleanup policies.
test_render_minimal = lambda {
    items = registry.render(_build({}))
    assert len(items) == 1, "minimal spec must render exactly one managed resource"
    assert items[0].apiVersion == "artifact.gcp.m.upbound.io/v1beta1", "wrong RegistryRepository apiVersion"
    assert items[0].kind == "RegistryRepository", "first item must be the RegistryRepository"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the repository id must be pinned to the XR name"
    _f = items[0].spec.forProvider
    assert _f.location == "us-central1", "region must become the location"
    assert _f.format == "DOCKER", "the abstraction is a container registry"
    assert _f.mode == "STANDARD_REPOSITORY", "a registry XR is not a remote/virtual repository"
    assert _f.dockerConfig.immutableTags == False, "tags must be mutable by default"
    assert _f.vulnerabilityScanningConfig.enablementConfig == "INHERITED", "scanOnPush must default to INHERITED"
    assert _f?.cleanupPolicies == Undefined, "no retention means no cleanup policies"
    assert _f?.kmsKeyName == Undefined, "no CMEK means no kmsKeyName"
}

# 2) immutableTags / scanOnPush flip the repository fields.
test_repository_flags = lambda {
    _f = _fp({immutableTags = True, scanOnPush = False})
    assert _f.dockerConfig.immutableTags == True, "immutableTags must reach dockerConfig"
    assert _f.vulnerabilityScanningConfig.enablementConfig == "DISABLED", "scanOnPush=false must disable scanning"
}

# 3) encryptionKeyId becomes the CMEK key, labels come from tags.
test_encryption_and_labels = lambda {
    _key = "projects/p/locations/us-central1/keyRings/r/cryptoKeys/k"
    _f = _fp({encryptionKeyId = _key, tags = {team = "platform"}})
    assert _f.kmsKeyName == _key, "CMEK key must be carried through"
    assert _f.labels == {team = "platform"}, "tags must become labels"
}

# 4) Retention becomes cleanup policies: DELETE for untagged past its age
#    (expressed in seconds), KEEP for the most recent pushes.
test_cleanup_untagged = lambda {
    _p = _policy({untaggedRetentionDays = 30}, "delete-untagged")
    assert _p != Undefined, "untagged retention must add a DELETE policy"
    assert _p.action == "DELETE", "untagged policy must delete"
    assert _p.condition.tagState == "UNTAGGED", "policy must target untagged versions"
    assert _p.condition.olderThan == "2592000s", "30 days must be expressed as seconds"
    assert _fp({untaggedRetentionDays = 30}).cleanupPolicyDryRun == False, "policies must actually run"
}
test_cleanup_keep_recent = lambda {
    _p = _policy({keepLastImages = 12}, "keep-recent")
    assert _p != Undefined, "keepLastImages must add a KEEP policy"
    assert _p.action == "KEEP", "the count policy must keep, not delete"
    assert _p.mostRecentVersions.keepCount == 12, "keepLastImages must be carried through"
}
test_cleanup_both = lambda {
    assert len(_fp({untaggedRetentionDays = 7, keepLastImages = 5}).cleanupPolicies) == 2, "both policies must be present"
}

# 5) publicAccess adds the allUsers reader binding, pinned to the repository by
#    its external name (the XR name).
test_public_access = lambda {
    items = registry.render(_build({publicAccess = True}))
    assert _kinds(items) == ["RegistryRepository", "RegistryRepositoryIAMMember"], "publicAccess must add the IAM member"
    _f = items[1].spec.forProvider
    assert _f.member == "allUsers", "anonymous pull means allUsers"
    assert _f.role == "roles/artifactregistry.reader", "anonymous access must be read-only"
    assert _f.repository == "demo", "binding must name the composed repository"
    assert _f.location == "us-central1", "binding must be in the repository's location"
}
test_private_by_default = lambda {
    assert _kinds(registry.render(_build({}))) == ["RegistryRepository"], "no IAM member without publicAccess"
}

# 6) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR.
test_deletion_policy_orphan = lambda {
    items = registry.render(_build({deletionPolicy = "Orphan", publicAccess = True}))
    _missing = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = registry.render(_build({publicAccess = True}))
    _stamped = [_i.kind for _i in items if _i.spec.managementPolicies == _orphan]
    assert _stamped == [], "Delete must not set the orphan policies, set on: ${_stamped}"
}

# 7) status before creation: the regional host is known, the project is not, so
#    no repository path is invented.
test_status_pre_creation = lambda {
    dxr = registry.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Registry", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "gcp", "provider must be gcp"
    assert dxr.status.endpoint == "us-central1-docker.pkg.dev", "endpoint is the regional docker host"
    assert dxr.status?.repository == Undefined, "the project is unknown until observed"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/artifacts", "cloud-url falls back to the Artifact Registry list"
}

# 8) status after creation: the project is parsed out of the observed id.
test_status_observed = lambda {
    ocds = {
        managed.Resource.status.atProvider = {
            id = "projects/my-project/locations/us-central1/repositories/demo"
            name = "demo"
            location = "us-central1"
            createTime = "2026-01-01T00:00:00Z"
        }
    }
    dxr = registry.status(_build({}), ocds)
    assert dxr.status.ready == True, "an observed id must mark the registry ready"
    assert dxr.status.repository == "us-central1-docker.pkg.dev/my-project/demo", "repository is the full push path"
    assert dxr.status.url == "oci://us-central1-docker.pkg.dev/my-project/demo", "url must be the oci:// form"
    assert dxr.status.id == "projects/my-project/locations/us-central1/repositories/demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://console.cloud.google.com/artifacts/docker/my-project/us-central1/demo", "cloud-url must address the repository"
}

test_render_minimal()
test_repository_flags()
test_encryption_and_labels()
test_cleanup_untagged()
test_cleanup_keep_recent()
test_cleanup_both()
test_public_access()
test_private_by_default()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_status_pre_creation()
test_status_observed()
