import .bucket

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "storage.azure.m.upbound.io/v1beta1"
    assert items[0].kind == "Account"
}

test_storage_class = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}
    items = bucket.render(oxr)
    assert len(items) == 2, "expected account + management policy"
    assert items[1].kind == "ManagementPolicy"
    assert items[0].spec.forProvider.accessTier == "Cold", "archive accessTier -> Cold"
}

test_render()
test_storage_class()
