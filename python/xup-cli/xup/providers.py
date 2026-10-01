"""A small catalog of Crossplane providers, plus a reader for `registry.yaml`.

The built-in catalog is a handful of well-known official Upbound providers —
enough to scaffold against without a network call. The registry reader is the
interoperability point with kcl-packages: `packages/providers/registry.yaml`
in that repo is the same shape (name/cloud/image/tag/modules), so `xup
providers --registry <path>` lists that repo's actual provider set instead of
xup's built-in one.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import yaml


@dataclass(frozen=True)
class ProviderEntry:
    """One row: a provider package plus what it's for."""

    name: str
    cloud: str
    image: str
    tag: str
    modules: tuple[str, ...] = ()


def _upbound(name: str, cloud: str, modules: tuple[str, ...]) -> ProviderEntry:
    image = f"xpkg.upbound.io/upbound/{name}"
    return ProviderEntry(name, cloud, image, "v1.0.0", modules)


BUILTIN: list[ProviderEntry] = [
    _upbound("provider-aws-s3", "aws", ("storage",)),
    _upbound("provider-aws-eks", "aws", ("cluster",)),
    _upbound("provider-aws-rds", "aws", ("database",)),
    _upbound("provider-aws-iam", "aws", ("iam",)),
    _upbound("provider-gcp-storage", "gcp", ("storage",)),
    _upbound("provider-gcp-container", "gcp", ("cluster",)),
    _upbound("provider-gcp-sql", "gcp", ("database",)),
    _upbound("provider-azure-storage", "azure", ("storage",)),
    _upbound("provider-azure-containerservice", "azure", ("cluster",)),
    _upbound("provider-azure-dbforpostgresql", "azure", ("database",)),
]


def from_registry(path: Path) -> list[ProviderEntry]:
    """Load provider rows from a kcl-packages-shaped `registry.yaml`.

    Rows with no `image` (operator/catalog-sourced CRDs, e.g. cert-manager)
    are skipped: they name no package for xup's provider commands to act on.
    """
    doc = yaml.safe_load(path.read_text())
    entries = []
    for row in doc.get("providers", []):
        image = row.get("image")
        if not image:
            continue
        entries.append(
            ProviderEntry(
                name=row["name"],
                cloud=row.get("cloud", "unknown"),
                image=image,
                tag=row.get("tag", ""),
                modules=tuple(row.get("modules", [])),
            )
        )
    return entries


def list_providers(
    cloud: str | None = None, registry: Path | None = None
) -> list[ProviderEntry]:
    """Providers from `registry` if given, else xup's built-in catalog."""
    entries = from_registry(registry) if registry else BUILTIN
    if cloud:
        entries = [e for e in entries if e.cloud == cloud]
    return entries
