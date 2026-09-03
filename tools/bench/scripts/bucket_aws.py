"""Python port of packages/cloud/bucket/aws (bucket.k) for function-python.

This is the *same Composition* as the KCL module, expressed in the runtime the
benchmark compares against: same abstract Bucket XR in, same S3 managed
resources and same XR status out. `tools/bench/src/main.ts` diffs the desired
state of every runtime against upstream function-kcl and fails when they
diverge, so this file is kept line-for-line faithful to `bucket.k` rather than
idiomatic — the mapping tables, defaults and ordering below all mirror it.

Two things here are function-kcl artefacts rather than S3 semantics, and exist
so the desired state matches byte for byte:

  * `metadata.annotations` is emitted empty. function-kcl names a composed
    resource with `krm.kcl.dev/composition-resource-name` and consumes that
    annotation, leaving an empty map behind. function-python names resources by
    map key, so the empty map has to be written explicitly.
  * `spec.managementPolicies: ["*"]` is a *schema* default of the aws-s3
    provider package (see packages/providers/aws-s3/models/v1beta1/*.k), which
    KCL materialises on every instance. Only `deletionPolicy: Orphan` replaces
    it with the observe-only policy set.
"""

from google.protobuf import json_format

from crossplane.function.proto.v1 import run_function_pb2 as fnv1

API_VERSION = "s3.aws.m.upbound.io/v1beta1"

