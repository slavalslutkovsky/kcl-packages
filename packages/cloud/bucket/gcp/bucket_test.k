import .bucket

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "storage.gcp.m.upbound.io/v1beta1"
    assert items[0].kind == "Bucket"
}

test_storage_class = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1", storageClass = "archive"}}
    items = bucket.render(oxr)
    assert items[0].spec.forProvider.storageClass == "ARCHIVE", "archive -> ARCHIVE"
}

test_render()
test_storage_class()
