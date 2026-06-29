import .bucket

test_render = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-central1"}}
    items = bucket.render(oxr)
    assert len(items) == 1, "expected one managed resource"
    assert items[0].apiVersion == "s3.aws.upbound.io/v1beta1"
    assert items[0].kind == "Bucket"
}

test_render()
