import file
import yaml
import .inbox

_anno = "krm.kcl.dev/composition-resource-name"

# ---- helpers ----------------------------------------------------------------
# NOTE: KCL normalizes the leading underscore, so a helper here shadows ANY
# lambda parameter of the same normalized name over in inbox.k (`_spec` would
# shadow render()'s `spec`). Hence `_build`, `_child`, `_min`.
_build = lambda _s {
    {apiVersion = "platform.example.org/v1alpha1", kind = "Inbox", metadata.name = "demo", spec = _s}
}

# The smallest spec the XRD admits: provider and region.
_min = lambda _provider: str {
    {provider = _provider, region = "us-east-1" if _provider == "aws" else "europe-west1"}
}

# Pick a child out of a render() by its composition-resource-name.
_child = lambda _items, _res: str {
    [i for i in _items if i.metadata.annotations[_anno] == _res][0]
}

_selector = lambda _c {
    _c.spec.crossplane.compositionSelector.matchLabels.provider
}

# Shape as function-kcl hands it over: ocds[<resource-name>].Resource.status is
# the CHILD XR's status, i.e. what its own XRD declares.
_wrap = lambda _st {
    {
        Resource = {status = _st}
    }
}

_bucket_observed = {
    ready = True
    provider = "aws"
    bucketName = "demo-bucket"
    url = "s3://demo-bucket"
    region = "us-east-1"
}

_queue_observed = {
    ready = True
    provider = "aws"
    queueName = "demo-queue"
    topic = "demo-queue"
    url = "https://sqs.us-east-1.amazonaws.com/111122223333/demo-queue"
    deadLetterUrl = "https://sqs.us-east-1.amazonaws.com/111122223333/demo-queue-dlq"
}

# ---- render: shape ----------------------------------------------------------
test_two_typed_children = lambda {
    items = inbox.render(_build(_min("aws")))
    assert len(items) == 2, "a Bucket and a Queue, nothing else"
    assert [i.kind for i in items] == ["Bucket", "Queue"]
    assert all i in items {i.apiVersion == "cloud.example.org/v1alpha1"}
    assert all i in items {i.metadata?.namespace == Undefined}, "children inherit the XR namespace"
    b = _child(items, "bucket")
    q = _child(items, "queue")
    assert b.metadata.name == "demo-bucket" and q.metadata.name == "demo-queue"
    assert _selector(b) == "aws" and _selector(q) == "aws", "one backend for the pair"
    assert b.spec.region == "us-east-1" and q.spec.region == "us-east-1"
}

test_inbox_defaults_override_child_defaults = lambda {
    items = inbox.render(_build(_min("gcp")))
    b = _child(items, "bucket")
    q = _child(items, "queue")

    # Where the Inbox disagrees with its children's XRD defaults the value is
    # sent explicitly, so a sparse Inbox never inherits the child's choice.
    assert b.spec.versioning == False, "Bucket defaults versioning on; an inbox turns it off"
    assert q.spec.deadLetter.enabled == True, "Queue defaults dead-lettering off; an inbox turns it on"
    assert q.spec.deadLetter.maxReceives == 5
    # Where they agree the typed child carries the XRD default explicitly.
    assert b.spec.storageClass == "standard" and b.spec.blockPublicAccess == True and b.spec.uniformAccess == True
    assert q.spec.fifo == False and q.spec.visibilityTimeoutSeconds == 30 and q.spec.retentionDays == 4
    assert b.spec.deletionPolicy == "Delete" and q.spec.deletionPolicy == "Delete"
    assert b.spec?.lifecycleRules == Undefined, "no expirationDays → no lifecycle rule"
    assert b.spec?.encryptionKmsKeyId == Undefined and q.spec?.encryptionKmsKeyId == Undefined
}

