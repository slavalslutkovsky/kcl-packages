"""xup: scaffold, validate, build and push multi-cloud Crossplane packages."""

from __future__ import annotations

from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

from xup import providers as providers_mod
from xup import scaffold
from xup import validate as validate_mod
from xup.clouds import CLOUDS, resolve
from xup.packaging import PackagingError, build_xpkg, push_xpkg

app = typer.Typer(
    name="xup",
    help="Pythonic multi-cloud scaffolding/validation for Crossplane packages.",
    no_args_is_help=True,
)
console = Console()
err_console = Console(stderr=True)

_CLOUD_LIST = ", ".join(CLOUDS)


@app.command()
def init(
    name: str = typer.Argument(
        ..., help="Package name (crossplane.yaml metadata.name)."
    ),
    kind: str = typer.Option("Bucket", "--kind", help="Claim Kind to scaffold."),
    group: str = typer.Option(
        ..., "--group", help="XRD API group, e.g. storage.example.org."
    ),
    clouds: str = typer.Option(
        "aws,gcp,azure", "--clouds", help=f"Comma-separated clouds: {_CLOUD_LIST}."
    ),
    directory: Path = typer.Option(
        Path("."), "--dir", help="Directory to scaffold the package into."
    ),
) -> None:
    """Scaffold a Configuration package: one XRD, one Composition per cloud."""
    try:
        cloud_profiles = resolve(clouds)
    except ValueError as e:
        err_console.print(f"[red]error:[/red] {e}")
        raise typer.Exit(1) from e

    result = scaffold.init_package(directory / name, name, kind, group, cloud_profiles)
    console.print(f"[green]scaffolded[/green] {result.root}/")
    for path in result.files:
        console.print(f"  {path.relative_to(result.root)}")


@app.command()
def validate(
    directory: Path = typer.Argument(..., help="Package directory to validate."),
) -> None:
    """Validate a package's crossplane.yaml, XRDs and Compositions."""
    issues = validate_mod.validate_package(directory)
    if not issues:
        console.print(f"[green]ok[/green] {directory} has no issues")
        return

    for issue in issues:
        color = "red" if issue.severity == "error" else "yellow"
        if issue.path.is_relative_to(directory):
            rel = issue.path.relative_to(directory)
        else:
            rel = issue.path
        console.print(f"[{color}]{issue.severity}[/{color}] {rel}: {issue.message}")

    if any(i.severity == "error" for i in issues):
        raise typer.Exit(1)


@app.command()
def build(
    directory: Path = typer.Argument(..., help="Package directory to build."),
    output: Path | None = typer.Option(
        None, "-o", "--output", help="Output .xpkg path."
    ),
) -> None:
    """Build a package into a `.xpkg` (delegates OCI packaging to crossplane/up)."""
    try:
        built = build_xpkg(directory, output)
    except PackagingError as e:
        err_console.print(f"[red]error:[/red] {e}")
        raise typer.Exit(1) from e
    console.print(f"[green]built[/green] {built}")


@app.command()
def push(
    xpkg: Path = typer.Argument(..., help="Path to a built .xpkg file."),
    tag: str = typer.Argument(
        ..., help="Registry tag, e.g. xpkg.upbound.io/org/pkg:v0.1.0."
    ),
) -> None:
    """Push a built `.xpkg` to an OCI registry (delegates to crossplane/up)."""
    try:
        push_xpkg(xpkg, tag)
    except PackagingError as e:
        err_console.print(f"[red]error:[/red] {e}")
        raise typer.Exit(1) from e
    console.print(f"[green]pushed[/green] {xpkg} -> {tag}")


@app.command(name="providers")
def list_providers(
    cloud: str | None = typer.Option(None, "--cloud", help=f"Filter: {_CLOUD_LIST}."),
    registry: Path | None = typer.Option(
        None,
        "--registry",
        help="Read providers from a kcl-packages registry.yaml, not xup's catalog.",
    ),
) -> None:
    """List known Crossplane provider packages, optionally filtered by cloud."""
    entries = providers_mod.list_providers(cloud=cloud, registry=registry)

    table = Table(title=str(registry) if registry else "xup built-in catalog")
    table.add_column("name")
    table.add_column("cloud")
    table.add_column("image")
    table.add_column("tag")
    table.add_column("modules")
    for e in entries:
        table.add_row(e.name, e.cloud, e.image, e.tag, ", ".join(e.modules))
    console.print(table)


def run() -> None:
    """Console-script entry point (`xup` on PATH)."""
    app()


if __name__ == "__main__":
    run()
