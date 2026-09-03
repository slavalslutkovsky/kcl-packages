import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_bucket as bucket

# The shipped example XRs are instances of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml.
test_examples_are_buckets = lambda {
    _files = ["examples/bucket-aws.yaml", "examples/bucket-azure.yaml", "examples/bucket-gcp.yaml", "examples/bucket-rustfs.yaml"]
    _xrs = [bucket.Bucket {**yaml.decode(file.read(f))} for f in _files]
    assert len(_xrs) == 4
    assert all x in _xrs {x.kind == "Bucket" and x.apiVersion == "cloud.example.org/v1alpha1"}
    assert all x in _xrs {x.spec.region != ""}, "region is the one required field"
    aws = _xrs[0]
    assert aws.spec.crossplane.compositionSelector.matchLabels.provider == "aws", "spec.crossplane is part of the schema"
    assert aws.spec.retention.days == 30 and aws.spec.retention.mode == "governance"
    assert aws.spec.lifecycleRules[0].transitionStorageClass == "cold"
}

test_defaults_match_xrd = lambda {
    # XRD defaults come through the generated schema, so a composer that omits a
    # field renders exactly what the API server would have filled in.
    b = bucket.Bucket {spec.region = "us-east-1"}
    assert b.spec.storageClass == "standard"
    assert b.spec.versioning == True and b.spec.blockPublicAccess == True and b.spec.uniformAccess == True
    assert b.spec.deletionPolicy == "Delete"
}
