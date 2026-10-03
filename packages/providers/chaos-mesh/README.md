# chaos-mesh

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed chaos-mesh`.

Source: chaos-mesh/chaos-mesh@v2.8.4 (config/crd/bases); service=chaos-mesh; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
chaos-mesh = { path = "<relative path>/packages/providers/chaos-mesh" }
```

Then import a model:

```python
import chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_a_w_s_chaos as model
```

## Kinds

### v1alpha1

| kind | import |
| --- | --- |
| AWSChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_a_w_s_chaos` |
| AzureChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_azure_chaos` |
| BlockChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_block_chaos` |
| DNSChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_dns_chaos` |
| GCPChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_g_c_p_chaos` |
| HTTPChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_http_chaos` |
| IOChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_i_o_chaos` |
| JVMChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_j_vm_chaos` |
| KernelChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_kernel_chaos` |
| NetworkChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_network_chaos` |
| PhysicalMachine | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_physical_machine` |
| PhysicalMachineChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_physical_machine_chaos` |
| PodChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_chaos` |
| PodHttpChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_http_chaos` |
| PodIOChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_i_o_chaos` |
| PodNetworkChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_pod_network_chaos` |
| RemoteCluster | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_remote_cluster` |
| Schedule | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_schedule` |
| StatusCheck | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_status_check` |
| StressChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_stress_chaos` |
| TimeChaos | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_time_chaos` |
| Workflow | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_workflow` |
| WorkflowNode | `chaos_mesh.models.v1alpha1.chaos_mesh_org_v1alpha1_workflow_node` |
