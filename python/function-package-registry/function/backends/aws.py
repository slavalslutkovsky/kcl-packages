"""AWS backend: ECR for containers and charts, CodeArtifact for language packages.

The ECR half is ported from packages/cloud/registry/aws/registry.k, policy
documents included. Registry-wide ECR resources (RegistryScanningConfiguration,
ReplicationConfiguration) are deliberately NOT composed — they configure the
whole account registry, so one XR would silently overwrite another's settings.

CodeArtifact repositories are polyglot: ONE repository serves every format
under `/<format>/<repository>/`, so a domain and a repository are composed once
no matter how many language formats the XR asks for
(https://docs.aws.amazon.com/codeartifact/latest/ug/packages-overview.html).

Helm charts are OCI artifacts in ECR, but an ECR repository holds ONE chart,
named after it, and the XR does not know its charts:
https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html
So `helm` composes a repository creation template with CREATE_ON_PUSH for the
prefix `<xr name>/charts`: `helm push <chart>.tgz oci://<registry>/<xr
name>/charts` makes ECR create `<xr name>/charts/<chart>` with the template's
settings:
https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html
Those repositories are ECR's, not this XR's: deleting the XR removes the
template and leaves pushed charts in place.

Typed against the generated models in function/models/aws_{ecr,codeartifact}.
"""

import json

from function.models.aws_codeartifact import domain as ca_domain
from function.models.aws_codeartifact import repository as ca_repository
from function.models.aws_ecr import lifecycle_policy as ecr_lifecycle
from function.models.aws_ecr import repository as ecr_repository
from function.models.aws_ecr import repository_creation_template as ecr_template
from function.models.aws_ecr import repository_policy as ecr_policy
from function.spec import Spec, SpecError, at_provider, management

NAME = "aws"

ECR_API = "ecr.aws.m.upbound.io/v1beta1"
CA_API = "codeartifact.aws.m.upbound.io/v1beta1"

#: XR format -> the path segment CodeArtifact serves it under (the `format`
#: values of GetRepositoryEndpoint).
CA_FORMAT = {
    "npm": "npm",
    "pypi": "pypi",
    "maven": "maven",
    "cargo": "cargo",
    "nuget": "nuget",
    "generic": "generic",
    "rubygems": "ruby",
    "swift": "swift",
}

#: The ECR-served formats.
ECR_FORMATS = frozenset({"oci", "helm"})

SUPPORTED = ECR_FORMATS | frozenset(CA_FORMAT)

UNSUPPORTED_HINT = "CodeArtifact has no go, composer or conan format."

# The pull actions an anonymous principal needs: fetch the manifest
# (BatchGetImage), the layers (GetDownloadUrlForLayer) and the layer existence
# check the docker client makes first (BatchCheckLayerAvailability).
PULL_ACTIONS = [
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchCheckLayerAvailability",
]


def lifecycle_policy(untagged_days: int | None, keep_last: int | None) -> str:
    """The ECR lifecycle policy document.

    Rules are evaluated by ascending rulePriority and an `any` rule must come
    last (ECR rejects a policy where a tagStatus=any rule is not the highest
    priority).
    """
    rules = []
    if untagged_days:
        rules.append(
            {
                "rulePriority": 1,
                "description": f"expire untagged images after {untagged_days} days",
                "selection": {
                    "tagStatus": "untagged",
                    "countType": "sinceImagePushed",
                    "countUnit": "days",
                    "countNumber": untagged_days,
                },
                "action": {"type": "expire"},
            }
        )
    if keep_last:
        rules.append(
            {
                "rulePriority": 2,
                "description": f"keep the {keep_last} most recent images",
                "selection": {
                    "tagStatus": "any",
                    "countType": "imageCountMoreThan",
                    "countNumber": keep_last,
                },
                "action": {"type": "expire"},
            }
        )
    return json.dumps({"rules": rules})


def public_pull_policy() -> str:
    """The repository policy document granting anonymous (any principal) pull."""
    return json.dumps(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Sid": "AllowAnonymousPull",
                    "Effect": "Allow",
                    "Principal": "*",
                    "Action": PULL_ACTIONS,
                }
            ],
        }
    )


