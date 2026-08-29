# queue (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-pubsub schema package. The portable Queue maps onto a
# Pub/Sub Topic plus exactly one pull Subscription (the work-queue shape), and
# a companion DLQ Topic + Subscription pair when dead lettering is asked for.
# region is not mapped: Pub/Sub is a global service and message placement is
# implicit (a messageStoragePolicy could pin it, but the abstraction leaves
# placement to Google). In-cluster-only fields (persistence,
# persistenceSizeGb, replicas) are ignored here; the managed backend is
# always durable and imposes its own quotas.
import gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_topic as pt
import gcp_pubsub.models.v1beta1.pubsub_gcpm_upbound_io_v1beta1_subscription as ps

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

_clamp = lambda v: int, lo: int, hi: int -> int {
    lo if v < lo else (hi if v > hi else v)
}

# Unlike the single-resource siblings, render also takes the observed state:
# the main subscription's deadLetterPolicy can only be written once the DLQ
# topic's provider-assigned id (projects/<p>/topics/<name>) has been observed.
render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _topic_name = "${_name}-topic"
    _dlq_topic_name = "${_name}-dlq-topic"

    _fifo = _spec?.fifo or False

    # visibilityTimeoutSeconds may legitimately be 0, so `or` cannot default it.
    _vt = _spec?.visibilityTimeoutSeconds
    if _vt == Undefined:
        _vt = 30

    # Pub/Sub only accepts ack deadlines between 10s and 600s; clamp rather
    # than reject so the portable 0..43200 range always renders something.
    _ack = _clamp(_vt, 10, 600)

    # Pub/Sub subscriptions retain for at most 7 days; clamp the portable
    # 1..14 day range down to what the backend can express.
    _days = _spec?.retentionDays or 4
    _retention = "${_clamp(_days, 1, 7) * 86400}s"

    _dl = _spec?.deadLetter?.enabled or False
    # GCP's maxDeliveryAttempts floor is 5 (the XRD documents the clamp).
    _max = _clamp(_spec?.deadLetter?.maxReceives or 5, 5, 100)
    _dlq_id = (ocds["dlq-topic"]?.Resource?.status?.atProvider?.id) if ("dlq-topic" in ocds) else Undefined

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    _items: [any] = [
        pt.Topic {
            # Deviation from the annotation-only convention: the topic gets an
            # explicit object name so the subscription can topicRef it by its
            # Kubernetes name (the annotation only names it inside the pipeline).
            metadata.name = _topic_name
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "topic"}
            if _mp:
                spec.managementPolicies = _mp
            # messageRetentionDuration is left to the provider default here;
            # retention is enforced on the subscription, where the portable
            # retentionDays actually lives.
            spec.forProvider = {
                if _spec?.encryptionKmsKeyId:
                    kmsKeyName = _spec.encryptionKmsKeyId
                if _spec?.tags:
                    labels = _spec.tags
            }
        }
        ps.Subscription {
            metadata.name = _name
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
            if _mp:
                spec.managementPolicies = _mp
            # An explicit ref, not topicSelector.matchControllerRef: with the
            # DLQ pair enabled the composite controls two topics, and a
            # controller-ref selector cannot tell them apart.
            spec.forProvider.topicRef = {name = _topic_name}
            spec.forProvider.ackDeadlineSeconds = _ack
            spec.forProvider.messageRetentionDuration = _retention
            # Ordering only helps producers that set an ordering key.
            spec.forProvider.enableMessageOrdering = _fifo
            # Eventual-consistency handshake: deadLetterTopic must be the full
            # topic path, which only exists once the DLQ topic has been
            # observed — until then the subscription renders without the
            # policy and gains it on a later reconcile. The Pub/Sub service
            # agent additionally needs roles/pubsub.publisher on the DLQ topic
            # and roles/pubsub.subscriber on this subscription; that is
            # provider-account-level IAM, out of scope here.
            if _dl and _dlq_id:
                spec.forProvider.deadLetterPolicy = {
                    deadLetterTopic = _dlq_id
                    maxDeliveryAttempts = _max
                }
            if _spec?.tags:
                spec.forProvider.labels = _spec.tags
        }
    ]

    if _dl:
        # Messages shunted to a topic with no subscription are lost, so the
        # DLQ is rendered as a pair: the topic the policy points at plus a
        # subscription that actually makes the shunted messages readable.
        _items += [
            pt.Topic {
                metadata.name = _dlq_topic_name
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "dlq-topic"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider = {
                    # Dead letters carry the same payloads as the main topic.
                    if _spec?.encryptionKmsKeyId:
                        kmsKeyName = _spec.encryptionKmsKeyId
                    if _spec?.tags:
                        labels = _spec.tags
                }
            }
            ps.Subscription {
                metadata.name = "${_name}-dlq"
                metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "dlq-sub"}
                if _mp:
                    spec.managementPolicies = _mp
                spec.forProvider.topicRef = {name = _dlq_topic_name}
                # Keep shunted messages around as long as the backend allows.
                spec.forProvider.messageRetentionDuration = "${7 * 86400}s"
                if _spec?.tags:
                    spec.forProvider.labels = _spec.tags
            }
        ]

}

_items

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _topic_at = (ocds["topic"]?.Resource?.status?.atProvider) if ("topic" in ocds) else Undefined
    _dlq_at = (ocds["dlq-topic"]?.Resource?.status?.atProvider) if ("dlq-topic" in ocds) else Undefined

    # The subscription id is its full path (projects/<p>/subscriptions/<name>),
    # which doubles as the consumer-facing url.
    _id = _at?.id or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Queue"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = _id != ""
            queueName = _name
            # Not project-qualified: the project id is only known once the
            # subscription is observed, and the console resolves the short
            # form against the active project. arn is intentionally absent
            # (AWS-only).
            "cloud-url" = "https://console.cloud.google.com/cloudpubsub/subscription/detail/${_name}"
            if _id != "":
                url = _id
                id = _id
            if _topic_at?.id:
                topic = _topic_at.id
            if _dlq_at?.id:
                deadLetterUrl = _dlq_at.id
        }
    }
}
