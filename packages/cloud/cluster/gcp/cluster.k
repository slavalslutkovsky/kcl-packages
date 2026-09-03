# cluster (gcp) — Crossplane Composition logic (function-kcl module).
# Typed against the gcp-container schema package. The portable
# KubernetesCluster maps onto a GKE Cluster (default node pool removed) plus a
# managed NodePool. GKE's own deletionProtection is disabled — lifecycle is
# governed by the XR's deletionPolicy (Crossplane managementPolicies) instead
# of a second, provider-level lock. The kubeconfig is published as a
# namespace-local connection secret by the Cluster MR itself.
import gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_cluster as gkecluster
import gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_node_pool as nodepool

# Crossplane management policy set for the Orphan deletion policy (everything but Delete).
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# Abstract node shape -> GCE machine type.
_machine = {"small" = "e2-medium", "medium" = "e2-standard-2", "large" = "e2-standard-4", "xlarge" = "e2-standard-8"}

machine_for = lambda spec: any -> str {
    spec?.machineType or _machine[spec?.nodeSize or "small"]
}

render = lambda oxr, ocds {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _region = _spec.region
    _mp = _orphan_policies if (_spec?.deletionPolicy or "Delete") == "Orphan" else Undefined

    assert not _spec?.kubeconfigSecret and not _spec?.bootstrap, "cluster-gcp: spec.kubeconfigSecret and spec.bootstrap are onprem-only — a provisioned cluster publishes its own kubeconfig (status.kubeconfigSecret) and is handed over bare"

    _count = _spec?.nodeCount or 2
    _as = _spec?.autoscaling
    _subnets = _spec?.network?.subnets or []

    # The control plane. GKE requires a node pool at creation; it is removed
    # in favour of the managed NodePool below.
    _items: [any] = [gkecluster.Cluster {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "managed"
            "crossplane.io/external-name" = _name
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _region
        spec.forProvider.removeDefaultNodePool = True
        spec.forProvider.initialNodeCount = 1
        spec.forProvider.deletionProtection = False
        if _spec?.version:
            spec.forProvider.minMasterVersion = _spec.version
        if _spec?.network?.id:
            spec.forProvider.network = _spec.network.id
        if len(_subnets) > 0:
            spec.forProvider.subnetwork = _subnets[0]
        if _spec?.tags:
            spec.forProvider.resourceLabels = _spec.tags
        spec.writeConnectionSecretToRef.name = "${_name}-kubeconfig"
    }]

    # The workers. nodeCount conflicts with autoscaling upstream, so the pool
    # sets exactly one of them (initialNodeCount seeds the autoscaled pool).
    _items += [nodepool.NodePool {
        metadata.annotations = {
            "krm.kcl.dev/composition-resource-name" = "nodes"
            "crossplane.io/external-name" = "${_name}-nodes"
        }
        if _mp:
            spec.managementPolicies = _mp
        spec.forProvider.location = _region
        spec.forProvider.clusterSelector.matchControllerRef = True
        if _as:
            spec.forProvider.initialNodeCount = _count
            spec.forProvider.autoscaling = {minNodeCount = _as.min, maxNodeCount = _as.max}
        else:
            spec.forProvider.nodeCount = _count
        spec.forProvider.nodeConfig = {
            machineType = machine_for(_spec)
            if _spec?.spot:
                spot = True
            if _spec?.tags:
                labels = _spec.tags
        }
    }]

    _items
}

# Build the desired composite carrying observed status back to the XR.
status = lambda oxr, ocds {
    _at = (ocds["managed"]?.Resource?.status?.atProvider) if ("managed" in ocds) else Undefined
    _name = oxr.metadata.name
    # atProvider.id is projects/<project>/locations/<location>/clusters/<name>.
    _id_parts = (_at.id.split("/")) if _at and _at?.id else []
    _project = _id_parts[1] if len(_id_parts) > 1 else ""
    _location = (_at?.location) or oxr.spec.region
    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "KubernetesCluster"
        metadata.name = _name
        status = {
            provider = "gcp"
            ready = (_at?.endpoint or "") != ""
            name = _name
            kubeconfigSecret = "${_name}-kubeconfig"
            if _at:
                if _at?.endpoint:
                    endpoint = _at.endpoint
                if _at?.masterVersion:
                    version = _at.masterVersion
                if _at?.id:
                    id = _at.id
                    "cloud-url" = "https://console.cloud.google.com/kubernetes/clusters/details/${_location}/${_name}?project=${_project}"
        }
    }
}
