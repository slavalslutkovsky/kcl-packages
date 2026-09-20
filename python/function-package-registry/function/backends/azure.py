"""Azure backend: one Container Registry, OCI only.

Ported verbatim from packages/cloud/registry/azure/registry.k. ACR is a single
resource: the registry carries its own retention, replication, anonymous-pull
and encryption settings, so this backend composes exactly one MR. A registry
name must be 5-50 alphanumeric characters, which the XR name has to satisfy.
"""

from function.spec import Spec, SpecError, at_provider, management

NAME = "azure"

API_VERSION = "containerregistry.azure.m.upbound.io/v1beta1"

SUPPORTED = frozenset({"oci"})

UNSUPPORTED_HINT = (
    "Azure Container Registry is OCI-only and Azure has no ARM-managed "
    "language package registry (Azure Artifacts is Azure DevOps); use gcp, "
    "aws or forgejo for language formats."
)


def sku_for(spec: Spec) -> str:
    """Standard, or Premium when a requested feature is gated behind it.

    ACR gates untagged-image retention, geo-replication and zone redundancy
    behind Premium. Asking for any of them upgrades the sku rather than
    rendering a registry Azure would reject.
    """
    premium = (
        spec.tier == "premium"
        or bool(spec.replication_regions)
        or spec.untagged_retention_days is not None
    )
    return "Premium" if premium else "Standard"


def render(spec: Spec) -> dict[str, dict]:
    """Compose the Container Registry.

    Raises:
        SpecError: no resource group was given.
    """
    # A Container Registry cannot exist outside a resource group and this XR
    # does not manage one; fail loud instead of rendering something Azure
    # rejects with a reference-resolution error.
    if not spec.resource_group:
        msg = (
            "package-registry-azure: spec.resourceGroup is required "
            "(the Resource Group the registry lives in)"
        )
        raise SpecError(msg)

    sku = sku_for(spec)
    # ACR rejects the registry's own location in georeplications.
    replicas = [r for r in spec.replication_regions if r != spec.region]

    for_provider: dict = {
        "location": spec.region,
        "resourceGroupName": spec.resource_group,
        "sku": sku,
        # Admin user is a shared static credential pair; Entra ID tokens
        # (az acr login) are the supported path, so it stays off.
        "adminEnabled": False,
        "anonymousPullEnabled": spec.public_access,
        "publicNetworkAccessEnabled": True,
        "zoneRedundancyEnabled": sku == "Premium",
    }
    if spec.untagged_retention_days is not None:
        for_provider["retentionPolicyInDays"] = spec.untagged_retention_days
    if replicas:
        for_provider["georeplications"] = [
            {
                "location": r,
                "regionalEndpointEnabled": True,
                "zoneRedundancyEnabled": False,
            }
            for r in replicas
        ]
    # Customer-managed keys need a user-assigned identity: ACR reads the Key
    # Vault key as that identity, and its system identity cannot be granted
    # access before the registry exists. Both or neither.
    if spec.encryption_key_id and spec.encryption_identity_client_id:
        for_provider["identity"] = {"type": "UserAssigned"}
        for_provider["encryption"] = {
            "keyVaultKeyId": spec.encryption_key_id,
            "identityClientId": spec.encryption_identity_client_id,
        }
    if spec.tags:
        for_provider["tags"] = dict(spec.tags)

    # external-name pins the ACR name to the XR name: it is the login server
    # host (<name>.azurecr.io), so it cannot be the random name Crossplane
    # generates for the composed resource.
    return {
        "managed": {
            "apiVersion": API_VERSION,
            "kind": "Registry",
            "metadata": {"annotations": {"crossplane.io/external-name": spec.name}},
            "spec": {**management(spec), "forProvider": for_provider},
        }
    }


def status(spec: Spec, observed: dict[str, dict]) -> dict:
    """The XR status block, from whatever the provider has reported so far."""
    at = at_provider(observed, "managed")
    login = str(at.get("loginServer") or "")
    resource_id = str(at.get("id") or "")

    out: dict = {
        "provider": NAME,
        "ready": bool(login),
        "registryName": spec.name,
        "region": str(at.get("location") or spec.region),
        "cloud-url": f"https://portal.azure.com/#@/resource{resource_id}"
        if resource_id
        else "https://portal.azure.com/#browse/Microsoft.ContainerRegistry%2Fregistries",
    }
    if login:
        # ACR is the host; the repository namespace under it is created on
        # first push. Report the path the XR owns by convention.
        out["endpoints"] = {"oci": f"{login}/{spec.name}"}
    if resource_id:
        out["id"] = resource_id
    return out
