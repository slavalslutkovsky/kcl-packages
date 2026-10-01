"""YAML templates for scaffolded Crossplane packages.

Plain f-strings rather than a template engine: every template here is small,
fully static apart from the substitutions, and one more dependency (Jinja2)
buys nothing a docstring-adjacent function doesn't already give.
"""

from __future__ import annotations

from xup.clouds import CloudProfile


def crossplane_yaml(name: str, clouds: list[CloudProfile]) -> str:
    """Package meta file: a Configuration depending on one provider per cloud."""
    deps = "\n".join(
        f'    - provider: "{c.provider_package}"\n      version: "{c.provider_version}"'
        for c in clouds
    )
    return (
        "apiVersion: meta.pkg.crossplane.io/v1\n"
        "kind: Configuration\n"
        "metadata:\n"
        f"  name: {name}\n"
        "spec:\n"
        "  crossplane:\n"
        '    version: ">=v1.14.0"\n'
        "  dependsOn:\n"
        f"{deps}\n"
    )


def xrd_yaml(kind: str, group: str) -> str:
    """CompositeResourceDefinition: one `spec.region` field, one claim."""
    kind_lower = kind.lower()
    return (
        "apiVersion: apiextensions.crossplane.io/v1\n"
        "kind: CompositeResourceDefinition\n"
        "metadata:\n"
        f"  name: x{kind_lower}s.{group}\n"
        "spec:\n"
        f"  group: {group}\n"
        "  names:\n"
        f"    kind: X{kind}\n"
        f"    plural: x{kind_lower}s\n"
        "  claimNames:\n"
        f"    kind: {kind}\n"
        f"    plural: {kind_lower}s\n"
        "  versions:\n"
        "    - name: v1alpha1\n"
        "      served: true\n"
        "      referenceable: true\n"
        "      schema:\n"
        "        openAPIV3Schema:\n"
        "          type: object\n"
        "          properties:\n"
        "            spec:\n"
        "              type: object\n"
        "              properties:\n"
        "                region:\n"
        "                  type: string\n"
        "                  description: Cloud region/location for the resource.\n"
        "              required: [region]\n"
    )


def composition_yaml(kind: str, group: str, cloud: CloudProfile) -> str:
    """One Composition rendering `kind` onto a single cloud's managed resource."""
    kind_lower = kind.lower()
    return (
        "apiVersion: apiextensions.crossplane.io/v1\n"
        "kind: Composition\n"
        "metadata:\n"
        f"  name: {kind_lower}-{cloud.key}\n"
        "  labels:\n"
        f"    provider: {cloud.key}\n"
        "spec:\n"
        "  compositeTypeRef:\n"
        f"    apiVersion: {group}/v1alpha1\n"
        f"    kind: X{kind}\n"
        "  mode: Pipeline\n"
        "  pipeline:\n"
        "    - step: render\n"
        "      functionRef:\n"
        "        name: function-patch-and-transform\n"
        "      input:\n"
        "        apiVersion: pt.fn.crossplane.io/v1beta1\n"
        "        kind: Resources\n"
        "        resources:\n"
        f"          - name: {kind_lower}\n"
        "            base:\n"
        f"              apiVersion: {cloud.resource_api_version()}\n"
        f"              kind: {cloud.resource_kind}\n"
        "              spec:\n"
        "                forProvider:\n"
        f"                  {cloud.region_field}: {cloud.default_region}\n"
        "            patches:\n"
        "              - type: FromCompositeFieldPath\n"
        "                fromFieldPath: spec.region\n"
        f"                toFieldPath: spec.forProvider.{cloud.region_field}\n"
    )


def example_yaml(kind: str, group: str, cloud: CloudProfile) -> str:
    """A namespaced claim exercising one cloud's Composition via a label selector."""
    return (
        f"apiVersion: {group}/v1alpha1\n"
        f"kind: {kind}\n"
        "metadata:\n"
        f"  name: demo-{cloud.key}\n"
        "  namespace: default\n"
        "spec:\n"
        f"  region: {cloud.default_region}\n"
        "  compositionSelector:\n"
        "    matchLabels:\n"
        f"      provider: {cloud.key}\n"
    )
