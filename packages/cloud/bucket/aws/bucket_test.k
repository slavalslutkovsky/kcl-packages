# Unit tests for the bucket (aws) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# Escaped schema keys ($rule/$filter) serialize to plain keys, so rendered
# dicts are indexed by the de-escaped string key (x["rule"], x["filter"]).
import .bucket

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# Return the first rendered item whose .kind matches, else Undefined.
_by_kind = lambda items: [any], kind: str -> any {
    _hit = [_i for _i in items if _i.kind == kind]
    _hit[0] if _hit else Undefined
}

# Collect every rendered .kind in order.
_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# 1) Minimal spec (region only): four MRs in a fixed order; first is the Bucket.
test_render_minimal = lambda {
    oxr = {apiVersion = "cloud.example.org/v1alpha1", kind = "Bucket", metadata.name = "demo", spec = {region = "us-east-1"}}
    items = bucket.render(oxr)
    assert len(items) == 4, "minimal spec must render exactly 4 managed resources"
    assert _kinds(items) == ["Bucket", "BucketVersioning", "BucketPublicAccessBlock", "BucketOwnershipControls"], "unexpected ordered kinds"
    assert items[0].apiVersion == "s3.aws.m.upbound.io/v1beta1", "wrong Bucket apiVersion"
    assert items[0].kind == "Bucket", "first item must be the Bucket"
}

# 2) storageClass=archive appends a BucketLifecycleConfiguration (len==5) with a
#    DEEP_ARCHIVE transition at 180 days under rule id 'storage-class'.
test_storage_class_archive = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", storageClass = "archive"}}
    items = bucket.render(oxr)
    assert len(items) == 5, "archive tier must add the lifecycle config"
    _lc = _by_kind(items, "BucketLifecycleConfiguration")
    assert _lc != Undefined, "BucketLifecycleConfiguration missing"
    _rules = _lc.spec.forProvider["rule"]
    _sc = [_r for _r in _rules if _r["id"] == "storage-class"]
    assert len(_sc) == 1, "expected a single 'storage-class' rule"
    _t = _sc[0]["transition"][0]
    assert _t["storageClass"] == "DEEP_ARCHIVE", "archive must transition to DEEP_ARCHIVE"
    assert _t["days"] == 180, "archive transition must be at 180 days"
}

# 3) versioning toggles the managed BucketVersioning status.
test_versioning_suspended = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", versioning = False}}
    _v = _by_kind(bucket.render(oxr), "BucketVersioning")
    assert _v.spec.forProvider.versioningConfiguration.status == "Suspended", "versioning=false must Suspend"
}
test_versioning_enabled_default = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1"}}
    _v = _by_kind(bucket.render(oxr), "BucketVersioning")
    assert _v.spec.forProvider.versioningConfiguration.status == "Enabled", "default versioning must be Enabled"
}

# 4) uniformAccess drives the ownership rule.
test_uniform_access_enforced = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", uniformAccess = True}}
    _o = _by_kind(bucket.render(oxr), "BucketOwnershipControls")
    assert _o.spec.forProvider["rule"]["objectOwnership"] == "BucketOwnerEnforced", "uniform => BucketOwnerEnforced"
}
test_uniform_access_preferred = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", uniformAccess = False}}
    _o = _by_kind(bucket.render(oxr), "BucketOwnershipControls")
    assert _o.spec.forProvider["rule"]["objectOwnership"] == "BucketOwnerPreferred", "non-uniform => BucketOwnerPreferred"
}

# blockPublicAccess true => all four PAB flags true.
test_block_public_access = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1"}}
    _p = _by_kind(bucket.render(oxr), "BucketPublicAccessBlock")
    _fp = _p.spec.forProvider
    assert _fp.blockPublicAcls and _fp.blockPublicPolicy and _fp.ignorePublicAcls and _fp.restrictPublicBuckets, "all PAB flags must be true by default"
}

# 5) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves them off (provider default ["*"] applies).
test_deletion_policy_orphan = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", deletionPolicy = "Orphan"}}
    items = bucket.render(oxr)
    assert items[0].spec.managementPolicies == _orphan, "Bucket must carry orphan policies"
    _v = _by_kind(items, "BucketVersioning")
    assert _v.spec.managementPolicies == _orphan, "companion MR must carry orphan policies"
}
test_deletion_policy_delete_default = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1"}}
    items = bucket.render(oxr)
    assert items[0].spec.managementPolicies != _orphan, "Delete must not set the orphan policies"
    _v = _by_kind(items, "BucketVersioning")
    assert _v.spec.managementPolicies != _orphan, "Delete must not set the orphan policies on companions"
}

# 6) encryptionKmsKeyId adds an SSE MR using aws:kms with the given key.
test_encryption_kms = lambda {
    _key = "arn:aws:kms:us-east-1:111122223333:key/abcd"
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", encryptionKmsKeyId = _key}}
    _e = _by_kind(bucket.render(oxr), "BucketServerSideEncryptionConfiguration")
    assert _e != Undefined, "SSE MR must be present when a KMS key is given"
    _def = _e.spec.forProvider["rule"][0]["applyServerSideEncryptionByDefault"]
    assert _def["sseAlgorithm"] == "aws:kms", "SSE algorithm must be aws:kms"
    assert _def["kmsMasterKeyId"] == _key, "SSE must reference the supplied KMS key"
}

