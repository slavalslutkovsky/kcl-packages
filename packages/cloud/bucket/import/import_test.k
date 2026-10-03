# Unit tests for bucket-import.
#
# Contract under test:
#   terraform_records / pulumi_records -> [Record]   both Terraform JSON shapes, Pulumi export
#   buckets(records)                    -> [Found]    companions folded onto their bucket
#   xr(found, opts)                     -> Bucket     spec.import pinned, notes annotated
#
# The fixtures under testdata/ are hand-cut from real state files: every
# companion kind the aws backend renders, both Terraform spellings (raw
# tfstate and `terraform show -json`, with a child module and a for_each
# key), and pulumi-aws with and without the V2 suffixes. Paths are relative
# to this package because `kcl test` runs with it as the working directory.
# Helper names must not collide with main.k's (`_found`, `_records`): test
# files share the package namespace.
import file
import json
import .lib

_load = lambda p: str -> any {
    json.decode(file.read(p))
}

_adopt = lambda p: str -> [lib.Found] {
    _doc = _load(p)
    lib.buckets(lib.records(_doc, lib.detect(_doc)))
}

_by_name = lambda fs: [lib.Found], n: str -> lib.Found {
    [f for f in fs if f.name == n][0]
}

# ---- readers ----------------------------------------------------------------
test_detect = lambda {
    assert lib.detect(_load("testdata/pulumi-export.json")) == "pulumi", "a deployment key means pulumi"
    assert lib.detect(_load("testdata/terraform-aws.tfstate.json")) == "terraform", "raw tfstate is terraform"
    assert lib.detect(_load("testdata/terraform-show.json")) == "terraform", "show -json is terraform"
}

# Raw tfstate: data sources are ignored, the module + for_each instance gets
# the address `terraform state rm` takes, unknown companions are reported.
test_terraform_state_records = lambda {
    recs = lib.terraform_records(_load("testdata/terraform-aws.tfstate.json"))
    assert len([r for r in recs if r.role == "bucket"]) == 2, "two aws_s3_bucket instances"
    assert [r.address for r in recs if r.role == "bucket"] == ["aws_s3_bucket.assets", "module.logs.aws_s3_bucket.this[\"logs\"]"], "addresses carry module and index_key"
    assert lib.skipped(recs) == ["aws_s3_bucket_policy.assets"], "a bucket policy is bucket-family but not portable: reported, not folded"
    assert len([r for r in recs if r.role == "lifecycleconfiguration"]) == 1, "companion roles are the type with the prefix and separators removed"
}

# `terraform show -json`: resources nested in child_modules are found, with
# their full address; a bucket IAM member is not bucket-family and is ignored.
test_terraform_show_records = lambda {
    recs = lib.terraform_records(_load("testdata/terraform-show.json"))
    assert [r.provider for r in recs] == ["azure", "gcp"], "root module first, then the child module"
    assert recs[1].address == "module.media.google_storage_bucket.media", "show -json addresses are taken verbatim"
    assert lib.skipped(recs) == [], "google_storage_bucket_iam_member is not read at all"
}

# Pulumi: V2 and non-V2 tokens map to the same roles, azure-native is not read.
test_pulumi_records = lambda {
    recs = lib.pulumi_records(_load("testdata/pulumi-export.json"))
    _roles = [r.role for r in recs if r.provider == "aws"]
    assert "versioning" in _roles and "corsconfiguration" in _roles and "lifecycleconfiguration" in _roles, "V2 suffix stripped, non-V2 kept: ${_roles}"
    assert lib.skipped(recs) == ["urn:pulumi:prod::infra::aws:s3/bucketObject:BucketObject::readme"], "a BucketObject is reported, not folded"
    assert [r.provider for r in recs if r.role == "bucket"] == ["aws", "gcp", "azure"], "azure-native StorageAccount is not read"
}

# ---- aws mapping ------------------------------------------------------------

