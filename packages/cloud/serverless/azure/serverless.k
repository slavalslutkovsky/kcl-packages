# serverless (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-containerapp schema package. The portable
# ServerlessApp maps onto a Container App plus its own Container App
# Environment (a Container App cannot exist outside an Environment and this
# XR does not assume a shared one), bound together by controller reference.
import azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment as env
import azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_container_app as app

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Container Apps (Consumption plan) only accepts fixed cpu/memory PAIRS — a
# free combination like 0.5 vCPU / 3 GiB is rejected outright. Ascending
# ladder; the memory string is Azure's exact expected literal (never "1.0Gi").
_size_ladder = [
    {cpu = 0.25, gi = 0.5, memory = "0.5Gi"}
    {cpu = 0.5, gi = 1, memory = "1Gi"}
    {cpu = 0.75, gi = 1.5, memory = "1.5Gi"}
    {cpu = 1, gi = 2, memory = "2Gi"}
    {cpu = 1.25, gi = 2.5, memory = "2.5Gi"}
    {cpu = 1.5, gi = 3, memory = "3Gi"}
    {cpu = 1.75, gi = 3.5, memory = "3.5Gi"}
    {cpu = 2, gi = 4, memory = "4Gi"}
]

# Smallest ladder pair satisfying BOTH the requested cpu and memory, so the
# request is only ever rounded up, never starved.
size_for = lambda cpu: float, memory_mb: float -> any {
    _gi = memory_mb / 1024
    _fits = [_s for _s in _size_ladder if _s.cpu >= cpu and _s.gi >= _gi]
    _fits[0] if _fits else _size_ladder[-1]
}

render = lambda oxr {
    _spec = oxr.spec
    _name = oxr.metadata.name

    # A Container App cannot exist outside a resource group and this XR does
    # not manage one; fail loud instead of rendering resources Azure rejects.
    assert _spec?.resourceGroup, "the azure backend requires spec.resourceGroup"

    _rg = _spec.resourceGroup
    _envs = _spec?.env or {}
    _size = size_for(_spec?.cpu or 1, _spec?.memoryMb or 512)

    _public = _spec?.public
    if _public == Undefined:
        _public = True

    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    # timeoutSeconds is ignored: Container Apps has no request-timeout knob
    # (its ingress timeout is platform-fixed). serviceAccount is ignored too:
    # runtime identity is a Container Apps managed identity, beyond this XR.
    _items: [any] = [env.Environment {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "environment"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _rg
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    _items += [app.ContainerApp {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "managed"}
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.resourceGroupName = _rg
        spec.forProvider.containerAppEnvironmentIdSelector.matchControllerRef = True
        # Single keeps exactly one revision serving; the portable claim has no
        # blue/green concept for Multiple's traffic splitting to map onto.
        spec.forProvider.revisionMode = "Single"
        spec.forProvider.template = {
            container = [{
                name = _name
                image = _spec.image
                cpu = _size.cpu
                memory = _size.memory
                # Sorted so the render is deterministic.
                if _envs:
                    env = [{name = _k, value = _envs[_k]} for _k in sorted(_envs)]
            }]
            minReplicas = _spec?.minInstances or 0
            # Unset means Azure's own default cap; 0 would be rejected anyway.
            if _spec?.maxInstances:
                maxReplicas = _spec.maxInstances
        }
        # public=false keeps the ingress rather than dropping it: the app
        # still serves on its FQDN, reachable only inside the Environment.
        spec.forProvider.ingress = {
            externalEnabled = _public
            targetPort = _spec?.port or 8080
            trafficWeight = [{latestRevision = True, percentage = 100}]
        }
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
    }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _name = oxr.metadata.name
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined

    # Single-revision mode serves on the latest revision's FQDN; the ingress
    # FQDN is the stable alias upjet also surfaces, so it is the fallback.
    _host = (_at?.latestRevisionFqdn) or (_at?.ingress?.fqdn) or ""

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "ServerlessApp"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = _host != ""
            if _host != "":
                host = _host
                url = "https://${_host}"
            if _at?.id:
                id = _at.id
                # The ARM id starts with a /, so the concatenation is clean.
                "cloud-url" = "https://portal.azure.com/#resource${_at.id}"
        }
    }
}
