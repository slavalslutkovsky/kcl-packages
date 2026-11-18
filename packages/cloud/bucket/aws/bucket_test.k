# Unit tests for the bucket (aws) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# Escaped schema keys ($rule/$filter) serialize to plain keys, so rendered
# dicts are indexed by the de-escaped string key (x["rule"], x["filter"]).
import .bucket
import json
import runtime

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
    ocds = {
        managed = {
            Resource = {
                status = {
                    atProvider = {
                        arn = "arn:aws:s3:::demo"
                        id = "demo"
                        region = "us-east-1"
                        bucketRegionalDomainName = "demo.s3.us-east-1.amazonaws.com"
                    }
                }
            }
        }
    }
    dxr = bucket.status(oxr, ocds)
    assert dxr.status.ready == True, "observed arn must mark the bucket ready"
    assert dxr.status.arn == "arn:aws:s3:::demo", "arn must be surfaced"
    assert dxr.status.endpoint == "demo.s3.us-east-1.amazonaws.com", "regional domain name must be the endpoint"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Bucket", "dxr kind must echo the composite"
}

# 11) import: every MR is pinned to the existing bucket by external-name and,
#     in the default observe mode, carries managementPolicies=[Observe];
#     companions name the bucket directly instead of resolving the selector.
test_import_observe = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", storageClass = "archive", import = {existingName = "legacy-assets-8f3a", source = "terraform", address = "aws_s3_bucket.assets"}}}
    items = bucket.render(oxr)
    _unpinned = [_i.kind for _i in items if _i.metadata.annotations?["crossplane.io/external-name"] != "legacy-assets-8f3a"]
    assert _unpinned == [], "every MR must pin external-name to the existing bucket, missing on: ${_unpinned}"
    _not_observe = [_i.kind for _i in items if _i.spec.managementPolicies != ["Observe"]]
    assert _not_observe == [], "observe mode must set [Observe] on every MR, missing on: ${_not_observe}"
    assert items[0].metadata.annotations["cloud.example.org/imported-from"] == "terraform", "source must be recorded"
    assert items[0].metadata.annotations["cloud.example.org/import-address"] == "aws_s3_bucket.assets", "address must be recorded"
    _v = _by_kind(items, "BucketVersioning")
    assert _v.spec.forProvider.bucket == "legacy-assets-8f3a", "companions must name the bucket directly"
    assert _v.spec.forProvider?.bucketSelector == Undefined, "no selector when the bucket is named"
    _lc = _by_kind(items, "BucketLifecycleConfiguration")
    assert _lc.metadata.annotations["crossplane.io/external-name"] == "legacy-assets-8f3a", "lifecycle companion is keyed by bucket too"
}

# 12) import mode=manage hands writes to Crossplane: no [Observe], and
#     deletionPolicy decides the policies exactly as for a created bucket.
test_import_manage = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", deletionPolicy = "Orphan", import = {existingName = "legacy", mode = "manage"}}}
    items = bucket.render(oxr)
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "legacy", "external-name still pinned in manage mode"
    _wrong = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _wrong == [], "manage + Orphan must stamp the orphan policies everywhere, wrong on: ${_wrong}"
    oxr2 = {metadata.name = "demo", spec = {region = "us-east-1", import = {existingName = "legacy", mode = "manage"}}}
    items2 = bucket.render(oxr2)
    assert items2[0].spec.managementPolicies != ["Observe"] and items2[0].spec.managementPolicies != _orphan, "manage + Delete leaves the provider default policies"
}

# 13) no import block: nothing is pinned, no provenance annotations.
test_no_import_no_pin = lambda {
    items = bucket.render({metadata.name = "demo", spec = {region = "us-east-1"}})
    assert items[0].metadata.annotations?["crossplane.io/external-name"] == Undefined, "a created bucket must not pin external-name"
    assert items[0].metadata.annotations?["cloud.example.org/imported-from"] == Undefined, "no provenance without import"
    _v = _by_kind(items, "BucketVersioning")
    assert _v.spec.forProvider.bucketSelector.matchControllerRef == True, "created buckets bind companions via the selector"
}

# 14) status.mode tells created from observe from managed, and an adopted
#     bucket reports its existing name before the provider observes anything.
test_status_mode = lambda {
    _created = bucket.status({metadata.name = "demo", spec = {region = "us-east-1"}}, {})
    assert _created.status.mode == "created", "no import -> created"
    assert _created.status.bucketName == "demo", "created bucket is named after the XR until observed"
    _obs = bucket.status({metadata.name = "demo", spec = {region = "us-east-1", import = {existingName = "legacy"}}}, {})
    assert _obs.status.mode == "observe", "import defaults to observe"
    assert _obs.status.bucketName == "legacy", "adopted bucket reports its existing name"
    assert _obs.status.url == "s3://legacy", "url follows the existing name"
    _man = bucket.status({metadata.name = "demo", spec = {region = "us-east-1", import = {existingName = "legacy", mode = "manage"}}}, {})
    assert _man.status.mode == "managed", "import mode=manage -> managed"
}

