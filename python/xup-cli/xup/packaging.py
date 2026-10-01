"""Build and push `.xpkg` OCI packages.

An xpkg is an OCI image with a specific annotated-layer layout, produced by a
Go toolchain (`crossplane xpkg build` / `up xpkg build`) that shells out to
go-containerregistry. Re-implementing that layout in Python would either be
incomplete or silently diverge from what `crossplane` actually accepts — so
xup does not build OCI images itself. Instead it validates and scaffolds the
package *source* (see `xup.validate` / `xup.scaffold`), then delegates the OCI
mechanics to whichever real tool is on PATH, preferring `crossplane` and
falling back to `up`.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


class PackagingError(RuntimeError):
    """Raised when no xpkg-capable tool is on PATH, or it exits non-zero."""


_TOOLS = ("crossplane", "up")


def _find_tool() -> str:
    for tool in _TOOLS:
        if shutil.which(tool):
            return tool
    msg = (
        f"none of {_TOOLS} found on PATH; install the Crossplane CLI "
        "(https://docs.crossplane.io/latest/cli/) or Upbound's `up` "
        "(https://docs.upbound.io/cli/) to build/push xpkgs"
    )
    raise PackagingError(msg)


def build_xpkg(package_dir: Path, output: Path | None = None) -> Path:
    """Build `package_dir` into an `.xpkg`, returning the produced file's path.

    `--examples-root` is passed explicitly, resolved against `package_dir`:
    the tool's own default (`./examples`) is relative to the *current
    directory*, not `--package-root`, so building from anywhere but
    `package_dir` itself would otherwise miss the examples xup scaffolds and
    fail trying to parse them as package objects instead.
    """
    tool = _find_tool()
    examples_root = package_dir / "examples"
    cmd = [tool, "xpkg", "build", "-f", str(package_dir)]
    if examples_root.is_dir():
        cmd += ["--examples-root", str(examples_root)]
    if output is not None:
        cmd += ["-o", str(output)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)  # noqa: S603
    if result.returncode != 0:
        msg = f"`{' '.join(cmd)}` failed:\n{result.stderr}"
        raise PackagingError(msg)
    if output is not None:
        return output
    built = sorted(package_dir.glob("*.xpkg"))
    if not built:
        msg = f"`{tool} xpkg build` reported success but produced no .xpkg"
        raise PackagingError(msg)
    return built[-1]


def push_xpkg(xpkg_path: Path, tag: str) -> None:
    """Push a built `.xpkg` to `tag` (e.g. `xpkg.upbound.io/org/pkg:v0.1.0`)."""
    tool = _find_tool()
    cmd = [tool, "xpkg", "push", tag, "-f", str(xpkg_path)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)  # noqa: S603
    if result.returncode != 0:
        msg = f"`{' '.join(cmd)}` failed:\n{result.stderr}"
        raise PackagingError(msg)