# Every companion the aws backend renders, read back off Terraform state.
test_aws_companions = lambda {
    f = _by_name(_adopt("testdata/terraform-aws.tfstate.json"), "legacy-assets-8f3a1c")
    s = f.spec
    assert f.provider == "aws" and f.address == "aws_s3_bucket.assets"
    assert len(f.companions) == 10 and "aws_s3_bucket_versioning.assets" in f.companions and "aws_s3_bucket_policy.assets" not in f.companions, "every folded companion address, and only those"
    assert s.region == "us-east-1" and s.tags == {team = "platform"}
    assert s.versioning == True, "aws_s3_bucket_versioning Enabled"
    assert s.blockPublicAccess == True, "all four PAB flags"
    assert s.uniformAccess == True, "BucketOwnerEnforced"
    assert s.encryptionKmsKeyId == "arn:aws:kms:us-east-1:111122223333:key/abcd-ef", "aws:kms key carried"
    assert s.requesterPays == True, "payer=Requester"
    assert s.retention == {days = 30, mode = "governance"}, "object lock default retention"
    assert s.logging == {targetBucket = "my-access-logs", targetPrefix = "legacy/"}
    assert s.website == {indexDocument = "index.html", errorDocument = "404.html"}
    assert s.cors == [{origins = ["https://example.com"], methods = ["GET", "HEAD"], headers = ["*"], maxAgeSeconds = 3600}]
    assert s?.forceDestroy == Undefined, "force_destroy=false is the default, not restated"
    assert s?.storageClass == Undefined, "S3 has no bucket tier; the composition's default applies"
}

# Lifecycle: GLACIER_IR maps back to cold, a disabled rule and an
# INTELLIGENT_TIERING transition are dropped and each named once.
test_aws_lifecycle = lambda {
    f = _by_name(_adopt("testdata/terraform-aws.tfstate.json"), "legacy-assets-8f3a1c")
    assert f.spec.lifecycleRules == [{id = "expire-tmp", prefix = "tmp/", expirationDays = 7, transitionDays = 3, transitionStorageClass = "cold"}], "the one portable rule"
    assert len(f.notes) == 2, "one note per dropped rule, not two for the same rule: ${f.notes}"
    assert f.notes[0].startswith("lifecycle rule paused: disabled"), f.notes[0]
    assert f.notes[1].startswith("lifecycle rule smart: transition to INTELLIGENT_TIERING"), f.notes[1]
}

# Legacy inline blocks (aws provider < 4): versioning, sse, website and
# lifecycle_rule live on the bucket itself; AES256 means "no key".
test_aws_legacy_inline = lambda {
    f = _by_name(_adopt("testdata/terraform-aws.tfstate.json"), "my-access-logs")
    s = f.spec
    assert f.address == "module.logs.aws_s3_bucket.this[\"logs\"]"
    assert s.versioning == False, "inline versioning.enabled=false"
    assert s?.encryptionKmsKeyId == Undefined, "SSE-S3 is the provider default, not a key"
    assert s.forceDestroy == True
    assert s.website == {indexDocument = "home.html", errorDocument = "oops.html"}, "legacy website block uses plain strings"
    assert s.lifecycleRules == [{id = "legacy-expire", prefix = "", expirationDays = 365, transitionDays = 30, transitionStorageClass = "nearline"}], "legacy rule uses enabled + a direct prefix"
    assert s?.tags == Undefined, "empty tags are not emitted"
    assert s?.blockPublicAccess == Undefined and s?.uniformAccess == Undefined, "no companion, no claim — the XRD default applies"
}

# Pulumi spellings: camelCase objects, `rules`/`transitions`/`corsRules`; a
# partial public-access block is all-or-nothing in the schema and says so.
test_aws_pulumi = lambda {
    f = _by_name(_adopt("testdata/pulumi-export.json"), "assets-c9d0e1f")
    s = f.spec
    assert f.address == "urn:pulumi:prod::infra::aws:s3/bucketV2:BucketV2::assets"
    assert len(f.companions) == 6 and all c in f.companions {c.startswith("urn:pulumi:prod::infra::aws:s3/bucket")}, "companion URNs for `pulumi state delete`"
    assert s.versioning == True, "companion (Enabled) wins over the legacy versionings[] (false)"
    assert s.blockPublicAccess == False and len([n for n in f.notes if n.startswith("public access block is partial")]) == 1
    assert s.uniformAccess == False, "BucketOwnerPreferred"
    assert s?.encryptionKmsKeyId == Undefined, "AES256 -> no key"
    assert s.lifecycleRules == [{id = "tier", prefix = "", transitionDays = 60, transitionStorageClass = "nearline"}, {id = "expire-tmp", prefix = "tmp/", expirationDays = 14}]
    assert s.cors == [{origins = ["*"], methods = ["GET"], headers = [], maxAgeSeconds = 300}]
}

# ---- gcp mapping ------------------------------------------------------------