# ── spec.access ──────────────────────────────────────────────────────────────
_acct = "111122223333"
_gh = {client = "github", owner = "acme", role = "write"}
_gl = {client = "gitlab", repositories = ["grp/app", "grp/lib"], audiences = ["sts.amazonaws.com"]}
_observed = {managed.Resource.status.atProvider = {id = "assets-x7k2p", arn = "arn:aws:s3:::assets-x7k2p"}}

_axr = lambda extra: {str:} -> {str:} {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Bucket", metadata = {name = "assets", namespace = "team-a"}, spec = {region = "us-east-1", federation.awsAccountId = _acct, access = [_gh, _gl]} | extra}
}

# The rendered item with this composition-resource-name, else Undefined.
_by_name = lambda items: [any], crn: str -> any {
    _hit = [_i for _i in items if _i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == crn]
    _hit[0] if _hit else Undefined
}

# Expected failure: its message.
_fails = lambda f: any -> str {
    _msg = runtime.catch(f)
    assert _msg, "expected a render failure"
    _msg
}

# Statement Sid -> actions of a rendered RolePolicy.
_actions = lambda items: [any], crn: str -> {str:[str]} {
    {_s.Sid: _s.Action for _s in json.decode(_by_name(items, crn).spec.forProvider.policy).Statement}
}

# No access: nothing composed, nothing in status, even with an account set.
test_access_absent = lambda {
    oxr = {metadata.name = "demo", spec = {region = "us-east-1", federation.awsAccountId = _acct}}
    assert bucket.render_access(oxr, _observed) == [], "no access -> no access resources"
    assert bucket.render_access({metadata.name = "demo", spec = {region = "us-east-1", access = []}}, {}) == [], "empty access needs no account"
    assert bucket.status(oxr, _observed).status?.access == Undefined, "no access -> no status.access"
}

