# azure-containerservice

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-containerservice`.

Source: ghcr.io/crossplane-contrib/provider-azure-containerservice:v2.6.0 (scope=namespaced; service=containerservice)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-containerservice = { path = "<relative path>/packages/providers/azure-containerservice" }
```

Then import a model:

```python
import azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| KubernetesCluster | `azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster` |
| KubernetesClusterExtension | `azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster_extension` |
| KubernetesClusterNodePool | `azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_cluster_node_pool` |
| KubernetesFleetManager | `azure_containerservice.models.v1beta1.containerservice_azurem_upbound_io_v1beta1_kubernetes_fleet_manager` |
