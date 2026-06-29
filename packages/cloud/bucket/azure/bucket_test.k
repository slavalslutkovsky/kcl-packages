import .bucket

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "storage.azure.upbound.io/v1beta1"
    assert items[0].kind == "Account"
}

test_render()