# 7) retention enables object lock on the Bucket and adds the lock config.
test_retention_governance = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", retention = {days = 30, mode = "governance"}}}
    items = bucket.render(oxr)
    assert items[0].spec.forProvider.objectLockEnabled == True, "retention must enable object lock on the Bucket"
    _ol = _by_kind(items, "BucketObjectLockConfiguration")
    assert _ol != Undefined, "BucketObjectLockConfiguration must be present"
    _dr = _ol.spec.forProvider["rule"]["defaultRetention"]
    assert _dr["mode"] == "GOVERNANCE", "governance mode must map to GOVERNANCE"
    assert _dr["days"] == 30, "retention days must be carried through"
}
test_retention_compliance = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", retention = {days = 7, mode = "compliance"}}}
    _ol = _by_kind(bucket.render(oxr), "BucketObjectLockConfiguration")
    _dr = _ol.spec.forProvider["rule"]["defaultRetention"]
    assert _dr["mode"] == "COMPLIANCE", "compliance mode must map to COMPLIANCE"
    assert _dr["days"] == 7, "retention days must be carried through"
}

# 8) Kitchen-sink: every optional field set renders cleanly and includes the
#    cors/logging/website/request-payment companions.
test_kitchen_sink = lambda {
    oxr = {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "Bucket"
        metadata.name = "demo"
        spec = {
            region = "us-east-1"
            storageClass = "nearline"
            versioning = True
            forceDestroy = True
            deletionPolicy = "Orphan"
            blockPublicAccess = True
            uniformAccess = True
            encryptionKmsKeyId = "arn:aws:kms:us-east-1:111122223333:key/abcd"
            requesterPays = True
            retention = {days = 14, mode = "compliance"}
            tags = {env = "prod", team = "platform"}
            logging = {targetBucket = "logs-bkt", targetPrefix = "demo/"}
            website = {indexDocument = "index.html", errorDocument = "error.html"}
            cors = [{origins = ["https://example.com"], methods = ["GET", "PUT"], headers = ["*"], maxAgeSeconds = 600}]
            lifecycleRules = [{id = "expire-old", prefix = "tmp/", expirationDays = 90, transitionDays = 30, transitionStorageClass = "cold"}]
        }
    }
    items = bucket.render(oxr)
    _present = _kinds(items)
    _expected = ["Bucket", "BucketVersioning", "BucketPublicAccessBlock", "BucketOwnershipControls", "BucketServerSideEncryptionConfiguration", "BucketLifecycleConfiguration", "BucketObjectLockConfiguration", "BucketCorsConfiguration", "BucketLogging", "BucketWebsiteConfiguration", "BucketRequestPaymentConfiguration"]
    _missing = [_k for _k in _expected if _k not in _present]
    assert _missing == [], "kitchen-sink missing kinds: ${_missing}"
    # CORS companion carries the supplied rule.
    _c = _by_kind(items, "BucketCorsConfiguration")
    assert _c.spec.forProvider.corsRule[0].allowedOrigins == ["https://example.com"], "cors origins must be carried"
    assert _c.spec.forProvider.corsRule[0].maxAgeSeconds == 600, "cors maxAgeSeconds must be carried"
    # Logging companion.
    _lg = _by_kind(items, "BucketLogging")
    assert _lg.spec.forProvider.targetBucket == "logs-bkt", "logging targetBucket must be carried"
    # Website companion.
    _w = _by_kind(items, "BucketWebsiteConfiguration")
    assert _w.spec.forProvider.indexDocument.suffix == "index.html", "website index document must be carried"
    # Request-payment companion.
    _rp = _by_kind(items, "BucketRequestPaymentConfiguration")
    assert _rp.spec.forProvider.payer == "Requester", "requesterPays must set payer=Requester"
}

# 9) status before creation: not ready, sensible synthetic URLs.
test_status_pre_creation = lambda {
    oxr = {apiVersion = "cloud.example.org/v1alpha1", kind = "Bucket", metadata.name = "demo", spec = {region = "us-east-1"}}
    dxr = bucket.status(oxr, {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Bucket", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.url == "s3://demo", "synthetic url must be s3://<name>"
    assert dxr.status["cloud-url"].startswith("https://s3.console.aws.amazon.com"), "cloud-url must point at the S3 console"
}

# 10) status after creation: ready with provider-observed fields populated.
test_status_observed = lambda {
    oxr = {apiVersion = "cloud.example.org/v1alpha1", kind = "Bucket", metadata.name = "demo", spec = {region = "us-east-1"}}
    ocds = {managed = {Resource = {status = {atProvider = {
        arn = "arn:aws:s3:::demo"
        id = "demo"
        region = "us-east-1"
        bucketRegionalDomainName = "demo.s3.us-east-1.amazonaws.com"
    }}}}}
    dxr = bucket.status(oxr, ocds)
    assert dxr.status.ready == True, "observed arn must mark the bucket ready"
    assert dxr.status.arn == "arn:aws:s3:::demo", "arn must be surfaced"
    assert dxr.status.endpoint == "demo.s3.us-east-1.amazonaws.com", "regional domain name must be the endpoint"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Bucket", "dxr kind must echo the composite"
}

test_render_minimal()
test_storage_class_archive()
test_versioning_suspended()
test_versioning_enabled_default()
test_uniform_access_enforced()
test_uniform_access_preferred()
test_block_public_access()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_encryption_kms()
test_retention_governance()
test_retention_compliance()
test_kitchen_sink()
test_status_pre_creation()
test_status_observed()
