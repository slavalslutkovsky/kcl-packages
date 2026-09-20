import .bucket

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "s3.aws.m.upbound.io/v1beta1"
    assert items[0].kind == "Bucket"
    assert items[0].metadata.annotations?["crossplane.io/external-name"] == Undefined, "a created bucket pins nothing"
}

test_storage_class = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}
    items = bucket.render(oxr)
    assert len(items) == 2, "expected bucket + lifecycle config"
    assert items[1].kind == "BucketLifecycleConfiguration"
    assert items[1].spec.forProvider.bucketSelector.matchControllerRef == True, "created buckets bind the companion via the selector"
}

test_deletion_policy = lambda {
    items = bucket.render({metadata.name = "demo", spec = {region = "us-east-1", storageClass = "cold", deletionPolicy = "Orphan"}})
    assert items[0].spec.managementPolicies == _orphan and items[1].spec.managementPolicies == _orphan, "Orphan -> orphan policies on both MRs"
    assert bucket.render({metadata.name = "demo", spec = {region = "us-east-1"}})[0].spec.managementPolicies == ["*"], "Delete -> provider default"
}

# Adopting pins both MRs to the existing bucket name, observe is read-only,
# and the companion names the bucket instead of resolving the selector.
test_import = lambda {
    obs = bucket.render({metadata.name = "demo", spec = {region = "us-east-1", storageClass = "cold", import = {existingName = "legacy", source = "other"}}})
    assert len(obs) == 2, "both MRs render when adopting"
    assert obs[0].metadata.annotations["crossplane.io/external-name"] == "legacy" and obs[1].metadata.annotations["crossplane.io/external-name"] == "legacy", "both pinned"
    assert obs[0].spec.managementPolicies == ["Observe"] and obs[1].spec.managementPolicies == ["Observe"], "observe-only on both"
    assert obs[1].spec.forProvider.bucket == "legacy" and obs[1].spec.forProvider?.bucketSelector == Undefined, "companion names the bucket directly"
    assert obs[0].metadata.annotations["cloud.example.org/imported-from"] == "other", "source recorded"
    man = bucket.render({metadata.name = "demo", spec = {region = "us-east-1", import = {existingName = "legacy", mode = "manage"}}})
    assert man[0].spec.managementPolicies == ["*"], "manage + Delete -> provider default"
}

test_mode_of = lambda {
    assert bucket.mode_of({
        spec = {region = "us-east-1"}
    }) == "created"
    assert bucket.mode_of({
        spec = {region = "us-east-1", import = {existingName = "x"}}
    }) == "observe"
    assert bucket.mode_of({
        spec = {region = "us-east-1", import = {existingName = "x", mode = "manage"}}
    }) == "managed"
}

test_render()
test_storage_class()
test_deletion_policy()
test_import()
test_mode_of()
