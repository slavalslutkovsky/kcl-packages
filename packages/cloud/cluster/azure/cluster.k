# cluster (azure) — Crossplane Composition logic (function-kcl module).
# Typed against the azure-containerservice schema package. The portable
# KubernetesCluster maps onto a single AKS KubernetesCluster: the default
# (System) node pool carries the workers, the cluster runs with a
# system-assigned identity, and the kubeconfig is published as a
# namespace-local connection secret. AKS refuses Spot for its default node
# pool, so spot fails the render instead of silently running on-demand.
import azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster as aks

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract node shape -> Azure VM size.
_machine = {"small" = "Standard_B2s", "medium" = "Standard_D2s_v5", "large" = "Standard_D4s_v5", "xlarge" = "Standard_D8s_v5"}

machine_for = lambda spec: any -> str {
    spec?.machineType or _machine[spec?.nodeSize or "small"]
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    assert _spec?.region, "cluster-azure: spec.region is required (the Azure location of the cluster)"
    assert _spec?.resourceGroup, "cluster-azure: spec.resourceGroup is required (the Resource Group the cluster lives in)"
    assert not _spec?.spot, "cluster-azure: spec.spot is not expressible — AKS requires its default (System) node pool on regular capacity"

    _count = _spec?.nodeCount or 2
    _as = _spec?.autoscaling
    _subnets = _spec?.network?.subnets or []

    [aks.KubernetesCluster {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _spec.region
        spec.forProvider.resourceGroupName = _spec.resourceGroup
        spec.forProvider.dnsPrefix = _name
        if _spec?.version:
            spec.forProvider.kubernetesVersion = _spec.version
        spec.forProvider.identity = {$type = "SystemAssigned"}
        spec.forProvider.defaultNodePool = {
            name = "default"
            vmSize = machine_for(_spec)
            if _as:
                autoScalingEnabled = True
                minCount = _as.min
                maxCount = _as.max
                nodeCount = _count
            else:
                nodeCount = _count
            if len(_subnets) > 0:
                vnetSubnetId = _subnets[0]
        }
        if _spec?.tags:
            spec.forProvider.tags = _spec.tags
        spec.writeConnectionSecretToRef.name = "${_name}-kubeconfig"
    }]
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "KubernetesCluster"
        metadata.name = _name
        status = {
            provider = "azure"
            ready = (_at?.fqdn or "") != ""
            name = _name
            kubeconfigSecret = "${_name}-kubeconfig"
            if _at:
                if _at?.fqdn:
                    endpoint = _at.fqdn
                if _at?.currentKubernetesVersion:
                    version = _at.currentKubernetesVersion
                elif _at?.kubernetesVersion:
                    version = _at.kubernetesVersion
                if _at?.id:
                    id = _at.id
                    "cloud-url" = "https://portal.azure.com/#@/resource${_at.id}"
        }
    }
}
