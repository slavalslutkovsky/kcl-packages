import .queue

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr`/`ocds` parameters —
# KCL normalizes the leading underscore, so a helper named `_oxr` shadows it.
_build = lambda _spec {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Queue", metadata.name = "demo", spec = _spec}
}

_by_name = lambda _items, _n {
    _hits = [_i for _i in _items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _n]
    _hits[0] if _hits else Undefined
}

# The main Queue forProvider block from a render() of the given spec, with
# nothing observed yet.
_fp = lambda _spec {
    queue.render(_build(_spec), {})[0].spec.forProvider
}

# An ocds fixture carrying an observed DLQ ARN (what the second reconcile sees).
_dlq_observed = {
    dlq = {
        Resource = {
            status = {
                atProvider = {
                    arn = "arn:aws:sqs:us-east-1:1:demo-dlq"
                    url = "https://sqs.us-east-1.amazonaws.com/1/demo-dlq"
                }
            }
        }
    }
}

# ---- render: shape ----------------------------------------------------------

# Minimal spec: one Queue, no DLQ (dead-lettering defaults off).
test_render_minimal = lambda {
    items = queue.render(_build({region = "us-east-1"}), {})
    assert len(items) == 1, "minimal render must emit exactly one MR"
    assert items[0].apiVersion == "sqs.aws.m.upbound.io/v1beta1", "wrong apiVersion"
    assert items[0].kind == "Queue", "wrong kind"
    assert items[0].metadata.annotations["krm.kcl.dev/composition-resource-name"] == "managed", "must be the managed resource"
    fp = items[0].spec.forProvider
    assert fp.region == "us-east-1", "region must be carried"
    assert fp.name == "demo", "a standard queue keeps the bare XR name"
    assert fp?.fifoQueue == Undefined, "standard queues must not send the fifo flag"
    assert fp?.contentBasedDeduplication == Undefined, "dedup is a FIFO-only setting"
}

# ---- render: fifo -----------------------------------------------------------

# SQS mandates the .fifo suffix, and a FIFO queue's DLQ must be FIFO too.
test_fifo_naming = lambda {
    items = queue.render(_build({region = "us-east-1", fifo = True, deadLetter = {enabled = True}}), {})
    fp = items[0].spec.forProvider
    assert fp.name == "demo.fifo", "FIFO queue names must gain the .fifo suffix"
    assert fp.fifoQueue == True, "fifo must set the FIFO flag"
    assert fp.contentBasedDeduplication == True, "fifo must enable content-based deduplication"
    dlq = _by_name(items, "dlq").spec.forProvider
    assert dlq.name == "demo-dlq.fifo", "the DLQ must match the source queue's type"
    assert dlq.fifoQueue == True, "the DLQ must be FIFO when the source is"
    assert dlq.contentBasedDeduplication == True, "the FIFO DLQ must deduplicate too"
}

# ---- render: visibility and retention ---------------------------------------
test_visibility_and_retention_defaults = lambda {
    fp = _fp({region = "us-east-1"})
    assert fp.visibilityTimeoutSeconds == 30, "visibility must default to 30 seconds"
    assert fp.messageRetentionSeconds == 345600, "retention must default to 4 days"
}

test_visibility_and_retention_overrides = lambda {
    fp = _fp({region = "us-east-1", visibilityTimeoutSeconds = 120, retentionDays = 14})
    assert fp.visibilityTimeoutSeconds == 120, "explicit visibility must win"
    assert fp.messageRetentionSeconds == 1209600, "retentionDays must convert to seconds"
    assert _fp({region = "us-east-1", visibilityTimeoutSeconds = 0}).visibilityTimeoutSeconds == 0, "0 is a valid visibility timeout and must not fall to the default"
}

# ---- render: encryption -----------------------------------------------------
test_kms = lambda {
    assert _fp({region = "us-east-1"})?.kmsMasterKeyId == Undefined, "no CMEK unless asked for"
    items = queue.render(_build({region = "us-east-1", encryptionKmsKeyId = "arn:aws:kms:us-east-1:1:key/a", deadLetter = {enabled = True}}), {})
    assert items[0].spec.forProvider.kmsMasterKeyId == "arn:aws:kms:us-east-1:1:key/a", "CMEK must be carried"
    assert _by_name(items, "dlq").spec.forProvider.kmsMasterKeyId == "arn:aws:kms:us-east-1:1:key/a", "the DLQ must be encrypted with the same CMEK"
}

# ---- render: dead-lettering -------------------------------------------------
test_dead_letter_disabled = lambda {
    items = queue.render(_build({region = "us-east-1", deadLetter = {enabled = False}}), {})
    assert len(items) == 1, "disabled dead-lettering must not render a DLQ"
}

test_dead_letter_enabled = lambda {
    items = queue.render(_build({region = "us-east-1", deadLetter = {enabled = True}}), {})
    assert len(items) == 2, "dead-lettering must add a DLQ MR"
    dlq = _by_name(items, "dlq")
    assert dlq != Undefined, "the DLQ must be present"
    assert dlq.spec.forProvider.name == "demo-dlq", "the DLQ name must derive from the XR"

    # Shunted messages should outlive the source retention, so the DLQ is
    # pinned at the SQS 14-day maximum.
    assert dlq.spec.forProvider.messageRetentionSeconds == 1209600, "the DLQ must keep messages for 14 days"
}

# The DLQ ARN only exists after AWS creates it: no redrive policy on the first
# reconcile, the exact JSON string once ocds carries the observed ARN.
test_redrive_policy_waits_for_the_dlq = lambda {
    first = queue.render(_build({region = "us-east-1", deadLetter = {enabled = True}}), {})
    assert first[0].spec.forProvider?.redrivePolicy == Undefined, "no redrive policy before the DLQ is observed"
    second = queue.render(_build({region = "us-east-1", deadLetter = {enabled = True}}), _dlq_observed)
    assert second[0].spec.forProvider.redrivePolicy == '{"deadLetterTargetArn":"arn:aws:sqs:us-east-1:1:demo-dlq","maxReceiveCount":5}', "the redrive policy must embed the observed ARN and the default maxReceives"
    assert _by_name(second, "dlq").spec.forProvider?.redrivePolicy == Undefined, "the DLQ itself carries no redrive policy"
}

test_max_receives = lambda {
    items = queue.render(_build({region = "us-east-1", deadLetter = {enabled = True, maxReceives = 3}}), _dlq_observed)
    assert items[0].spec.forProvider.redrivePolicy.endswith('"maxReceiveCount":3}'), "explicit maxReceives must win"
    assert queue.receives_for(0) == 1, "maxReceives must clamp up to 1"
    assert queue.receives_for(250) == 100, "maxReceives must clamp down to the SQS cap"
    assert queue.receives_for(5) == 5, "in-range values must pass through"
}

# ---- render: deletion policy ------------------------------------------------

# Orphan must reach the DLQ too, or deleting the XR still drops the shunted
# messages it was supposed to preserve.
test_deletion_policy_orphan = lambda {
    items = queue.render(_build({region = "us-east-1", deletionPolicy = "Orphan", deadLetter = {enabled = True}}), {})
    assert items[0].spec.managementPolicies == _orphan, "Orphan must set the non-delete policies"
    assert _by_name(items, "dlq").spec.managementPolicies == _orphan, "Orphan must reach the DLQ"
}

test_deletion_policy_delete_default = lambda {
    items = queue.render(_build({region = "us-east-1"}), {})
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
}

# ---- render: tags -----------------------------------------------------------
test_tags_fan_out = lambda {
    items = queue.render(_build({region = "us-east-1", tags = {team = "core"}, deadLetter = {enabled = True}}), {})
    assert items[0].spec.forProvider.tags == {team = "core"}, "tags must reach the main queue"
    assert _by_name(items, "dlq").spec.forProvider.tags == {team = "core"}, "tags must reach the DLQ"
    assert _fp({region = "us-east-1"})?.tags == Undefined, "no tags unless asked for"
}

# ---- status -----------------------------------------------------------------
test_status_pre_creation = lambda {
    dxr = queue.status(_build({region = "us-east-1", fifo = True}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Queue", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.queueName == "demo.fifo", "the queue name is deterministic from spec"
    assert dxr.status.topic == "demo.fifo", "on SQS the topic is the queue itself"
    assert dxr.status?.url == Undefined, "no url before the queue exists"
    assert dxr.status?["cloud-url"] == Undefined, "no console url before the queue exists"
}

test_status_observed = lambda {
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:sqs:us-east-1:1:demo"
                        id = "https://sqs.us-east-1.amazonaws.com/1/demo"
                        url = "https://sqs.us-east-1.amazonaws.com/1/demo"
                        region = "us-east-1"
                    }
                }
            }
        }
    } | _dlq_observed
    dxr = queue.status(_build({region = "us-east-1", deadLetter = {enabled = True}}), ocds)
    assert dxr.status.ready == True, "an observed url must mark the queue ready"
    assert dxr.status.url == "https://sqs.us-east-1.amazonaws.com/1/demo", "the queue url must be surfaced"
    assert dxr.status.id == "https://sqs.us-east-1.amazonaws.com/1/demo", "the url doubles as the terraform id"
    assert dxr.status.queueName == "demo", "queue name must be surfaced"
    assert dxr.status.arn == "arn:aws:sqs:us-east-1:1:demo", "arn must be surfaced"
    assert dxr.status.deadLetterUrl == "https://sqs.us-east-1.amazonaws.com/1/demo-dlq", "the DLQ url must be surfaced"
    assert dxr.status["cloud-url"].startswith("https://us-east-1.console.aws.amazon.com/sqs/v3/home"), "cloud-url must point at the SQS console"
    assert dxr.status["cloud-url"].endswith("#/queues/https://sqs.us-east-1.amazonaws.com/1/demo"), "cloud-url must carry the observed queue url"
}
