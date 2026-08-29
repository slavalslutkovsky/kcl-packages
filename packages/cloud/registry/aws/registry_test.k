# Unit tests for the registry (aws) function-kcl module.
# Contract under test:
#   render(oxr) -> [resource]   (provider managed resources, no composite)
#   status(oxr, ocds) -> dxr    (single desired-composite carrying .status)
# Escaped schema keys ($type) serialize to plain keys, so decoded policy
# documents are indexed by the de-escaped string key (x["type"]).
import json
import .registry

_orphan = ["Observe", "Create", "Update", "LateInitialize"]

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with render()'s `oxr` parameter — KCL
# normalizes the leading underscore, so a helper named `_oxr` shadows it.

# An observed composite XR carrying the base spec merged with `extra`.
_build = lambda extra: any -> any {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Registry", metadata.name = "demo", spec = {region = "us-east-1"} | extra}
}

_by_kind = lambda items: [any], kind: str -> any {
    _hit = [_i for _i in items if _i.kind == kind]
    _hit[0] if _hit else Undefined
}

_kinds = lambda items: [any] -> [str] {
    [_i.kind for _i in items]
}

# 1) Minimal spec: exactly one MR — the Repository, mutable, scanning on push.
test_render_minimal = lambda {
    items = registry.render(_build({}))
    assert len(items) == 1, "minimal spec must render exactly one managed resource"
    assert items[0].apiVersion == "ecr.aws.m.upbound.io/v1beta1", "wrong Repository apiVersion"
    assert items[0].kind == "Repository", "first item must be the Repository"
    assert items[0].metadata.annotations["crossplane.io/external-name"] == "demo", "the ECR repository name must be pinned to the XR name"
    _fp = items[0].spec.forProvider
    assert _fp.region == "us-east-1", "region must reach the repository"
    assert _fp.imageTagMutability == "MUTABLE", "tags must be mutable by default"
    assert _fp.imageScanningConfiguration.scanOnPush == True, "scanOnPush must default to true"
    assert _fp.forceDelete == False, "forceDestroy must default to false"
    assert _fp?.encryptionConfiguration == Undefined, "no KMS key means no encryptionConfiguration block"
}

# 2) immutableTags / scanOnPush / forceDestroy flip the repository fields.
test_repository_flags = lambda {
    _fp = registry.render(_build({immutableTags = True, scanOnPush = False, forceDestroy = True}))[0].spec.forProvider
    assert _fp.imageTagMutability == "IMMUTABLE", "immutableTags must set IMMUTABLE"
    assert _fp.imageScanningConfiguration.scanOnPush == False, "scanOnPush=false must reach ECR"
    assert _fp.forceDelete == True, "forceDestroy must set forceDelete"
}

# 3) encryptionKeyId switches ECR to SSE-KMS with that key.
test_encryption_kms = lambda {
    _key = "arn:aws:kms:us-east-1:111122223333:key/abcd"
    _enc = registry.render(_build({encryptionKeyId = _key}))[0].spec.forProvider.encryptionConfiguration
    assert len(_enc) == 1, "one encryption configuration block"
    assert _enc[0].encryptionType == "KMS", "encryption type must be KMS"
    assert _enc[0].kmsKey == _key, "the supplied key must be referenced"
}

# 4) Retention renders a lifecycle policy: untagged expiry at priority 1, the
#    image-count rule (tagStatus any) last, as ECR requires.
test_lifecycle_untagged_only = lambda {
    items = registry.render(_build({untaggedRetentionDays = 14}))
    assert _kinds(items) == ["Repository", "LifecyclePolicy"], "untagged retention must add the lifecycle policy"
    _lp = _by_kind(items, "LifecyclePolicy")
    assert _lp.spec.forProvider.repositorySelector.matchControllerRef == True, "policy must bind to the composed repository"
    _rules = json.decode(_lp.spec.forProvider.policy)["rules"]
    assert len(_rules) == 1, "only the untagged rule was asked for"
    _sel = _rules[0]["selection"]
    assert _sel["tagStatus"] == "untagged", "rule must target untagged images"
    assert _sel["countType"] == "sinceImagePushed" and _sel["countUnit"] == "days", "untagged rule must expire by age"
    assert _sel["countNumber"] == 14, "retention days must be carried through"
    assert _rules[0]["action"]["type"] == "expire", "action must be expire"
}
test_lifecycle_both_rules = lambda {
    _lp = _by_kind(registry.render(_build({untaggedRetentionDays = 7, keepLastImages = 20})), "LifecyclePolicy")
    _rules = json.decode(_lp.spec.forProvider.policy)["rules"]
    assert len(_rules) == 2, "both retention rules must be present"
    assert _rules[0]["rulePriority"] == 1 and _rules[1]["rulePriority"] == 2, "priorities must ascend"
    assert _rules[1]["selection"]["tagStatus"] == "any", "the image-count rule must be the tagStatus=any rule"
    assert _rules[1]["selection"]["countType"] == "imageCountMoreThan", "keepLastImages must expire by count"
    assert _rules[1]["selection"]["countNumber"] == 20, "keepLastImages must be carried through"
}
test_lifecycle_keep_only = lambda {
    _lp = _by_kind(registry.render(_build({keepLastImages = 5})), "LifecyclePolicy")
    _rules = json.decode(_lp.spec.forProvider.policy)["rules"]
    assert len(_rules) == 1 and _rules[0]["selection"]["countType"] == "imageCountMoreThan", "only the count rule"
}

