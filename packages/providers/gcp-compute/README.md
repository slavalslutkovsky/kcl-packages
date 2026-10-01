# gcp-compute

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-compute`.

Source: ghcr.io/crossplane-contrib/provider-gcp-compute:v2.6.0 (scope=namespaced; service=compute)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-compute = { path = "<relative path>/packages/providers/gcp-compute" }
```

Then import a model:

```python
import gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_address as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Address | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_address` |
| AttachedDisk | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_attached_disk` |
| Autoscaler | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_autoscaler` |
| BackendBucket | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_backend_bucket` |
| BackendBucketSignedURLKey | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_backend_bucket_signed_url_key` |
| BackendService | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_backend_service` |
| BackendServiceSignedURLKey | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_backend_service_signed_url_key` |
| Disk | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_disk` |
| DiskIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_disk_i_a_m_member` |
| DiskResourcePolicyAttachment | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_disk_resource_policy_attachment` |
| ExternalVPNGateway | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_external_v_p_n_gateway` |
| Firewall | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_firewall` |
| FirewallPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_firewall_policy` |
| FirewallPolicyAssociation | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_firewall_policy_association` |
| FirewallPolicyRule | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_firewall_policy_rule` |
| ForwardingRule | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_forwarding_rule` |
| GlobalAddress | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_address` |
| GlobalForwardingRule | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_forwarding_rule` |
| GlobalNetworkEndpoint | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_network_endpoint` |
| GlobalNetworkEndpointGroup | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_global_network_endpoint_group` |
| HaVPNGateway | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_ha_v_p_n_gateway` |
| HealthCheck | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_health_check` |
| HTTPHealthCheck | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_http_health_check` |
| HTTPSHealthCheck | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_https_health_check` |
| Image | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_image` |
| ImageIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_image_i_a_m_member` |
| Instance | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance` |
| InstanceFromTemplate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_from_template` |
| InstanceGroup | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_group` |
| InstanceGroupManager | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_group_manager` |
| InstanceGroupNamedPort | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_group_named_port` |
| InstanceIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_i_a_m_member` |
| InstanceTemplate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_instance_template` |
| InterconnectAttachment | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_interconnect_attachment` |
| ManagedSSLCertificate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_managed_s_s_l_certificate` |
| Network | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network` |
| NetworkEndpoint | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_endpoint` |
| NetworkEndpointGroup | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_endpoint_group` |
| NetworkFirewallPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_firewall_policy` |
| NetworkFirewallPolicyAssociation | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_firewall_policy_association` |
| NetworkFirewallPolicyRule | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_firewall_policy_rule` |
| NetworkPeering | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_peering` |
| NetworkPeeringRoutesConfig | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_network_peering_routes_config` |
| NodeGroup | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_node_group` |
| NodeTemplate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_node_template` |
| PacketMirroring | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_packet_mirroring` |
| PerInstanceConfig | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_per_instance_config` |
| ProjectDefaultNetworkTier | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_project_default_network_tier` |
| ProjectMetadata | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_project_metadata` |
| ProjectMetadataItem | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_project_metadata_item` |
| RegionAutoscaler | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_autoscaler` |
| RegionBackendService | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_backend_service` |
| RegionDisk | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_disk` |
| RegionDiskIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_disk_i_a_m_member` |
| RegionDiskResourcePolicyAttachment | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_disk_resource_policy_attachment` |
| RegionHealthCheck | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_health_check` |
| RegionInstanceGroupManager | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_instance_group_manager` |
| RegionNetworkEndpoint | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_network_endpoint` |
| RegionNetworkEndpointGroup | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_network_endpoint_group` |
| RegionNetworkFirewallPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_network_firewall_policy` |
| RegionNetworkFirewallPolicyAssociation | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_network_firewall_policy_association` |
| RegionPerInstanceConfig | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_per_instance_config` |
| RegionSecurityPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_security_policy` |
| RegionSSLCertificate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_s_s_l_certificate` |
| RegionSSLPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_s_s_l_policy` |
| RegionTargetHTTPProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_target_http_proxy` |
| RegionTargetHTTPSProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_target_https_proxy` |
| RegionTargetTCPProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_target_tcp_proxy` |
| RegionURLMap | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_region_url_map` |
| Reservation | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_reservation` |
| ResourcePolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_resource_policy` |
| Route | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_route` |
| Router | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router` |
| RouterInterface | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router_interface` |
| RouterNAT | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router_n_a_t` |
| RouterPeer | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_router_peer` |
| SecurityPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_security_policy` |
| ServiceAttachment | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_service_attachment` |
| SharedVPCHostProject | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_shared_v_p_c_host_project` |
| SharedVPCServiceProject | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_shared_v_p_c_service_project` |
| Snapshot | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_snapshot` |
| SnapshotIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_snapshot_i_a_m_member` |
| SSLCertificate | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_s_s_l_certificate` |
| SSLPolicy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_s_s_l_policy` |
| Subnetwork | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_subnetwork` |
| SubnetworkIAMMember | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_subnetwork_i_a_m_member` |
| TargetGRPCProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_g_rpc_proxy` |
| TargetHTTPProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_http_proxy` |
| TargetHTTPSProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_https_proxy` |
| TargetInstance | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_instance` |
| TargetPool | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_pool` |
| TargetSSLProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_s_s_l_proxy` |
| TargetTCPProxy | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_target_tcp_proxy` |
| URLMap | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_url_map` |
| VPNGateway | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_v_p_n_gateway` |
| VPNTunnel | `gcp_compute.models.v1beta1.compute_gcpm_upbound_io_v1beta1_v_p_n_tunnel` |