# Abstract storage tier -> S3 native class for lifecycle transitions
# (S3 has no bucket-level storage class).
AWS_CLASS = {
    "standard": "STANDARD",
    "nearline": "STANDARD_IA",
    "cold": "GLACIER_IR",
    "archive": "DEEP_ARCHIVE",
}
# storageClass tier -> implicit transition (class + age in days).
TRANSITION = {
    "nearline": {"storageClass": "STANDARD_IA", "days": 30},
    "cold": {"storageClass": "GLACIER_IR", "days": 90},
    "archive": {"storageClass": "DEEP_ARCHIVE", "days": 180},
}
ORPHAN_POLICIES = ["Observe", "Create", "Update", "LateInitialize"]
DEFAULT_POLICIES = ["*"]


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse) -> None:
    """Render the S3 resources for a Bucket XR and carry status back to it."""
    oxr = json_format.MessageToDict(req.observed.composite.resource)
    spec = oxr.get("spec", {})
    region = spec["region"]

    versioning = spec.get("versioning", True)
    block = spec.get("blockPublicAccess", True)
    uniform = spec.get("uniformAccess", True)
    policies = ORPHAN_POLICIES if spec.get("deletionPolicy", "Delete") == "Orphan" else DEFAULT_POLICIES
    retention = spec.get("retention")

    def attach(kind: str, for_provider: dict) -> dict:
        """Companion MR scaffolding: region plus the binding back to the Bucket."""
        return {
            "apiVersion": API_VERSION,
            "kind": kind,
            "metadata": {"annotations": {}},
            "spec": {
                "managementPolicies": policies,
                "forProvider": {
                    "region": region,
                    "bucketSelector": {"matchControllerRef": True},
                    **for_provider,
                },
            },
        }

    desired = {}

    # 1) Bucket (minimal).
    bucket = {"region": region, "forceDestroy": spec.get("forceDestroy", False)}
    if retention:
        bucket["objectLockEnabled"] = True
    if spec.get("tags"):
        bucket["tags"] = spec["tags"]
    desired["managed"] = {
        "apiVersion": API_VERSION,
        "kind": "Bucket",
        "metadata": {"annotations": {}},
        "spec": {"managementPolicies": policies, "forProvider": bucket},
    }

    # 2) Versioning (always managed: Enabled or Suspended).
    desired["versioning"] = attach(
        "BucketVersioning",
        {"versioningConfiguration": {"status": "Enabled" if versioning else "Suspended"}},
    )

    # 3) Public access block (always managed).
    desired["public-access-block"] = attach(
        "BucketPublicAccessBlock",
        {
            "blockPublicAcls": block,
            "blockPublicPolicy": block,
            "ignorePublicAcls": block,
            "restrictPublicBuckets": block,
        },
    )

    # 4) Ownership controls (ACLs disabled when uniform).
    desired["ownership"] = attach(
        "BucketOwnershipControls",
        {"rule": {"objectOwnership": "BucketOwnerEnforced" if uniform else "BucketOwnerPreferred"}},
    )

    # 5) Server-side encryption — KMS when a key is given (S3 applies SSE-S3 by default otherwise).
    if spec.get("encryptionKmsKeyId"):
        desired["encryption"] = attach(
            "BucketServerSideEncryptionConfiguration",
            {
                "rule": [
                    {
                        "applyServerSideEncryptionByDefault": {
                            "sseAlgorithm": "aws:kms",
                            "kmsMasterKeyId": spec["encryptionKmsKeyId"],
                        },
                        "bucketKeyEnabled": True,
                    }
                ]
            },
        )

    # 6) Lifecycle: storageClass tier transition + explicit rules, merged into one config.
    storage_class = spec.get("storageClass")
    rules = []
    if storage_class in TRANSITION:
        tier = TRANSITION[storage_class]
        rules.append(
            {
                "id": "storage-class",
                "status": "Enabled",
                "filter": [{}],
                "transition": [{"days": tier["days"], "storageClass": tier["storageClass"]}],
            }
        )
    for rule in spec.get("lifecycleRules", []):
        entry = {
            "id": rule["id"],
            "status": "Enabled",
            "filter": [{"prefix": rule.get("prefix", "")}],
        }
        if rule.get("expirationDays") is not None:
            entry["expiration"] = [{"days": rule["expirationDays"]}]
        if rule.get("transitionDays") is not None and rule.get("transitionStorageClass") is not None:
            entry["transition"] = [
                {
                    "days": rule["transitionDays"],
                    "storageClass": AWS_CLASS[rule["transitionStorageClass"]],
                }
            ]
        rules.append(entry)
    if rules:
        desired["lifecycle"] = attach("BucketLifecycleConfiguration", {"rule": rules})

    # 7) Object lock / retention.
    if retention:
        mode = "COMPLIANCE" if retention.get("mode", "governance") == "compliance" else "GOVERNANCE"
        desired["object-lock"] = attach(
            "BucketObjectLockConfiguration",
            {"rule": {"defaultRetention": {"mode": mode, "days": retention["days"]}}},
        )

    # 8) CORS.
    if spec.get("cors"):
        desired["cors"] = attach(
            "BucketCorsConfiguration",
            {
                "corsRule": [
                    {
                        "allowedOrigins": entry["origins"],
                        "allowedMethods": entry["methods"],
                        "allowedHeaders": entry.get("headers", []),
                        "maxAgeSeconds": entry.get("maxAgeSeconds", 3600),
                    }
                    for entry in spec["cors"]
                ]
            },
        )

    # 9) Access logging.
    if spec.get("logging"):
        desired["logging"] = attach(
            "BucketLogging",
            {
                "targetBucket": spec["logging"]["targetBucket"],
                "targetPrefix": spec["logging"].get("targetPrefix", ""),
            },
        )

    # 10) Static website.
    if spec.get("website"):
        website = {"indexDocument": {"suffix": spec["website"].get("indexDocument", "index.html")}}
        if spec["website"].get("errorDocument"):
            website["errorDocument"] = {"key": spec["website"]["errorDocument"]}
        desired["website"] = attach("BucketWebsiteConfiguration", website)

    # 11) Requester pays.
    if spec.get("requesterPays"):
        desired["request-payment"] = attach(
            "BucketRequestPaymentConfiguration", {"payer": "Requester"}
        )

    for name, resource in desired.items():
        # Readiness is left unspecified: function-auto-ready decides, exactly as
        # it does for the KCL Composition.
        rsp.desired.resources[name].resource.update(resource)

    rsp.desired.composite.resource.update(_status(oxr, req))


def _status(oxr: dict, req: fnv1.RunFunctionRequest) -> dict:
    """Build the desired composite carrying observed status back to the XR."""
    at = {}
    if "managed" in req.observed.resources:
        observed = json_format.MessageToDict(req.observed.resources["managed"].resource)
        at = observed.get("status", {}).get("atProvider", {})

    name = at.get("id") or oxr["metadata"]["name"]
    region = at.get("region") or oxr["spec"]["region"]
    status = {
        "provider": "aws",
        "ready": bool(at) and at.get("arn", "") != "",
        "bucketName": name,
        "region": region,
        "url": f"s3://{name}",
        "cloud-url": f"https://s3.console.aws.amazon.com/s3/buckets/{name}?region={region}",
    }
    if at:
        if at.get("arn"):
            status["arn"] = at["arn"]
        if at.get("bucketRegionalDomainName"):
            status["endpoint"] = at["bucketRegionalDomainName"]
        elif at.get("bucketDomainName"):
            status["endpoint"] = at["bucketDomainName"]
        if at.get("id"):
            status["id"] = at["id"]

    return {
        "apiVersion": oxr.get("apiVersion", "cloud.example.org/v1alpha1"),
        "kind": oxr.get("kind", "Bucket"),
        "metadata": {"name": oxr["metadata"]["name"]},
        "status": status,
    }
