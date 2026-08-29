# queue (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-sqs schema package. The portable Queue maps onto an
# SQS Queue, plus a companion <name>-dlq Queue wired via the inline
# forProvider.redrivePolicy JSON when dead-lettering is asked for (the model
# carries the policy as a string field, so no separate QueueRedrivePolicy MR
# is needed). In-cluster-only fields (persistence, persistenceSizeGb,
# replicas) are ignored here; SQS is always durable and imposes its own
# quotas. fifo=false is also the SQS default, so the flag is only sent when
# a FIFO queue is asked for.
import aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue as q

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# SQS caps a redrive policy's maxReceiveCount at 100; the XRD enforces the
# same range, but the composition clamps defensively.
receives_for = lambda n: int -> int {
    _r = n
    if _r < 1:
        _r = 1

    if _r > 100:
        _r = 100

    _r
}

# render needs the observed state too: the redrive policy embeds the DLQ's
# ARN, which only exists once AWS has created the DLQ (see below).
render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region

    _fifo = _spec?.fifo or False

    # 0 is a valid visibility timeout, so `or` would clobber it.
    _visibility = _spec?.visibilityTimeoutSeconds
    if _visibility == Undefined:
        _visibility = 30

    _retention = (_spec?.retentionDays or 4) * 86400
    _kms = _spec?.encryptionKmsKeyId
    _dl = _spec?.deadLetter?.enabled or False
    _receives = receives_for(_spec?.deadLetter?.maxReceives or 5)

    # A FIFO queue's name must end with .fifo, and its DLQ must be FIFO too —
    # SQS rejects a redrive policy that crosses queue types.
    _queue_name = "${_name}.fifo" if _fifo else _name
    _dlq_name = "${_name}-dlq.fifo" if _fifo else "${_name}-dlq"

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Eventual-consistency handshake: the DLQ's ARN is only known after AWS
    # creates it, so the first reconcile renders both queues without a redrive
    # policy, and the next one — once ocds carries the DLQ's atProvider.arn —
    # wires the policy onto the main queue.
    _dlq_arn = (ocds["dlq"]?.Resource?.status?.atProvider?.arn) if ("dlq" in ocds) else Undefined

    _items: [any] = [q.Queue {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.name = _queue_name
        if _fifo:
            spec.forProvider.fifoQueue = True
            # Without content-based deduplication every send would need an
            # explicit deduplication id; hashing the body is the sane default.
            spec.forProvider.contentBasedDeduplication = True
        spec.forProvider.visibilityTimeoutSeconds = _visibility
        spec.forProvider.messageRetentionSeconds = _retention
        if _kms:
            spec.forProvider.kmsMasterKeyId = _kms
        if _dl and _dlq_arn:
            # SQS wants maxReceiveCount as a bare integer, not a string.
            spec.forProvider.redrivePolicy = '{"deadLetterTargetArn":"${_dlq_arn}","maxReceiveCount":${_receives}}'
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    if _dl:
        _items += [q.Queue {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "dlq"}
            if _mp:
                spec.managementPolicies = _mp
            spec.forProvider.region = _region
            spec.forProvider.name = _dlq_name
            if _fifo:
                spec.forProvider.fifoQueue = True
                spec.forProvider.contentBasedDeduplication = True
            # Shunted messages should outlive the source queue's retention —
            # they exist to be inspected later — so the DLQ keeps the SQS
            # maximum of 14 days regardless of retentionDays.
            spec.forProvider.messageRetentionSeconds = 14 * 86400
            if _kms:
                spec.forProvider.kmsMasterKeyId = _kms
            if _spec?.tags:
                spec.forProvider.tags = _spec.tags
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _fifo = _spec?.fifo or False
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _dlq_at = (ocds["dlq"]?.Resource?.status?.atProvider) if ("dlq" in ocds) else Undefined

    _queue_name = "${_name}.fifo" if _fifo else _name
    _region = (_at?.region) or _spec.region
    # The queue URL doubles as the terraform id.
    _url = (_at?.url) or (_at?.id) or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Queue"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = _url != ""
            # Deterministic from spec: the name is chosen here, not by AWS.
            queueName = _queue_name
            # Producers and consumers address the same queue on SQS; there is
            # no separate topic.
            topic = _queue_name
            if _url != "":
                url = _url
                id = _url
                "cloud-url" = "https://${_region}.console.aws.amazon.com/sqs/v3/home?region=${_region}#/queues/${_url}"
            if _at?.arn:
                arn = _at.arn
            if _dlq_at?.url:
                deadLetterUrl = _dlq_at.url
        }
    }
}