# Trust: the account's IAM OIDC provider for each issuer, aud and sub patterns
# from owner / repositories, role names pinned to <namespace>-<xr>-<entry>.
test_access_trust = lambda {
    items = bucket.render_access(_axr({}), _observed)
    assert [_i.kind for _i in items] == ["Role", "RolePolicy", "Role", "RolePolicy"], "one Role + RolePolicy per entry"
    _role = _by_name(items, "access-github-actions-pool")
    assert _role.apiVersion == "iam.aws.m.upbound.io/v1beta1", "IAM role from aws-iam"
    assert _role.metadata.annotations["crossplane.io/external-name"] == "team-a-assets-github-actions-pool", "role name pinned"
    _st = json.decode(_role.spec.forProvider.assumeRolePolicy).Statement
    assert len(_st) == 1 and _st[0].Action == "sts:AssumeRoleWithWebIdentity", "web identity trust only"
    assert _st[0].Principal == {Federated = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"}, "github OIDC provider of the account"
    assert _st[0].Condition.StringEquals == {"token.actions.githubusercontent.com:aud" = ["sts.amazonaws.com"]}, "github aws audience"
    assert _st[0].Condition.StringLike == {"token.actions.githubusercontent.com:sub" = ["repo:acme/*"]}, "owner sub pattern"
    _gl_st = json.decode(_by_name(items, "access-gitlab-ci-pool").spec.forProvider.assumeRolePolicy).Statement[0]
    assert _gl_st.Principal.Federated == "arn:aws:iam::111122223333:oidc-provider/gitlab.com", "gitlab.com OIDC provider"
    assert _gl_st.Condition.StringEquals == {"gitlab.com:aud" = ["sts.amazonaws.com"]}, "gitlab audiences as given"
    assert _gl_st.Condition.StringLike == {"gitlab.com:sub" = ["project_path:grp/app:*", "project_path:grp/lib:*"]}, "one sub pattern per repository"
    _p = _by_name(items, "access-github-actions-pool-policy")
    assert _p.spec.forProvider.role == "team-a-assets-github-actions-pool", "inline policy on the pinned role"
    assert "GitHub Actions" in _role.spec.forProvider.description and "team-a/assets" in _role.spec.forProvider.description, "description names client and bucket"
    assert _role.spec?.forProvider?.tags == Undefined, "no tags unless spec.tags"
    assert _by_name(bucket.render_access(_axr({tags = {env = "dev"}}), {}), "access-gitlab-ci-pool").spec.forProvider.tags == {env = "dev"}, "spec.tags carried to roles"
}

# Two-phase: a created bucket's name is unknown until observed; roles first,
# policies once ocds carries the bucket id, scoped to that bucket only.
test_access_two_phase = lambda {
    _first = bucket.render_access(_axr({}), {})
    assert [_i.kind for _i in _first] == ["Role", "Role"], "no RolePolicy before the bucket is observed"
    _second = bucket.render_access(_axr({}), _observed)
    _st = json.decode(_by_name(_second, "access-gitlab-ci-pool-policy").spec.forProvider.policy).Statement
    assert [_s.Resource for _s in _st] == ["arn:aws:s3:::assets-x7k2p", "arn:aws:s3:::assets-x7k2p/*"], "bucket and its objects only"
    assert all _s in _st {
        _s.Effect == "Allow"
    }, "allow statements only"
}

# Actions per role: read lists/gets, write adds put/delete/multipart, admin
# adds ACLs/tags/retention; none touch bucket configuration, policy or IAM.
test_access_role_actions = lambda {
    items = bucket.render_access(_axr({access = [_gh | {role = "read"}, _gl | {role = "admin"}]}), _observed)
    _read = _actions(items, "access-github-actions-pool-policy")
    assert _read.Bucket == ["s3:ListBucket", "s3:GetBucketLocation"], "read bucket actions"
    assert _read.Objects == ["s3:GetObject", "s3:GetObjectVersion"], "read object actions"
    _admin = _actions(items, "access-gitlab-ci-pool-policy")
    assert all _x in ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectAcl", "s3:PutObjectTagging", "s3:PutObjectRetention", "s3:PutObjectLegalHold"] {
        _x in _admin.Objects
    }, "admin object control"
    assert "s3:ListBucketVersions" in _admin.Bucket, "admin lists versions"
    _write = _actions(bucket.render_access(_axr({}), _observed), "access-github-actions-pool-policy")
    assert all _x in ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"] {
        _x in _write.Objects
    }, "write = read + put/delete + multipart"
    assert "s3:ListBucketMultipartUploads" in _write.Bucket, "write lists multipart uploads"
    assert not any _x in ["s3:PutObjectAcl", "s3:DeleteObjectVersion", "s3:PutObjectRetention", "s3:BypassGovernanceRetention"] {
        _x in _write.Objects
    }, "write has no admin actions"
    _all = _read.Bucket + _read.Objects + _write.Bucket + _write.Objects + _admin.Bucket + _admin.Objects
    assert not any _x in _all {
        "*" in _x or _x.startswith("iam:") or _x.startswith("s3:PutBucket") or _x.startswith("s3:DeleteBucket") or _x.startswith("s3:GetBucketPolicy")
    }, "no wildcards, bucket configuration, bucket policy or IAM: ${_all}"
}

# A customer KMS key adds a statement for that key only, per role.
test_access_kms = lambda {
    _key = "arn:aws:kms:us-east-1:111122223333:key/abcd"
    items = bucket.render_access(_axr({encryptionKmsKeyId = _key}), _observed)
    _kms = [_s for _s in json.decode(_by_name(items, "access-gitlab-ci-pool-policy").spec.forProvider.policy).Statement if _s.Sid == "Kms"][0]
    assert _kms.Resource == _key and _kms.Action == ["kms:Decrypt"], "read decrypts with the bucket key"
    assert _actions(items, "access-github-actions-pool-policy").Kms == ["kms:Decrypt", "kms:GenerateDataKey"], "write also generates data keys"
    assert "Kms" not in _actions(bucket.render_access(_axr({}), _observed), "access-gitlab-ci-pool-policy"), "no KMS statement without a key"
    assert _fails(lambda {
        bucket.render_access(_axr({encryptionKmsKeyId = "abcd"}), _observed)
    }).startswith("bucket-aws: "), "a bare key id cannot be granted"
}

# Reordering entries keeps every resource name and role name.
test_access_names_stable = lambda {
    _names = lambda items: [any] -> {str:str} {
        {_i.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _i.metadata.annotations?["crossplane.io/external-name"] or _i.spec.forProvider.role for _i in items}
    }
    _fwd = _names(bucket.render_access(_axr({}), _observed))
    _rev = _names(bucket.render_access(_axr({access = [_gl, _gh]}), _observed))
    assert _fwd == _rev, "names must not depend on entry order"
    _t = bucket.render_access(_axr({access = [_gh, {client = "github", ticket = "jira", subjects = ["repo:acme/ops:ref:refs/heads/main"]}]}), {})
    assert _by_name(_t, "access-jira-github") != Undefined, "ticket entry named after its pool"
    assert "started by Jira" in _by_name(_t, "access-jira-github").spec.forProvider.description, "description names the ticket system"
}

