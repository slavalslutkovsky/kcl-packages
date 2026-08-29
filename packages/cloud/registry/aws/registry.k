# registry (aws) — Crossplane Composition logic (function-kcl module).
# Typed against the aws-ecr schema package. The portable Registry maps onto one
# ECR Repository plus two companion policy MRs bound to it by controller
# reference: a lifecycle policy (retention) and a repository policy (anonymous
# pull). Registry-wide ECR resources (RegistryScanningConfiguration,
# ReplicationConfiguration) are deliberately NOT composed — they configure the
# whole account registry, so one XR would silently overwrite another's settings.
import json
import aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_repository as backend
import aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_lifecycle_policy as lifecycle
import aws_ecr.models.v1beta1.ecr_awsm_upbound_io_v1beta1_repository_policy as repopolicy

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The pull actions an anonymous principal needs: fetch the manifest
# (BatchGetImage), the layers (GetDownloadUrlForLayer) and the layer existence
# check the docker client makes first (BatchCheckLayerAvailability).
_pull_actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]

# ECR lifecycle policy document. Rules are evaluated by ascending rulePriority
# and an `any` rule must come last (ECR rejects a policy where a tagStatus=any
# rule is not the highest priority).
lifecycle_policy = lambda untagged_days: any, keep_last: any -> str {
    _rules = []
    if untagged_days != Undefined:
        _rules += [{
            rulePriority = 1
            description = "expire untagged images after ${untagged_days} days"
            selection = {
                tagStatus = "untagged"
                countType = "sinceImagePushed"
                countUnit = "days"
                countNumber = untagged_days
            }
            action = {$type = "expire"}
        }]

    if keep_last != Undefined:
        _rules += [{
            rulePriority = 2
            description = "keep the ${keep_last} most recent images"
            selection = {
                tagStatus = "any"
                countType = "imageCountMoreThan"
                countNumber = keep_last
            }
            action = {$type = "expire"}
        }]

    json.encode({rules = _rules})
}

# Repository policy granting anonymous (any principal) pull.
public_pull_policy = lambda {
    json.encode({
        Version = "2012-10-17"
        Statement = [{
            Sid = "AllowAnonymousPull"
            Effect = "Allow"
            Principal = "*"
            Action = _pull_actions
        }]
    })
}

render = lambda oxr {
    _spec = oxr.spec
    _region = _spec.region

    _immutable = _spec?.immutableTags or False

    _scan = _spec?.scanOnPush
    if _scan == Undefined:
        _scan = True

    # `or Undefined` normalizes the two shapes an absent optional key can take
    # (missing -> Undefined, explicit null -> None) to one sentinel; both mean
    # "no retention asked for", and neither day count nor image count can be 0.
    _untagged = _spec?.untaggedRetentionDays or Undefined
    _keep = _spec?.keepLastImages or Undefined

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # Common scaffolding for a companion policy MR: name annotation, region,
    # controller binding back to the Repository above.
    _attach = lambda name: str -> any {
        _c = {
            metadata.annotations = {"krm.kcl.dev/composition-resource-name" = name}
            spec.forProvider.region = _region
            spec.forProvider.repositorySelector.matchControllerRef = True
        }
        _c | {spec.managementPolicies = _mp} if _mp else _c
    }

    # 1) The repository itself. external-name pins the ECR repository name to
    # the XR name: it is part of every image reference, so it cannot be the
    # random name Crossplane generates for the composed resource.
    _items: [any] = [backend.Repository {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = oxr.metadata.name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.region = _region
        spec.forProvider.imageTagMutability = "IMMUTABLE" if _immutable else "MUTABLE"
        spec.forProvider.imageScanningConfiguration = {scanOnPush = _scan}
        spec.forProvider.forceDelete = _spec?.forceDestroy or False
        # Omitted entirely for the default AES256 key: an empty
        # encryptionConfiguration block is a diff ECR cannot reconcile.
        if _spec?.encryptionKeyId:
            spec.forProvider.encryptionConfiguration = [{
                encryptionType = "KMS"
                kmsKey = _spec.encryptionKeyId
            }]
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    # 2) Retention, as a lifecycle policy document.
    if _untagged != Undefined or _keep != Undefined:
        _items += [lifecycle.LifecyclePolicy {
            **_attach("lifecycle")
            spec.forProvider.policy = lifecycle_policy(_untagged, _keep)
        }]

    # 3) Anonymous pull, as a repository policy document.
    if _spec?.publicAccess or False:
        _items += [repopolicy.RepositoryPolicy {
            **_attach("public-policy")
            spec.forProvider.policy = public_pull_policy()
        }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    _region = (_at?.region) or oxr.spec.region

    # <account>.dkr.ecr.<region>.amazonaws.com/<name> — known only once ECR
    # reports it back, since the account id is not part of the XR.
    _repo = _at?.repositoryUrl or ""
    _host = _repo.split("/")[0] if _repo else ""
    _account = _at?.registryId or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Registry"
        metadata.name = _name
        status = {
            provider = "aws"
            ready = (_at?.arn or "") != ""
            registryName = _name
            region = _region
            "cloud-url" = "https://${_region}.console.aws.amazon.com/ecr/repositories/private/${_account}/${_name}?region=${_region}" if _account else "https://${_region}.console.aws.amazon.com/ecr/repositories?region=${_region}"
            if _repo:
                endpoint = _host
                repository = _repo
                url = "oci://${_repo}"
            if _at?.arn:
                arn = _at.arn
            if _at?.id:
                id = _at.id
        }
    }
}
