import file
import yaml
import models.v1alpha1.cloud_example_org_v1alpha1_queue as queue

# The shipped example XRs are instances of the generated schema: a field the
# XRD does not declare, or a mistyped one, fails here before it fails on the
# cluster — and proves models/ is in step with xrd.yaml.
test_examples_are_queues = lambda {
    _files = ["examples/queue-aws.yaml", "examples/queue-gcp.yaml", "examples/queue-nats.yaml"]
    _xrs = [queue.Queue {**yaml.decode(file.read(f))} for f in _files]
    assert len(_xrs) == 3
    assert all x in _xrs {x.kind == "Queue" and x.apiVersion == "cloud.example.org/v1alpha1"}
    assert all x in _xrs {x.spec.region != ""}, "region is the one required field"
    aws = _xrs[0]
    assert aws.spec.crossplane.compositionSelector.matchLabels.provider == "aws", "spec.crossplane is part of the schema"
    assert aws.spec.deadLetter.enabled == True and aws.spec.deadLetter.maxReceives == 5
}

test_defaults_match_xrd = lambda {
    q = queue.Queue {spec.region = "us-east-1"}
    assert q.spec.fifo == False
    assert q.spec.visibilityTimeoutSeconds == 30 and q.spec.retentionDays == 4
    assert q.spec.deletionPolicy == "Delete" and q.spec.persistence == True
}