# 5) publicAccess adds a repository policy granting anonymous pull only.
test_public_access = lambda {
    items = registry.render(_build({publicAccess = True}))
    assert _kinds(items) == ["Repository", "RepositoryPolicy"], "publicAccess must add the repository policy"
    _rp = _by_kind(items, "RepositoryPolicy")
    assert _rp.spec.forProvider.repositorySelector.matchControllerRef == True, "policy must bind to the composed repository"
    _stmt = json.decode(_rp.spec.forProvider.policy)["Statement"][0]
    assert _stmt["Effect"] == "Allow" and _stmt["Principal"] == "*", "anonymous principals must be allowed"
    assert "ecr:BatchGetImage" in _stmt["Action"], "pull requires BatchGetImage"
    assert "ecr:GetDownloadUrlForLayer" in _stmt["Action"], "pull requires GetDownloadUrlForLayer"
    assert "ecr:PutImage" not in _stmt["Action"], "anonymous push must never be granted"
}
test_private_by_default = lambda {
    assert _by_kind(registry.render(_build({})), "RepositoryPolicy") == Undefined, "no repository policy without publicAccess"
}

# 6) deletionPolicy=Orphan stamps the orphan managementPolicies on every MR;
#    default Delete leaves them off (provider default ["*"] applies).
test_deletion_policy_orphan = lambda {
    items = registry.render(_build({deletionPolicy = "Orphan", untaggedRetentionDays = 3, publicAccess = True}))
    _missing = [_i.kind for _i in items if _i.spec.managementPolicies != _orphan]
    assert _missing == [], "every MR must carry the orphan policies, missing on: ${_missing}"
}
test_deletion_policy_delete_default = lambda {
    items = registry.render(_build({untaggedRetentionDays = 3, publicAccess = True}))
    _stamped = [_i.kind for _i in items if _i.spec.managementPolicies == _orphan]
    assert _stamped == [], "Delete must not set the orphan policies, set on: ${_stamped}"
}

# 7) Kitchen sink: all three MRs, in a fixed order.
test_kitchen_sink = lambda {
    items = registry.render(_build({
        immutableTags = True
        scanOnPush = True
        publicAccess = True
        untaggedRetentionDays = 30
        keepLastImages = 10
        encryptionKeyId = "arn:aws:kms:us-east-1:111122223333:key/abcd"
        forceDestroy = True
        tags = {team = "platform"}
    }))
    assert _kinds(items) == ["Repository", "LifecyclePolicy", "RepositoryPolicy"], "unexpected ordered kinds"
    assert items[0].spec.forProvider.tags == {team = "platform"}, "tags must reach the repository"
}

# 8) status before creation: not ready, no invented repository path.
test_status_pre_creation = lambda {
    dxr = registry.status(_build({}), {})
    assert dxr.apiVersion == "cloud.example.org/v1alpha1", "dxr apiVersion must echo the composite"
    assert dxr.kind == "Registry", "dxr kind must echo the composite"
    assert dxr.status.ready == False, "pre-creation must be not ready"
    assert dxr.status.provider == "aws", "provider must be aws"
    assert dxr.status.registryName == "demo", "registry name is the XR name"
    assert dxr.status?.repository == Undefined, "the ECR host is unknown until observed"
    assert dxr.status["cloud-url"].startswith("https://us-east-1.console.aws.amazon.com/ecr/repositories"), "cloud-url must point at ECR"
}

# 9) status after creation: ready, endpoint split off the observed repositoryUrl.
test_status_observed = lambda {
    ocds = {
        managed.Resource.status.atProvider = {
            arn = "arn:aws:ecr:us-east-1:111122223333:repository/demo"
            id = "demo"
            region = "us-east-1"
            registryId = "111122223333"
            repositoryUrl = "111122223333.dkr.ecr.us-east-1.amazonaws.com/demo"
        }
    }
    dxr = registry.status(_build({}), ocds)
    assert dxr.status.ready == True, "observed arn must mark the registry ready"
    assert dxr.status.endpoint == "111122223333.dkr.ecr.us-east-1.amazonaws.com", "endpoint is the host of repositoryUrl"
    assert dxr.status.repository == "111122223333.dkr.ecr.us-east-1.amazonaws.com/demo", "repository is the full push path"
    assert dxr.status.url == "oci://111122223333.dkr.ecr.us-east-1.amazonaws.com/demo", "url must be the oci:// form"
    assert dxr.status.arn == "arn:aws:ecr:us-east-1:111122223333:repository/demo", "arn must be surfaced"
    assert dxr.status.id == "demo", "observed id must be surfaced"
    assert dxr.status["cloud-url"] == "https://us-east-1.console.aws.amazon.com/ecr/repositories/private/111122223333/demo?region=us-east-1", "cloud-url must address the repository"
}

test_render_minimal()
test_repository_flags()
test_encryption_kms()
test_lifecycle_untagged_only()
test_lifecycle_both_rules()
test_lifecycle_keep_only()
test_public_access()
test_private_by_default()
test_deletion_policy_orphan()
test_deletion_policy_delete_default()
test_kitchen_sink()
test_status_pre_creation()
test_status_observed()
