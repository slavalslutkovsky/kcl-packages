"""GCP backend: one Artifact Registry repository per requested format.

Ported from packages/cloud/registry/gcp/registry.k, which composes the DOCKER
repository only. Artifact Registry is natively polyglot — the same regional
service hosts npm, python, maven and go repositories — so the mapping is one
`RegistryRepository` per format, each with its own `format` and its own id.
"""

from function.spec import Spec, at_provider, management

NAME = "gcp"

API_VERSION = "artifact.gcp.m.upbound.io/v1beta1"

#: XR format -> Artifact Registry repository format.
AR_FORMAT = {
    "oci": "DOCKER",
    "npm": "NPM",
    "pypi": "PYTHON",
    "maven": "MAVEN",
    "go": "GO",
    "generic": "GENERIC",
}

#: XR format -> the service host segment Artifact Registry serves it on
#: (`<location>-<segment>.pkg.dev`).
AR_HOST = {
    "oci": "docker",
    "npm": "npm",
    "pypi": "python",
    "maven": "maven",
    "go": "go",
    "generic": "generic",
}

SUPPORTED = frozenset(AR_FORMAT)

UNSUPPORTED_HINT = (
    "Artifact Registry has no cargo or nuget format; "
    "use the aws or forgejo backend for those."
)

SECONDS_PER_DAY = 86400


def repo_id(spec: Spec, fmt: str) -> str:
    """The Artifact Registry repository id for one format.

    Always suffixed with the format: a repository id is unique per project and
    location, so two formats of one XR would otherwise collide. The CRD has no
    `repositoryId` field — this string is the `crossplane.io/external-name`.
    """
    return f"{spec.name}-{fmt}"


def _cleanup_policies(spec: Spec, fmt: str) -> list[dict]:
    # KEEP wins over DELETE in Artifact Registry, so the two compose without
    # ordering. "untagged" is a container concept: only the DOCKER repository
    # has versions without a tag.
    policies: list[dict] = []
    if fmt == "oci" and spec.untagged_retention_days:
        policies.append(
            {
                "id": "delete-untagged",
                "action": "DELETE",
                "condition": {
                    "tagState": "UNTAGGED",
                    "olderThan": f"{spec.untagged_retention_days * SECONDS_PER_DAY}s",
                },
            }
        )
    if spec.keep_last_images:
        policies.append(
            {
                "id": "keep-recent",
                "action": "KEEP",
                "mostRecentVersions": {"keepCount": spec.keep_last_images},
            }
        )
    return policies


def _repository(spec: Spec, fmt: str) -> dict:
    for_provider: dict = {
        "location": spec.region,
        "format": AR_FORMAT[fmt],
        "mode": "STANDARD_REPOSITORY",
        # INHERITED follows the project's Artifact Analysis setting — the only
        # way to opt IN from the repository; DISABLED opts out unconditionally.
        "vulnerabilityScanningConfig": {
            "enablementConfig": "INHERITED" if spec.scan_on_push else "DISABLED"
        },
    }
    if fmt == "oci":
        for_provider["dockerConfig"] = {"immutableTags": spec.immutable_tags}
    policies = _cleanup_policies(spec, fmt)
    if policies:
        for_provider["cleanupPolicies"] = policies
        for_provider["cleanupPolicyDryRun"] = False
    if spec.encryption_key_id:
        for_provider["kmsKeyName"] = spec.encryption_key_id
    if spec.tags:
        for_provider["labels"] = dict(spec.tags)
    return {
        "apiVersion": API_VERSION,
        "kind": "RegistryRepository",
        "metadata": {
            "annotations": {"crossplane.io/external-name": repo_id(spec, fmt)},
        },
        "spec": {**management(spec), "forProvider": for_provider},
    }


def _public_reader(spec: Spec, fmt: str) -> dict:
    # IAMMember carries no repositorySelector, but the repository's external
    # name is deterministic, so the binding is too.
    return {
        "apiVersion": API_VERSION,
        "kind": "RegistryRepositoryIAMMember",
        "spec": {
            **management(spec),
            "forProvider": {
                "location": spec.region,
                "repository": repo_id(spec, fmt),
                "role": "roles/artifactregistry.reader",
                "member": "allUsers",
            },
        },
    }


def render(spec: Spec) -> dict[str, dict]:
    """Compose one repository (and optional anonymous-read binding) per format."""
    out: dict[str, dict] = {}
    for fmt in spec.formats:
        out[f"repo-{fmt}"] = _repository(spec, fmt)
        if spec.public_access:
            out[f"public-reader-{fmt}"] = _public_reader(spec, fmt)
    return out


def _project_of(resource_id: str) -> str:
    # atProvider.id is projects/<project>/locations/<location>/repositories/<id>.
    parts = resource_id.split("/")
    return parts[1] if len(parts) > 1 else ""


def _endpoint(location: str, project: str, spec: Spec, fmt: str) -> str:
    host = f"{location}-{AR_HOST[fmt]}.pkg.dev"
    path = f"{host}/{project}/{repo_id(spec, fmt)}"
    # The docker client is given a host/path pair, every other client a URL.
    return path if fmt == "oci" else f"https://{path}/"


def status(spec: Spec, observed: dict[str, dict]) -> dict:
    """The XR status block, from whatever the provider has reported so far.

    The repository path needs the project, which the XR does not carry (it
    comes from the ProviderConfig) — so it is derived from the observed id, and
    the endpoints appear only once at least one repository exists. The CRD
    reports no registry URL of its own; `<location>-<service>.pkg.dev` is the
    documented, fully deterministic host for every Artifact Registry format.
    """
    ats = {fmt: at_provider(observed, f"repo-{fmt}") for fmt in spec.formats}
    location = next(
        (at["location"] for at in ats.values() if at.get("location")), spec.region
    )
    first = ats[spec.formats[0]]
    resource_id = str(first.get("id") or "")
    project = _project_of(resource_id)

    out: dict = {
        "provider": NAME,
        "ready": all(at.get("id") for at in ats.values()),
        "registryName": spec.name,
        "region": location,
        "cloud-url": f"https://console.cloud.google.com/artifacts?project={project}"
        if project
        else "https://console.cloud.google.com/artifacts",
    }
    if project:
        out["endpoints"] = {
            fmt: _endpoint(location, project, spec, fmt)
            for fmt, at in ats.items()
            if at.get("id")
        }
    if resource_id:
        out["id"] = resource_id
    return out
