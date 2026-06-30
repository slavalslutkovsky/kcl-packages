import .bucket

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# Build a minimal observed composite XR with the given spec.
_build = lambda _spec {
    {metadata.name = "demo", spec = _spec}
}

# The single GCS Bucket forProvider block from a render() of the given spec.
_fp = lambda _spec {
    bucket.render(_build(_spec))[0].spec.forProvider
}

# True if any native lifecycle rule has the given serialized action type.
_has_action = lambda _rules, _t {
    len([_r for _r in _rules if _r["action"]["type"] == _t]) > 0
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec (region only): GCS expresses everything inline -> exactly one MR.
test_render = lambda {
    items = bucket.render(_build({region = "us-central1"}))
    assert len(items) == 1, "GCS render must emit exactly one Bucket"
    assert items[0].apiVersion == "storage.gcp.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Bucket", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    assert items[0].spec.forProvider.location == "us-central1", "region -> forProvider.location"
}

# ---- render: storage class --------------------------------------------------

# archive -> ARCHIVE and a SetStorageClass lifecycle transition is injected.
test_storage_class = lambda {
    fp = _fp({region = "us-central1", storageClass = "archive"})
    assert fp.storageClass == "ARCHIVE", "archive -> ARCHIVE"
    assert _has_action(fp.lifecycleRule, "SetStorageClass"), "non-standard tier must add SetStorageClass rule"
    # standard tier maps through but injects no lifecycle transition.
    fp2 = _fp({region = "us-central1", storageClass = "standard"})
    assert fp2.storageClass == "STANDARD", "standard -> STANDARD"
    assert fp2?.lifecycleRule == Undefined, "standard tier must not inject a lifecycle rule"
    # full tier map.
    assert _fp({region = "us-central1", storageClass = "nearline"}).storageClass == "NEARLINE", "nearline -> NEARLINE"
    assert _fp({region = "us-central1", storageClass = "cold"}).storageClass == "COLDLINE", "cold -> COLDLINE"
}

# ---- render: versioning -----------------------------------------------------

test_versioning = lambda {
    assert _fp({region = "us-central1"}).versioning.enabled == True, "versioning defaults to enabled"
    assert _fp({region = "us-central1", versioning = False}).versioning.enabled == False, "versioning=false -> disabled"
}

# ---- render: public access / uniform access ---------------------------------

test_block_public_access = lambda {
    assert _fp({region = "us-central1"}).publicAccessPrevention == "enforced", "default blockPublicAccess -> enforced"
    assert _fp({region = "us-central1", blockPublicAccess = True}).publicAccessPrevention == "enforced", "true -> enforced"
    assert _fp({region = "us-central1", blockPublicAccess = False}).publicAccessPrevention == "inherited", "false -> inherited"
}

test_uniform_access = lambda {
    assert _fp({region = "us-central1"}).uniformBucketLevelAccess == True, "uniformAccess defaults true"
    assert _fp({region = "us-central1", uniformAccess = False}).uniformBucketLevelAccess == False, "uniformAccess=false maps through"
}

# ---- render: encryption -----------------------------------------------------

test_encryption = lambda {
    fp = _fp({region = "us-central1", encryptionKmsKeyId = "projects/p/locations/l/keyRings/r/cryptoKeys/k"})
    assert fp.encryption.defaultKmsKeyName == "projects/p/locations/l/keyRings/r/cryptoKeys/k", "kms key -> defaultKmsKeyName"
    # no key -> no encryption block.
    assert _fp({region = "us-central1"})?.encryption == Undefined, "no kms key -> no encryption block"
}

# ---- render: retention ------------------------------------------------------

test_retention = lambda {
    fp = _fp({region = "us-central1", retention = {days = 7, mode = "compliance"}})
    assert fp.retentionPolicy.retentionPeriod == 7 * 86400, "days -> seconds"
    assert fp.retentionPolicy.isLocked == True, "compliance -> locked"
    fp2 = _fp({region = "us-central1", retention = {days = 3, mode = "governance"}})
    assert fp2.retentionPolicy.retentionPeriod == 3 * 86400, "days -> seconds (governance)"
    assert fp2.retentionPolicy.isLocked == False, "governance -> not locked"
}

# ---- render: deletion policy ------------------------------------------------

test_deletion_policy = lambda {
    mr = bucket.render(_build({region = "us-central1", deletionPolicy = "Orphan"}))[0]
    assert mr.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"], "Orphan -> orphan management policies"
    # Delete (default) does not set the orphan list; the provider schema default ["*"] applies.
    mr2 = bucket.render(_build({region = "us-central1"}))[0]
    assert mr2.spec.managementPolicies == ["*"], "Delete default -> provider default management policies"
}

# ---- render: tags -----------------------------------------------------------

test_tags = lambda {
    tags = {env = "prod", team = "core"}
    assert _fp({region = "us-central1", tags = tags}).labels == tags, "tags -> forProvider.labels"
    assert _fp({region = "us-central1"})?.labels == Undefined, "no tags -> no labels"
}

# ---- render: lifecycle rules + cors -----------------------------------------

test_lifecycle_rules = lambda {
    # No storageClass tier here, so the only native rules come from lifecycleRules.
    fp = _fp({region = "us-central1", lifecycleRules = [
        {id = "expire", expirationDays = 30}
        {id = "tier", transitionDays = 60, transitionStorageClass = "cold"}
    ]})
    rules = fp.lifecycleRule
    assert len(rules) == 2, "two abstract rules -> two native rules"
    assert rules[0]["action"]["type"] == "Delete", "expirationDays -> Delete action"
    assert rules[0].condition.age == 30, "Delete rule keeps the expiration age"
    assert rules[1]["action"]["type"] == "SetStorageClass", "transition -> SetStorageClass action"
    assert rules[1]["action"].storageClass == "COLDLINE", "transition tier mapped to COLDLINE"
    assert rules[1].condition.age == 60, "SetStorageClass rule keeps the transition age"
}

test_cors = lambda {
    fp = _fp({region = "us-central1", cors = [
        {origins = ["https://app.example.com"], methods = ["GET", "PUT"], headers = ["X-Foo"], maxAgeSeconds = 120}
    ]})
    assert fp.cors[0].origin == ["https://app.example.com"], "cors origins -> origin"
    assert fp.cors[0].method == ["GET", "PUT"], "cors methods -> method"
    assert fp.cors[0].responseHeader == ["X-Foo"], "cors headers -> responseHeader"
    assert fp.cors[0].maxAgeSeconds == 120, "cors maxAgeSeconds maps through"
}

# ---- status -----------------------------------------------------------------

# Pre-creation: no observed composed resources.
test_status_pending = lambda {
    dxr = bucket.status(_build({region = "us-central1"}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr keeps composite apiVersion"
    assert dxr.kind == "Bucket", "dxr keeps composite kind"
    assert dxr.status.ready == False, "not ready before creation"
    assert dxr.status.provider == "gcp", "provider gcp"
    assert dxr.status["cloud-url"].startswith("https://console.cloud.google.com/storage/browser/"), "console url prefix"
    assert dxr.status.endpoint == "demo.storage.googleapis.com", "endpoint derived from name"
}

# Observed: provider has reconciled the bucket.
test_status_ready = lambda {
    ocds = {managed = {Resource = {status = {atProvider = {
        url = "gs://demo"
        selfLink = "https://www.googleapis.com/storage/v1/b/demo"
        id = "demo"
        location = "US-CENTRAL1"
        storageClass = "ARCHIVE"
    }}}}}
    dxr = bucket.status(_build({region = "us-central1"}), ocds)
    assert dxr.status.ready == True, "ready once observed with an id"
    assert dxr.status.url == "gs://demo", "url from atProvider"
    assert dxr.status.selfLink == "https://www.googleapis.com/storage/v1/b/demo", "selfLink from atProvider"
    assert dxr.status.id == "demo", "id from atProvider"
    assert dxr.status.region == "US-CENTRAL1", "region from atProvider.location"
}

test_render()
test_storage_class()
test_versioning()
test_block_public_access()
test_uniform_access()
test_encryption()
test_retention()
test_deletion_policy()
test_tags()
test_lifecycle_rules()
test_cors()
test_status_pending()
test_status_ready()
