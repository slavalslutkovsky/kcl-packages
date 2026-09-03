# inbox — Crossplane Composition logic (function-kcl module).
#
# A composite of composites: instead of managed resources this module emits two
# CHILD COMPOSITE RESOURCES, a cloud.example.org Bucket (where payloads land)
# and a Queue (the work item per payload). Each capability keeps owning its
# cloud mapping, so nothing here knows what an S3 bucket or a Pub/Sub
# subscription looks like — it only sizes the pair and points both at one
# backend.
#
# Unlike appstack the children are TYPED: bucket-xrd and queue-xrd are the KCL
# schemas `just xrd-schema <module>` generates from those two XRDs, so a field
# the child XRD does not declare, a value outside its range, or a wrong enum is
# a render error here rather than a rejected apply on the cluster. The typed
# child also carries the XRD's own defaults explicitly, which is the same
# object the API server would have produced from a sparse one. Those two
# imports are also the edges the Nx project graph shows for this package.
import bucket_xrd.models.v1alpha1.cloud_example_org_v1alpha1_bucket as bucket
import queue_xrd.models.v1alpha1.cloud_example_org_v1alpha1_queue as queue

# Explicit "was this field set?" test. Truthiness cannot answer it: false and 0
# are legitimate values that must still be forwarded. Both spellings of absent
# are checked because `?.` yields Undefined for a missing key but None when the
# parent dict itself is empty, which is exactly the case for an omitted
# optional block such as spec.bucket.
_set = lambda value -> bool {
    not (value == Undefined or value == None)
}

# A child XR's observed state as function-kcl receives it. Unlike a managed
# resource there is no `atProvider` layer: a composed XR's status IS the status
# its XRD declares.
_observed = lambda ocds, name: str -> any {
    (ocds[name]?.Resource?.status) if (name in ocds) else Undefined
}

# The spec fragment both children start from. Backend, region, deletion policy,
# encryption key and tags are pair-wide by design: a bucket on one cloud and a
# queue on another would not be an inbox.
_base = lambda spec: {str:any} -> {str:any} {
    {
        region = spec.region
        deletionPolicy = spec?.deletionPolicy or "Delete"
        crossplane.compositionSelector.matchLabels.provider = spec.provider
        if spec?.encryptionKmsKeyId:
            encryptionKmsKeyId = spec.encryptionKmsKeyId
        if spec?.tags:
            tags = spec.tags
    }
}

_bucket = lambda name: str, spec: {str:any} -> bucket.Bucket {
    _b = spec?.bucket or {}
    bucket.Bucket {
        metadata = {
            name = "${name}-bucket"
            annotations = {"krm.kcl.dev/composition-resource-name" = "bucket"}
        }
        spec = _base(spec) | {
            storageClass = _b?.storageClass or "standard"
            # Inbox defaults differ from the Bucket's own (versioning off): the
            # value is always sent so the child never falls back to ITS default.
            versioning = _b?.versioning if _set(_b?.versioning) else False
            forceDestroy = _b?.forceDestroy if _set(_b?.forceDestroy) else False
            if _set(_b?.expirationDays):
                lifecycleRules = [{id = "expire-payloads", prefix = "", expirationDays = _b.expirationDays}]
        }
    }
}

_queue = lambda name: str, spec: {str:any} -> queue.Queue {
    _q = spec?.queue or {}
    _dl = _q?.deadLetter or {}
    queue.Queue {
        metadata = {
            name = "${name}-queue"
            annotations = {"krm.kcl.dev/composition-resource-name" = "queue"}
        }
        spec = _base(spec) | {
            fifo = _q?.fifo if _set(_q?.fifo) else False
            # Presence, not truthiness: a visibility timeout of 0 is a value.
            visibilityTimeoutSeconds = _q?.visibilityTimeoutSeconds if _set(_q?.visibilityTimeoutSeconds) else 30
            retentionDays = _q?.retentionDays if _set(_q?.retentionDays) else 4
            # Dead-lettering is on by default here, off on the bare Queue: a
            # poison payload must not block every payload behind it.
            deadLetter = {
                enabled = _dl?.enabled if _set(_dl?.enabled) else True
                maxReceives = _dl?.maxReceives if _set(_dl?.maxReceives) else 5
            }
        }
    }
}

# render(oxr) — the two children. No ocds parameter: unlike appstack there is
# no cross-child wiring, the bucket and the queue are independent and complete
# on the first reconcile.
render = lambda oxr -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # Composed resources inherit the XR's namespace, so metadata.namespace is
    # deliberately never set here.
    [_bucket(_name, _spec), _queue(_name, _spec)]
}

# Build the desired composite carrying the children's observed status back to
# the Inbox. Coordinates are copied, never recomputed: each capability already
# decided what its URL and names look like, and duplicating that here would let
# the two answers disagree.
status = lambda oxr, ocds -> any {
    _name = oxr.metadata.name

    _b = _observed(ocds, "bucket")
    _q = _observed(ocds, "queue")

    _b_ready = _b?.ready or False
    _q_ready = _q?.ready or False

    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "Inbox"
        metadata.name = _name
        status = {
            provider = oxr.spec.provider
            # Usable only as a pair: payloads with no work items, or work items
            # pointing at no payloads, are not an inbox.
            ready = _b_ready and _q_ready
            components = {
                bucket = _b_ready
                queue = _q_ready
            }
            if _b?.bucketName:
                bucketName = _b.bucketName
            if _b?.url:
                bucketUrl = _b.url
            if _q?.queueName:
                queueName = _q.queueName
            if _q?.url:
                queueUrl = _q.url
            if _q?.topic:
                topic = _q.topic
            if _q?.deadLetterUrl:
                deadLetterUrl = _q.deadLetterUrl
        }
    }
}