# Role names over IAM's 64 characters: 55 chars, "-", 8 hash chars; stable and distinct.
test_access_role_name_hash = lambda {
    _long = {metadata = {name = "a-very-long-bucket-composite-name-for-tests", namespace = "platform-team"}}
    _rn = bucket.access_role_name(_long, "github-actions-pool")
    _full = "platform-team-a-very-long-bucket-composite-name-for-tests-github-actions-pool"
    assert len(_rn) == 64 and _rn[:56] == _full[:55] + "-", "truncated with a hash suffix: ${_rn}"
    assert _rn == bucket.access_role_name(_long, "github-actions-pool"), "deterministic"
    assert _rn != bucket.access_role_name(_long, "github-actions-pool-x"), "distinct names stay distinct"
    assert bucket.access_role_name({metadata.name = "b"}, "gitlab-ci-pool") == "default-b-gitlab-ci-pool", "short names kept whole"
}

# The contract's failure cases.
test_access_failures = lambda {
    _noacct = _fails(lambda {
        bucket.render_access(_axr({federation = {}}), {})
    })
    assert _noacct.startswith("bucket-aws: ") and "awsAccountId" in _noacct, _noacct
    _gcp = _fails(lambda {
        bucket.render_access(_axr({federation = {awsAccountId = _acct, gcpProjectNumber = "123"}}), {})
    })
    assert _gcp.startswith("bucket-aws: ") and "gcpProjectNumber" in _gcp, _gcp
    _az = _fails(lambda {
        bucket.render_access({metadata.name = "demo", spec = {region = "us-east-1", federation.azureResourceGroup = "rg"}}, {})
    })
    assert _az.startswith("bucket-aws: ") and "azureResourceGroup" in _az, _az
    _obs = _fails(lambda {
        bucket.render_access(_axr({$import = {existingName = "legacy"}}), {})
    })
    assert _obs.startswith("bucket-aws: ") and "import.mode" in _obs, _obs
    _ticket = _fails(lambda {
        bucket.render_access(_axr({access = [{client = "github", ticket = "jira", repositories = ["acme/ops"]}]}), {})
    })
    assert "cannot be expressed in an AWS trust policy" in _ticket, _ticket
    _wf = _fails(lambda {
        bucket.render_access(_axr({access = [{client = "github", owner = "acme", workflows = ["acme/ops/.github/workflows/x.yml"]}]}), {})
    })
    assert "workflows" in _wf, _wf
}

# import manage: the existing name is known, so policies come in one pass;
# Orphan stamps the orphan policies on access resources too.
test_access_import_manage_orphan = lambda {
    items = bucket.render_access(_axr({deletionPolicy = "Orphan", $import = {existingName = "legacy", mode = "manage"}}), {})
    assert [_i.kind for _i in items] == ["Role", "RolePolicy", "Role", "RolePolicy"], "policies without waiting"
    assert json.decode(items[1].spec.forProvider.policy).Statement[0].Resource == "arn:aws:s3:::legacy", "scoped to the existing bucket"
    _wrong = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _wrong == [], "Orphan must reach access resources, wrong on: ${_wrong}"
    _del = bucket.render_access(_axr({}), _observed)
    assert all _i in _del {
        _i.spec.managementPolicies != _orphan
    }, "Delete leaves the default policies"
}

# status.access: name + role per entry, roleArn once the role is observed.
test_access_status = lambda {
    _seen = _observed | {"access-gitlab-ci-pool" = {Resource.status.atProvider.arn = "arn:aws:iam::111122223333:role/team-a-assets-gitlab-ci-pool"}}
    _acc = bucket.status(_axr({}), _seen).status.access
    assert _acc == [{name = "github-actions-pool", role = "write"}, {name = "gitlab-ci-pool", role = "read", roleArn = "arn:aws:iam::111122223333:role/team-a-assets-gitlab-ci-pool"}], "status.access: ${_acc}"
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
test_import_observe()
test_import_manage()
test_no_import_no_pin()
test_status_mode()
test_access_absent()
test_access_trust()
test_access_two_phase()
test_access_role_actions()
test_access_kms()
test_access_names_stable()
test_access_role_name_hash()
test_access_failures()
test_access_import_manage_orphan()
test_access_status()