# The composition's own tier injection (SetStorageClass at age 0 to the
# bucket's class) folds back into storageClass; other rules map one each;
# a rule without an age is dropped and named.
test_gcp_terraform = lambda {
    f = _by_name(_adopt("testdata/terraform-show.json"), "media-prod-4a2")
    s = f.spec
    assert f.provider == "gcp" and s.region == "US-CENTRAL1" and s.storageClass == "nearline"
    assert s.versioning == True and s.uniformAccess == True and s.blockPublicAccess == True
    assert s.encryptionKmsKeyId == "projects/p/locations/us/keyRings/r/cryptoKeys/k"
    assert s.retention == {days = 30, mode = "governance"}, "2592000s -> 30 days, unlocked"
    assert s.logging == {targetBucket = "media-logs", targetPrefix = "media/"}
    assert s.website == {indexDocument = "index.html", errorDocument = "404.html"}
    assert s.cors == [{origins = ["https://example.com"], methods = ["GET"], headers = ["*"], maxAgeSeconds = 600}]
    assert s.lifecycleRules == [{id = "rule-2", prefix = "tmp/", expirationDays = 30}, {id = "rule-3", transitionDays = 365, transitionStorageClass = "archive"}], "tier rule folded, ids by position"
    assert f.notes == ["lifecycle rule rule-4: no age condition (versions, dates or state instead), dropped"]
}

test_gcp_pulumi = lambda {
    f = _by_name(_adopt("testdata/pulumi-export.json"), "media-1b2c")
    s = f.spec
    assert s.storageClass == "standard" and s.region == "EU"
    assert s.forceDestroy == True and s.requesterPays == True
    assert s.uniformAccess == False and s.blockPublicAccess == False, "inherited is not enforced"
    assert s.retention == {days = 1, mode = "compliance"}, "locked -> compliance; 90000s rounds down"
    assert f.notes == ["retention period 90000s is not whole days, rounded down to 1"]
    assert s.lifecycleRules == [{id = "rule-1", prefix = "tmp/", expirationDays = 90}]
    assert s.cors[0].headers == ["X-Foo"] and s.cors[0].maxAgeSeconds == 120
}

# ---- azure mapping ----------------------------------------------------------
test_azure = lambda {
    tf = _by_name(_adopt("testdata/terraform-show.json"), "legacyst01")
    assert tf.provider == "azure" and tf.resourceGroup == "rg-legacy", "the resource group is what the ARM id needs"
    assert tf.spec == {region = "westeurope", storageClass = "nearline", tags = {team = "platform"}}, "Cool -> nearline"
    pu = _by_name(_adopt("testdata/pulumi-export.json"), "legacyst02")
    assert pu.resourceGroup == "rg-legacy" and pu.spec == {region = "westeurope", storageClass = "standard"}, "Hot -> standard, empty tags dropped"
}

# ---- xr ---------------------------------------------------------------------
test_k8s_name = lambda {
    assert lib.k8s_name("legacy-assets-8f3a1c") == "legacy-assets-8f3a1c"
    assert lib.k8s_name("My.Bucket_2024") == "my-bucket-2024", "dots, underscores and case are not DNS-1123"
    assert lib.k8s_name("-x-") == "x", "no leading or trailing dash"
    assert len(lib.k8s_name("a" * 80)) == 63, "label length"
}

# The XR adopts, never creates: import pinned to the cloud name, observe +
# Orphan by default, provider picked from the state, notes as an annotation.
test_xr = lambda {
    f = _by_name(_adopt("testdata/terraform-aws.tfstate.json"), "legacy-assets-8f3a1c")
    x = lib.xr(f, lib.Options {})
    assert x.apiVersion == "cloud.example.org/v1alpha1" and x.kind == "Bucket"
    assert x.metadata.name == "legacy-assets-8f3a1c" and x.metadata.namespace == "default"
    assert x.spec["import"] == {existingName = "legacy-assets-8f3a1c", mode = "observe", source = "terraform", address = "aws_s3_bucket.assets"}
    assert x.spec.deletionPolicy == "Orphan", "deleting the XR must never delete an adopted bucket by default"
    assert x.spec.crossplane.compositionSelector.matchLabels.provider == "aws"
    assert x.metadata.annotations["cloud.example.org/import-notes"].startswith("lifecycle rule paused"), "notes travel with the XR"
    assert x.spec.region == "us-east-1" and x.spec.encryptionKmsKeyId != Undefined, "the mapped spec is carried whole"
    # Options are honoured; Azure carries its resource group into the import block.
    az = lib.xr(_by_name(_adopt("testdata/terraform-show.json"), "legacyst01"), lib.Options {namespace = "prod", mode = "manage", deletionPolicy = "Delete", source = "other"})
    assert az.metadata.namespace == "prod" and az.spec.deletionPolicy == "Delete"
    assert az.spec["import"] == {existingName = "legacyst01", mode = "manage", source = "other", address = "azurerm_storage_account.legacy", resourceGroup = "rg-legacy"}
    assert az.metadata?.annotations == Undefined, "no notes, no annotation"
}
