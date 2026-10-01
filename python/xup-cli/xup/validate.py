"""Structural validation of a Crossplane package directory.

This checks the shape `crossplane xpkg build` and the API server itself would
reject if wrong: a parseable crossplane.yaml, XRDs with the fields the
apiextensions API requires, and Compositions whose `compositeTypeRef` actually
resolves to an XRD in the same package. It does not validate a managed
resource's `forProvider` schema against the owning provider's CRD — that
requires the provider's CRDs on hand, which a package directory alone doesn't
have.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import yaml

Severity = Literal["error", "warning"]

# (apiVersion, kind) -> the file its XRD is defined in.
XrdIndex = dict[tuple[str, str], Path]


@dataclass(frozen=True)
class Issue:
    """One validation finding, anchored to the file it came from."""

    path: Path
    severity: Severity
    message: str

    def __str__(self) -> str:
        """Render as `[severity] path: message`, for plain-text output."""
        return f"[{self.severity}] {self.path}: {self.message}"


def _load_all(path: Path) -> list[dict[str, Any]]:
    with path.open() as f:
        return [doc for doc in yaml.safe_load_all(f) if doc]


def validate_package(root: Path) -> list[Issue]:
    """Validate `root` as a Crossplane package. Returns every issue found."""
    meta_path = root / "crossplane.yaml"
    meta, issues = _validate_meta(meta_path)
    if meta is None:
        return issues

    manifest_paths = sorted(p for p in root.rglob("*.yaml") if p != meta_path)
    _, scan_issues = _scan_manifests(manifest_paths)
    issues.extend(scan_issues)
    return issues


def _validate_meta(meta_path: Path) -> tuple[dict[str, Any] | None, list[Issue]]:
    if not meta_path.exists():
        msg = "package is missing crossplane.yaml"
        return None, [Issue(meta_path, "error", msg)]

    try:
        docs = _load_all(meta_path)
    except yaml.YAMLError as e:
        msg = f"crossplane.yaml is not valid YAML: {e}"
        return None, [Issue(meta_path, "error", msg)]

    if len(docs) != 1:
        msg = "crossplane.yaml must contain exactly one document"
        return None, [Issue(meta_path, "error", msg)]

    meta = docs[0]
    issues: list[Issue] = []
    api_version = str(meta.get("apiVersion", ""))
    if not api_version.startswith("meta.pkg.crossplane.io/"):
        msg = f"apiVersion {api_version!r} is not a meta.pkg.crossplane.io/* kind"
        issues.append(Issue(meta_path, "error", msg))
    if meta.get("kind") not in {"Configuration", "Provider", "Function"}:
        msg = f"unexpected kind {meta.get('kind')!r} in crossplane.yaml"
        issues.append(Issue(meta_path, "error", msg))
    return meta, issues


def _scan_manifests(paths: list[Path]) -> tuple[XrdIndex, list[Issue]]:
    xrds: XrdIndex = {}
    issues: list[Issue] = []
    docs_by_path: dict[Path, list[dict[str, Any]]] = {}

    for path in paths:
        try:
            docs_by_path[path] = _load_all(path)
        except yaml.YAMLError as e:
            issues.append(Issue(path, "error", f"not valid YAML: {e}"))

    for path, docs in docs_by_path.items():
        for doc in docs:
            kind = doc.get("kind")
            if kind == "CompositeResourceDefinition":
                issues.extend(_validate_xrd(path, doc, xrds))
            elif kind == "Composition":
                issues.extend(_validate_composition(path, doc))

    for path, docs in docs_by_path.items():
        for doc in docs:
            if doc.get("kind") == "Composition":
                issues.extend(_validate_composition_ref(path, doc, xrds))

    return xrds, issues


def _validate_xrd(path: Path, doc: dict[str, Any], xrds: XrdIndex) -> list[Issue]:
    issues: list[Issue] = []
    spec = doc.get("spec", {})
    group = spec.get("group")
    names = spec.get("names", {})
    claim_names = spec.get("claimNames", {})
    versions = spec.get("versions", [])

    if not group:
        issues.append(Issue(path, "error", "XRD spec.group is required"))
    if not names.get("kind"):
        issues.append(Issue(path, "error", "XRD spec.names.kind is required"))
    if not claim_names.get("kind"):
        msg = "XRD has no spec.claimNames.kind (no claim API)"
        issues.append(Issue(path, "warning", msg))
    if not versions:
        issues.append(Issue(path, "error", "XRD spec.versions must be non-empty"))

    for v in versions:
        if not v.get("schema", {}).get("openAPIV3Schema"):
            version_name = v.get("name")
            msg = f"XRD version {version_name!r} is missing an openAPIV3Schema"
            issues.append(Issue(path, "error", msg))
        if group and names.get("kind"):
            xrds[(f"{group}/{v.get('name')}", names["kind"])] = path

    return issues


def _validate_composition(path: Path, doc: dict[str, Any]) -> list[Issue]:
    issues: list[Issue] = []
    spec = doc.get("spec", {})
    ref = spec.get("compositeTypeRef", {})
    if not ref.get("apiVersion") or not ref.get("kind"):
        msg = "Composition spec.compositeTypeRef needs apiVersion and kind"
        issues.append(Issue(path, "error", msg))
    if spec.get("mode") == "Pipeline":
        for step in spec.get("pipeline", []):
            if not step.get("functionRef", {}).get("name"):
                step_name = step.get("step")
                msg = f"pipeline step {step_name!r} is missing functionRef.name"
                issues.append(Issue(path, "error", msg))
    return issues


def _validate_composition_ref(
    path: Path, doc: dict[str, Any], xrds: XrdIndex
) -> list[Issue]:
    ref = doc.get("spec", {}).get("compositeTypeRef", {})
    api_version, kind = ref.get("apiVersion"), ref.get("kind")
    if api_version and kind and (api_version, kind) not in xrds:
        msg = f"compositeTypeRef {api_version}/{kind} matches no XRD in this package"
        return [Issue(path, "error", msg)]
    return []