def _ecr(spec: Spec) -> ecr_repository.Repository:
    # external-name pins the ECR repository name to the XR name: it is part of
    # every image reference, so it cannot be the random name Crossplane
    # generates for the composed resource.
    for_provider = ecr_repository.ForProvider(
        region=spec.region,
        imageTagMutability="IMMUTABLE" if spec.immutable_tags else "MUTABLE",
        imageScanningConfiguration=ecr_repository.ImageScanningConfiguration(
            scanOnPush=spec.scan_on_push
        ),
        forceDelete=spec.force_destroy,
    )
    # Omitted entirely for the default AES256 key: an empty
    # encryptionConfiguration block is a diff ECR cannot reconcile.
    if spec.encryption_key_id:
        for_provider.encryptionConfiguration = [
            ecr_repository.EncryptionConfigurationItem(
                encryptionType="KMS", kmsKey=spec.encryption_key_id
            )
        ]
    if spec.tags:
        for_provider.tags = dict(spec.tags)
    return ecr_repository.Repository(
        apiVersion=ECR_API,
        kind="Repository",
        metadata={"annotations": {"crossplane.io/external-name": spec.name}},
        spec=ecr_repository.Spec(forProvider=for_provider, **management(spec)),
    )


def _ecr_lifecycle(spec: Spec) -> ecr_lifecycle.LifecyclePolicy:
    # Bound to the Repository above by controller reference rather than by
    # name, so the two cannot drift apart.
    return ecr_lifecycle.LifecyclePolicy(
        apiVersion=ECR_API,
        kind="LifecyclePolicy",
        spec=ecr_lifecycle.Spec(
            forProvider=ecr_lifecycle.ForProvider(
                region=spec.region,
                repositorySelector=ecr_lifecycle.RepositorySelector(
                    matchControllerRef=True
                ),
                policy=lifecycle_policy(
                    spec.untagged_retention_days, spec.keep_last_images
                ),
            ),
            **management(spec),
        ),
    )


def _ecr_public_policy(spec: Spec) -> ecr_policy.RepositoryPolicy:
    return ecr_policy.RepositoryPolicy(
        apiVersion=ECR_API,
        kind="RepositoryPolicy",
        spec=ecr_policy.Spec(
            forProvider=ecr_policy.ForProvider(
                region=spec.region,
                repositorySelector=ecr_policy.RepositorySelector(
                    matchControllerRef=True
                ),
                policy=public_pull_policy(),
            ),
            **management(spec),
        ),
    )


def _ca_domain(spec: Spec) -> ca_domain.Domain:
    for_provider = ca_domain.ForProvider(region=spec.region, domain=spec.name)
    if spec.encryption_key_id:
        for_provider.encryptionKey = spec.encryption_key_id
    if spec.tags:
        for_provider.tags = dict(spec.tags)
    return ca_domain.Domain(
        apiVersion=CA_API,
        kind="Domain",
        metadata={"annotations": {"crossplane.io/external-name": spec.name}},
        spec=ca_domain.Spec(forProvider=for_provider, **management(spec)),
    )


def _ca_repository(spec: Spec) -> ca_repository.Repository:
    for_provider = ca_repository.ForProvider(
        region=spec.region,
        repository=spec.name,
        domainSelector=ca_repository.DomainSelector(matchControllerRef=True),
    )
    if spec.tags:
        for_provider.tags = dict(spec.tags)
    return ca_repository.Repository(
        apiVersion=CA_API,
        kind="Repository",
        metadata={"annotations": {"crossplane.io/external-name": spec.name}},
        spec=ca_repository.Spec(forProvider=for_provider, **management(spec)),
    )


def charts_prefix(spec: Spec) -> str:
    """The ECR repository prefix pushed charts are created under."""
    return f"{spec.name}/charts"


def _helm_template(spec: Spec) -> ecr_template.RepositoryCreationTemplate:
    # A template applies a KMS key (and resource tags) only through an IAM
    # creation role, and repository creation FAILS without one. The XRD models
    # no such role, and quietly falling back to AES256 would weaken the
    # encryption the XR asked for — so refuse instead.
    if spec.encryption_key_id:
        msg = (
            "package-registry-aws: helm charts live in ECR repositories created "
            "on push from a repository creation template, and a template can "
            "apply a customer-managed KMS key only through an IAM creation role "
            "this XRD does not model; drop spec.encryptionKeyId or serve helm "
            "from another backend (gcp, azure, zot, forgejo)"
        )
        raise SpecError(msg)
    for_provider = ecr_template.ForProvider(
        region=spec.region,
        prefix=charts_prefix(spec),
        appliedFor=["CREATE_ON_PUSH"],
        description=f"helm charts of PackageRegistry {spec.namespace}/{spec.name}",
        imageTagMutability="IMMUTABLE" if spec.immutable_tags else "MUTABLE",
    )
    if spec.untagged_retention_days or spec.keep_last_images:
        for_provider.lifecyclePolicy = lifecycle_policy(
            spec.untagged_retention_days, spec.keep_last_images
        )
    if spec.public_access:
        for_provider.repositoryPolicy = public_pull_policy()
    # The template's identifier is its prefix.
    return ecr_template.RepositoryCreationTemplate(
        apiVersion=ECR_API,
        kind="RepositoryCreationTemplate",
        metadata={"annotations": {"crossplane.io/external-name": charts_prefix(spec)}},
        spec=ecr_template.Spec(forProvider=for_provider, **management(spec)),
    )


