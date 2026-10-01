"""Per-cloud defaults for scaffolding Crossplane compositions.

Each `CloudProfile` captures the handful of things that differ between an
otherwise-identical composition on aws/gcp/azure: which Upbound official
provider package supplies the managed resource, what its API group and kind
are, and what the region-like field is called. Adding a fourth cloud means
adding one entry here, not touching the templates.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CloudProfile:
    """Everything a template needs to render one cloud's managed resource."""

    key: str
    display_name: str
    provider_package: str
    provider_version: str
    api_group: str
    resource_kind: str
    region_field: str
    default_region: str
    provider_config_kind: str = "ProviderConfig"

    def resource_api_version(self) -> str:
        """`apiVersion` of this cloud's managed resource, e.g. s3.aws.upbound.io."""
        return f"{self.api_group}/v1beta1"


# Official Upbound family providers (github.com/upbound/provider-{aws,gcp,azure}).
# Group/kind pairs below are the real Bucket-shaped resource each provider ships;
# `xup init` uses these as the default "storage bucket" example, matching this
# repo's own bucket-aws / bucket-gcp / bucket-azure split.
CLOUDS: dict[str, CloudProfile] = {
    "aws": CloudProfile(
        key="aws",
        display_name="AWS",
        provider_package="xpkg.upbound.io/upbound/provider-aws-s3",
        provider_version=">=v1.0.0",
        api_group="s3.aws.upbound.io",
        resource_kind="Bucket",
        region_field="region",
        default_region="us-east-1",
    ),
    "gcp": CloudProfile(
        key="gcp",
        display_name="GCP",
        provider_package="xpkg.upbound.io/upbound/provider-gcp-storage",
        provider_version=">=v1.0.0",
        api_group="storage.gcp.upbound.io",
        resource_kind="Bucket",
        region_field="location",
        default_region="us-central1",
    ),
    "azure": CloudProfile(
        key="azure",
        display_name="Azure",
        provider_package="xpkg.upbound.io/upbound/provider-azure-storage",
        provider_version=">=v1.0.0",
        api_group="storage.azure.upbound.io",
        resource_kind="Account",
        region_field="location",
        default_region="eastus",
    ),
}


def resolve(clouds: str) -> list[CloudProfile]:
    """Parse a `--clouds aws,gcp,azure` option into known `CloudProfile`s.

    Raises:
        ValueError: one of the names isn't a registered cloud.
    """
    keys = [c.strip().lower() for c in clouds.split(",") if c.strip()]
    unknown = [k for k in keys if k not in CLOUDS]
    if unknown:
        known = ", ".join(sorted(CLOUDS))
        msg = f"unknown cloud(s) {unknown}; known clouds: {known}"
        raise ValueError(msg)
    return [CLOUDS[k] for k in keys]
