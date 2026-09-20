"""Forgejo backend: the in-cluster registry that serves every format.

Forgejo's package registry speaks npm, PyPI, Maven, Go, Cargo, NuGet, generic
and OCI from one deployment, under `/api/packages/<owner>/<format>`. The chart
pin and the Service-name contract are the ones packages/cloud/forge/forgejo
already uses, so both capabilities install the same forge.
"""

from function.spec import FORMATS, Spec, SpecError, at_provider, management

NAME = "forgejo"

API_VERSION = "helm.m.crossplane.io/v1beta1"

SUPPORTED = frozenset(FORMATS)

UNSUPPORTED_HINT = "Forgejo serves every format this XRD defines."

# provider-helm pulls an OCI chart as `<repository>/<name>:<version>`, so the
# registry PATH and the chart NAME stay split.
CHART_REPOSITORY = "oci://code.forgejo.org/forgejo-helm"
CHART_NAME = "forgejo"
CHART_VERSION = "17.1.5"

#: The chart's web/API port (`service.http.port`).
HTTP_PORT = 3000


def service_name(spec: Spec) -> str:
    """The chart's web Service name, given `fullnameOverride = <xr name>`."""
    return f"{spec.name}-http"


def service_host(spec: Spec) -> str:
    """Host:port the in-cluster package API is reachable at."""
    return f"{service_name(spec)}.{spec.namespace}.svc.cluster.local:{HTTP_PORT}"


def _require(spec: Spec) -> None:
    if spec.owner and spec.admin_secret:
        return
    msg = (
        "package-registry-forgejo: spec.owner and spec.adminSecret are required "
        "(the Forgejo user that owns the packages, and the existing Secret with "
        "`username`/`password` keys the chart creates it from; username must "
        "equal spec.owner)"
    )
    raise SpecError(msg)


def chart_values(spec: Spec) -> dict:
    """Everything the XR says about the chart, in one place."""
    host = service_host(spec)
    domain = host.rsplit(":", 1)[0]
    return {
        # Every chart resource name derives from this, including the Service
        # the endpoints are built from.
        "fullnameOverride": spec.name,
        "persistence": {"enabled": True, "size": f"{spec.storage_gb}Gi"},
        # In-cluster only, like the zot backend: no ingress, no TLS story.
        "ingress": {"enabled": False},
        "gitea": {
            "admin": {"existingSecret": spec.admin_secret},
            "config": {
                # ROOT_URL/DOMAIN are set explicitly rather than left to the
                # chart's derivation: Forgejo writes ROOT_URL into every
                # package registry URL it hands a client back.
                "server": {
                    "ROOT_URL": f"http://{host}/",
                    "DOMAIN": domain,
                },
                "packages": {"ENABLED": True},
                "service": {
                    "DISABLE_REGISTRATION": True,
                    "REQUIRE_SIGNIN_VIEW": not spec.public_access,
                },
            },
        },
    }


def render(spec: Spec) -> dict[str, dict]:
    """Compose the Helm Release that installs Forgejo.

    Raises:
        SpecError: the owner or the admin Secret is missing.
    """
    _require(spec)
    # external-name pins the Helm release name to the XR name, which is what
    # makes the chart's Service name — and therefore every endpoint below —
    # predictable.
    return {
        "managed": {
            "apiVersion": API_VERSION,
            "kind": "Release",
            "metadata": {"annotations": {"crossplane.io/external-name": spec.name}},
            "spec": {
                **management(spec),
                "providerConfigRef": {
                    "kind": "ClusterProviderConfig",
                    "name": "default",
                },
                "forProvider": {
                    "namespace": spec.namespace,
                    "chart": {
                        "name": CHART_NAME,
                        "repository": CHART_REPOSITORY,
                        "version": CHART_VERSION,
                    },
                    "values": chart_values(spec),
                    "wait": True,
                    "waitTimeout": "10m",
                },
            },
        }
    }


def endpoint(spec: Spec, fmt: str) -> str:
    """The client-facing endpoint of one package format.

    Each is the string the matching client is configured with: a docker
    host/path for OCI, a registry URL for npm, a sparse index for cargo, the
    service index for NuGet.
    """
    host = service_host(spec)
    api = f"http://{host}/api/packages/{spec.owner}"
    return {
        "oci": f"{host}/{spec.owner}",
        "npm": f"{api}/npm/",
        "pypi": f"{api}/pypi",
        "maven": f"{api}/maven",
        "go": f"{api}/go",
        "cargo": f"sparse+http://{host}/api/packages/{spec.owner}/cargo/",
        "nuget": f"{api}/nuget/index.json",
        "generic": f"{api}/generic",
    }[fmt]


def status(spec: Spec, observed: dict[str, dict]) -> dict:
    """The XR status block.

    Readiness comes from the Release's Ready CONDITION rather than
    atProvider.state: `deployed` is Helm's verdict on the release, while Ready
    also carries provider-helm's own `wait` result.
    """
    release = observed.get("managed") or {}
    conditions = (release.get("status") or {}).get("conditions") or []
    ready = any(
        c.get("type") == "Ready" and c.get("status") == "True" for c in conditions
    )
    at = at_provider(observed, "managed")

    out: dict = {
        "provider": NAME,
        "ready": ready,
        "registryName": spec.name,
        "region": spec.region,
        "endpoints": {fmt: endpoint(spec, fmt) for fmt in spec.formats},
        "cloud-url": f"kubernetes://{spec.namespace}/deployment/{spec.name}",
    }
    if spec.admin_secret:
        out["authSecret"] = spec.admin_secret
    if at.get("revision"):
        out["id"] = f"{spec.namespace}/{spec.name}@{at['revision']}"
    return out