def language_formats(spec: Spec) -> list[str]:
    """The requested formats CodeArtifact serves, in XR order."""
    return [fmt for fmt in spec.formats if fmt not in ECR_FORMATS]


def render(spec: Spec) -> dict[str, object]:
    """Compose the ECR repository, the chart template and/or CodeArtifact.

    Raises:
        SpecError: helm was asked for together with a customer-managed key.
    """
    out: dict[str, object] = {}
    if "oci" in spec.formats:
        out["ecr"] = _ecr(spec)
        if spec.untagged_retention_days or spec.keep_last_images:
            out["ecr-lifecycle"] = _ecr_lifecycle(spec)
        if spec.public_access:
            out["ecr-public-policy"] = _ecr_public_policy(spec)
    if "helm" in spec.formats:
        out["ecr-helm-template"] = _helm_template(spec)
    if language_formats(spec):
        out["ca-domain"] = _ca_domain(spec)
        out["ca-repository"] = _ca_repository(spec)
    return out


def _console_url(spec: Spec, region: str, account: str, owner: str) -> str:
    if "oci" in spec.formats and account:
        return (
            f"https://{region}.console.aws.amazon.com/ecr/repositories/private/"
            f"{account}/{spec.name}?region={region}"
        )
    if "oci" in spec.formats or not language_formats(spec):
        return (
            f"https://{region}.console.aws.amazon.com/ecr/repositories?region={region}"
        )
    if owner:
        return (
            f"https://{region}.console.aws.amazon.com/codesuite/codeartifact/d/"
            f"{owner}/{spec.name}/r/{spec.name}?region={region}"
        )
    return (
        f"https://{region}.console.aws.amazon.com/codesuite/codeartifact/"
        f"domains?region={region}"
    )


def status(spec: Spec, observed: dict[str, dict]) -> dict:
    """The XR status block, from whatever the providers have reported so far."""
    ecr = at_provider(observed, "ecr")
    template = at_provider(observed, "ecr-helm-template")
    domain = at_provider(observed, "ca-domain")
    repo = at_provider(observed, "ca-repository")
    langs = language_formats(spec)
    wants_oci = "oci" in spec.formats
    wants_helm = "helm" in spec.formats

    region = str(
        ecr.get("region")
        or template.get("region")
        or domain.get("region")
        or spec.region
    )
    # The CodeArtifact endpoint carries the account that owns the domain; the
    # Repository CRD reports no endpoint of its own.
    owner = str(domain.get("owner") or "")
    registry_id = str(ecr.get("registryId") or template.get("registryId") or "")

    endpoints = {}
    if ecr.get("repositoryUrl"):
        endpoints["oci"] = str(ecr["repositoryUrl"])
    if wants_helm and template.get("id") and registry_id:
        # What `helm push` takes; ECR appends the chart name.
        endpoints["helm"] = (
            f"oci://{registry_id}.dkr.ecr.{region}.amazonaws.com/{charts_prefix(spec)}"
        )
    if owner:
        for fmt in langs:
            endpoints[fmt] = (
                f"https://{spec.name}-{owner}.d.codeartifact.{region}.amazonaws.com/"
                f"{CA_FORMAT[fmt]}/{spec.name}/"
            )

    if wants_oci:
        primary = ecr
    elif langs:
        primary = domain
    else:
        primary = template
    out: dict = {
        "provider": NAME,
        "ready": (not wants_oci or bool(ecr.get("arn")))
        and (not wants_helm or bool(template.get("id")))
        and (not langs or (bool(domain.get("arn")) and bool(repo.get("arn")))),
        "registryName": spec.name,
        "region": region,
        "cloud-url": _console_url(
            spec, region, str(ecr.get("registryId") or ""), owner
        ),
    }
    if endpoints:
        out["endpoints"] = endpoints
    if primary.get("arn"):
        out["arn"] = str(primary["arn"])
    if primary.get("id"):
        out["id"] = str(primary["id"])
    return out
