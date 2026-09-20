"""zot backend: the in-cluster OCI registry, installed by provider-helm.

Ported verbatim from packages/cloud/registry/zot/registry.k. No cloud account,
no IAM: one namespaced Release installs the zot chart into the XR's own
namespace, and a client that pushes to ECR/Artifact Registry/ACR pushes here
unchanged.
"""

import json

from function.spec import Spec, at_provider, management

NAME = "zot"

API_VERSION = "helm.m.crossplane.io/v1beta1"

SUPPORTED = frozenset({"oci"})

UNSUPPORTED_HINT = (
    "zot is an OCI-only registry; use the forgejo backend for an in-cluster "
    "registry that also serves language packages."
)

# Pinned so a re-render never silently upgrades a running registry.
CHART_REPOSITORY = "https://zotregistry.dev/helm-charts"
CHART_NAME = "zot"
CHART_VERSION = "0.1.122"

#: The chart's container port, and the service port it publishes.
REGISTRY_PORT = 5000

#: Where the chart mounts a Secret listed in `externalSecrets`, and the
#: htpasswd file zot then reads inside it.
SECRET_MOUNT = "/secret"  # noqa: S105  # a mount path, not a credential
HTPASSWD_KEY = "htpasswd"

HOURS_PER_DAY = 24


def service_host(spec: Spec) -> str:
    """The chart's Service host, given `fullnameOverride = <xr name>`."""
    return f"{spec.name}.{spec.namespace}.svc.cluster.local"


def _storage(spec: Spec) -> dict:
    # Storage retention needs the garbage collector: without `gc` the policies
    # are recorded and never act.
    storage: dict = {
        "rootDirectory": "/var/lib/registry",
        "dedupe": True,
        "gc": True,
        "gcDelay": "1h",
    }
    if spec.untagged_retention_days is None and spec.keep_last_images is None:
        return storage

    policy: dict = {
        "repositories": ["**"],
        "deleteUntagged": spec.untagged_retention_days is not None,
    }
    if spec.keep_last_images is not None:
        # keepTags patterns are Go REGEXES (repository names above are globs):
        # ".*" is every tag, "**" does not compile.
        policy["keepTags"] = [
            {"patterns": [".*"], "mostRecentlyPushedCount": spec.keep_last_images}
        ]
    retention: dict = {"dryRun": False, "policies": [policy]}
    # Untagged images become deletable only once this delay has elapsed since
    # they were pushed; with no age limit there is no delay to set.
    if spec.untagged_retention_days is not None:
        retention["delay"] = f"{spec.untagged_retention_days * HOURS_PER_DAY}h"
    storage["retention"] = retention
    return storage


def _http(spec: Spec) -> dict:
    http: dict = {
        "address": "0.0.0.0",  # noqa: S104  # a ClusterIP Service fronts it.
        "port": str(REGISTRY_PORT),
        "readTimeout": "60s",
        "writeTimeout": "60s",
    }
    # Credentials are supplied by the user's own Secret; without one zot serves
    # anonymous read/write, which is safe only because the chart publishes a
    # ClusterIP service and no ingress.
    if spec.htpasswd_secret:
        http["auth"] = {"htpasswd": {"path": f"{SECRET_MOUNT}/{HTPASSWD_KEY}"}}
        http["accessControl"] = {
            "repositories": {
                "**": {
                    "defaultPolicy": ["read", "create", "update", "delete"],
                    "anonymousPolicy": ["read"] if spec.public_access else [],
                }
            }
        }
    return http


def config_json(spec: Spec) -> str:
    """Zot's config.json, as the chart's `configFiles` entry."""
    cfg: dict = {
        "storage": _storage(spec),
        "http": _http(spec),
        "log": {"level": "info"},
    }
    # The CVE search extension is zot's scanning story: it downloads the
    # vulnerability database and reports per-image CVEs.
    if spec.scan_on_push:
        cfg["extensions"] = {
            "search": {"enable": True, "cve": {"updateInterval": "2h"}},
        }
    return json.dumps(cfg)


def render(spec: Spec) -> dict[str, dict]:
    """Compose the Helm Release that installs zot."""
    values: dict = {
        "fullnameOverride": spec.name,
        "service": {"type": "ClusterIP", "port": REGISTRY_PORT},
        # Images are large and a registry that loses them on restart is not a
        # registry: the chart switches to a StatefulSet with a PVC when
        # persistence is on.
        "persistence": True,
        "pvc": {"create": True, "storage": f"{spec.storage_gb}Gi"},
        "mountConfig": True,
        "configFiles": {"config.json": config_json(spec)},
    }
    if spec.htpasswd_secret:
        values["externalSecrets"] = [
            {"secretName": spec.htpasswd_secret, "mountPath": SECRET_MOUNT}
        ]
    if spec.tags:
        values["podLabels"] = dict(spec.tags)

    # external-name pins the Helm release name to the XR name, matching the
    # chart resource names `fullnameOverride` produces (and the endpoints
    # status() reports).
    return {
        "managed": {
            "apiVersion": API_VERSION,
            "kind": "Release",
            "metadata": {"annotations": {"crossplane.io/external-name": spec.name}},
            "spec": {
                **management(spec),
                # The helm provider runs with in-cluster identity, so one
                # cluster-wide config serves XRs in every namespace.
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
                    "values": values,
                    "wait": True,
                    "waitTimeout": "10m",
                },
            },
        }
    }


def status(spec: Spec, observed: dict[str, dict]) -> dict:
    """The XR status block.

    In-cluster endpoints are deterministic from the release name, so they are
    reported as soon as the chart is deployed rather than read back from a
    cloud.
    """
    at = at_provider(observed, "managed")
    host = f"{service_host(spec)}:{REGISTRY_PORT}"

    out: dict = {
        "provider": NAME,
        "ready": str(at.get("state") or "") == "deployed",
        "registryName": spec.name,
        "region": spec.region,
        "endpoints": {"oci": f"{host}/{spec.name}"},
        "cloud-url": f"kubernetes://{spec.namespace}/statefulset/{spec.name}",
    }
    if spec.htpasswd_secret:
        out["authSecret"] = spec.htpasswd_secret
    if at.get("revision"):
        out["id"] = f"{spec.namespace}/{spec.name}@{at['revision']}"
    return out