test_pair_wide_fields_forwarded = lambda {
    items = inbox.render(_build(_min("aws") | {
        deletionPolicy = "Orphan"
        encryptionKmsKeyId = "arn:aws:kms:us-east-1:1:key/k"
        tags = {team = "platform"}
    }))
    assert all i in items {i.spec.deletionPolicy == "Orphan"}
    assert all i in items {i.spec.encryptionKmsKeyId == "arn:aws:kms:us-east-1:1:key/k"}, "one key for payload and work item"
    assert all i in items {i.spec.tags.team == "platform"}
}

test_sizing_forwarded_by_presence = lambda {
    items = inbox.render(_build(_min("aws") | {
        bucket = {storageClass = "cold", versioning = True, forceDestroy = True, expirationDays = 14}
        # 0 is a real visibility timeout and false a real fifo: presence, not truthiness
        queue = {fifo = False, visibilityTimeoutSeconds = 0, retentionDays = 7, deadLetter = {enabled = False}}
    }))
    b = _child(items, "bucket")
    q = _child(items, "queue")
    assert b.spec.storageClass == "cold" and b.spec.versioning == True and b.spec.forceDestroy == True
    lr = b.spec.lifecycleRules[0]
    assert len(b.spec.lifecycleRules) == 1 and lr.id == "expire-payloads" and lr.prefix == "" and lr.expirationDays == 14
    assert q.spec.fifo == False and q.spec.visibilityTimeoutSeconds == 0 and q.spec.retentionDays == 7
    assert q.spec.deadLetter.enabled == False, "explicit false wins over the inbox default"
    assert q.spec.deadLetter.maxReceives == 5, "unset maxReceives keeps the default beside an explicit enabled"
}

# ---- examples ---------------------------------------------------------------
test_examples_render = lambda {
    aws = inbox.render(yaml.decode(file.read("../xrd/examples/inbox-aws.yaml")))
    gcp = inbox.render(yaml.decode(file.read("../xrd/examples/inbox-gcp.yaml")))
    assert _selector(_child(aws, "queue")) == "aws" and _selector(_child(gcp, "bucket")) == "gcp"
    assert _child(aws, "bucket").spec.lifecycleRules[0].expirationDays == 14
    assert _child(aws, "queue").spec.visibilityTimeoutSeconds == 120
    assert _child(gcp, "bucket").spec.storageClass == "nearline"
    assert all i in gcp {i.spec.deletionPolicy == "Orphan"}
}

# ---- status -----------------------------------------------------------------
test_status_first_reconcile = lambda {
    st = inbox.status(_build(_min("aws")), {})
    assert st.kind == "Inbox" and st.apiVersion == "platform.example.org/v1alpha1"
    assert st.metadata.name == "demo"
    assert st.status.provider == "aws"
    assert st.status.ready == False
    assert st.status.components == {bucket = False, queue = False}
    assert st.status?.bucketName == Undefined and st.status?.queueUrl == Undefined, "nothing published yet"
}

test_status_half_ready = lambda {
    st = inbox.status(_build(_min("aws")), {bucket = _wrap(_bucket_observed)})
    assert st.status.ready == False, "a bucket with no queue is not an inbox"
    assert st.status.components == {bucket = True, queue = False}
    assert st.status.bucketName == "demo-bucket" and st.status.bucketUrl == "s3://demo-bucket"
}

test_status_copies_child_coordinates = lambda {
    st = inbox.status(_build(_min("aws")), {bucket = _wrap(_bucket_observed), queue = _wrap(_queue_observed)})
    assert st.status.ready == True
    assert st.status.components == {bucket = True, queue = True}
    assert st.status.bucketName == "demo-bucket"
    assert st.status.bucketUrl == "s3://demo-bucket"
    assert st.status.queueName == "demo-queue"
    assert st.status.topic == "demo-queue"
    assert st.status.queueUrl == _queue_observed.url
    assert st.status.deadLetterUrl == _queue_observed.deadLetterUrl
}

test_status_without_dead_letter = lambda {
    q = {k: v for k, v in _queue_observed if k != "deadLetterUrl"}
    st = inbox.status(_build(_min("aws")), {bucket = _wrap(_bucket_observed), queue = _wrap(q)})
    assert st.status?.deadLetterUrl == Undefined, "absent when the queue publishes none"
}
