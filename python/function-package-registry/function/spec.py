"""The PackageRegistry XR spec, parsed once and shared by every backend.

A locally rendered XR carries no XRD defaults (`crossplane render` never goes
through the API server), so every default the XRD declares is applied here too
— the same reason the KCL modules in this repo carry a `_flag` helper. An
explicit `null` is treated exactly like an absent key.
"""

import dataclasses

#: Every package format the XRD accepts. A backend serves a subset.
FORMATS = ("oci", "npm", "pypi", "maven", "go", "cargo", "nuget", "generic")

#: Crossplane management policy set for the Orphan deletion policy
#: (everything but Delete).
ORPHAN_POLICIES = ["Observe", "Create", "Update", "LateInitialize"]


class SpecError(ValueError):
    """A spec this function refuses to render.

    The message is reported verbatim as the function's fatal result, so it is
    written for the person who wrote the XR.
    """


def _text(spec: dict, key: str) -> str | None:
    value = spec.get(key)
    return str(value) if value else None


def _count(spec: dict, key: str) -> int | None:
    # Neither a day count nor an image count can be 0, so falsy means "not
    # asked for" — the same normalisation the KCL renderers do with `or
    # Undefined`.
    value = spec.get(key)
    return int(value) if value else None


def _flag(spec: dict, key: str, *, fallback: bool) -> bool:
    # Presence, not truthiness: `or` would swallow an explicit false.
    value = spec.get(key)
    return fallback if value is None else bool(value)


def _formats(value: object) -> tuple[str, ...]:
    if not value:
        return ("oci",)
    if not isinstance(value, list):
        msg = "spec.formats must be a list of package formats"
        raise SpecError(msg)
    out: list[str] = []
    for item in value:
        if item not in FORMATS:
            allowed = ", ".join(FORMATS)
            msg = f"spec.formats: unknown format {item!r}; allowed: {allowed}"
            raise SpecError(msg)
        if item not in out:
            out.append(item)
    return tuple(out)


def _strings(value: object) -> tuple[str, ...]:
    return tuple(str(v) for v in value) if isinstance(value, list) else ()


def _tags(value: object) -> dict[str, str]:
    return {str(k): str(v) for k, v in value.items()} if isinstance(value, dict) else {}


@dataclasses.dataclass(frozen=True)
class Spec:
    """One PackageRegistry XR, normalised."""

    name: str
    namespace: str
    region: str
    formats: tuple[str, ...]
    tier: str
    immutable_tags: bool
    scan_on_push: bool
    public_access: bool
    untagged_retention_days: int | None
    keep_last_images: int | None
    encryption_key_id: str | None
    encryption_identity_client_id: str | None
    replication_regions: tuple[str, ...]
    storage_gb: int
    htpasswd_secret: str | None
    owner: str | None
    admin_secret: str | None
    resource_group: str | None
    force_destroy: bool
    orphan: bool
    tags: dict[str, str]

    @classmethod
    def from_xr(cls, xr: dict) -> "Spec":
        """Parse an observed composite resource.

        Args:
            xr: the observed composite, as a plain dict.

        Returns:
            The normalised spec.

        Raises:
            SpecError: the XR is missing something no backend can render.
        """
        meta = xr.get("metadata") or {}
        spec = xr.get("spec") or {}
        region = _text(spec, "region")
        if not region:
            msg = "spec.region is required"
            raise SpecError(msg)
        return cls(
            name=str(meta.get("name") or ""),
            namespace=str(meta.get("namespace") or "default"),
            region=region,
            formats=_formats(spec.get("formats")),
            tier=_text(spec, "tier") or "standard",
            immutable_tags=_flag(spec, "immutableTags", fallback=False),
            scan_on_push=_flag(spec, "scanOnPush", fallback=True),
            public_access=_flag(spec, "publicAccess", fallback=False),
            untagged_retention_days=_count(spec, "untaggedRetentionDays"),
            keep_last_images=_count(spec, "keepLastImages"),
            encryption_key_id=_text(spec, "encryptionKeyId"),
            encryption_identity_client_id=_text(spec, "encryptionIdentityClientId"),
            replication_regions=_strings(spec.get("replicationRegions")),
            storage_gb=_count(spec, "storageGb") or 8,
            htpasswd_secret=_text(spec, "htpasswdSecret"),
            owner=_text(spec, "owner"),
            admin_secret=_text(spec, "adminSecret"),
            resource_group=_text(spec, "resourceGroup"),
            force_destroy=_flag(spec, "forceDestroy", fallback=False),
            orphan=(_text(spec, "deletionPolicy") or "Delete") == "Orphan",
            tags=_tags(spec.get("tags")),
        )


def management(spec: Spec) -> dict:
    """The `spec.managementPolicies` fragment a composed resource needs, if any."""
    return {"managementPolicies": list(ORPHAN_POLICIES)} if spec.orphan else {}


def at_provider(observed: dict, name: str) -> dict:
    """`status.atProvider` of one observed composed resource, or `{}`.

    Every read of observed state is optional: on the first reconcile there is
    none, and that means "not ready", never an error.
    """
    return ((observed.get(name) or {}).get("status") or {}).get("atProvider") or {}
