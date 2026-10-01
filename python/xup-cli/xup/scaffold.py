"""Writes a scaffolded Crossplane package to disk."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from xup import templates
from xup.clouds import CloudProfile


@dataclass(frozen=True)
class ScaffoldResult:
    """Paths written by `init_package`, in write order."""

    root: Path
    files: list[Path]


def init_package(
    root: Path,
    name: str,
    kind: str,
    group: str,
    clouds: list[CloudProfile],
) -> ScaffoldResult:
    """Write crossplane.yaml, one XRD, and one Composition + example per cloud.

    Layout mirrors the shape `crossplane xpkg build` expects: a package root
    with crossplane.yaml at the top and every other manifest anywhere below it.

        <root>/crossplane.yaml
        <root>/apis/<kind>/definition.yaml
        <root>/apis/<kind>/composition-<cloud>.yaml   (one per cloud)
        <root>/examples/<kind>/<cloud>.yaml            (one per cloud)
    """
    root.mkdir(parents=True, exist_ok=True)
    kind_lower = kind.lower()
    written: list[Path] = []

    def write(path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        written.append(path)

    write(root / "crossplane.yaml", templates.crossplane_yaml(name, clouds))
    write(
        root / "apis" / kind_lower / "definition.yaml",
        templates.xrd_yaml(kind, group),
    )

    for cloud in clouds:
        write(
            root / "apis" / kind_lower / f"composition-{cloud.key}.yaml",
            templates.composition_yaml(kind, group, cloud),
        )
        write(
            root / "examples" / kind_lower / f"{cloud.key}.yaml",
            templates.example_yaml(kind, group, cloud),
        )

    return ScaffoldResult(root=root, files=written)
