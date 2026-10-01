# aws-ec2

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-ec2`.

Source: ghcr.io/crossplane-contrib/provider-aws-ec2:v2.6.0 (scope=namespaced; service=ec2)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-ec2 = { path = "<relative path>/packages/providers/aws-ec2" }
```

Then import a model:

```python
import aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_a_m_i as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AMI | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_a_m_i` |
| AMICopy | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_a_m_i_copy` |
| AMILaunchPermission | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_a_m_i_launch_permission` |
| AvailabilityZoneGroup | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_availability_zone_group` |
| CapacityBlockReservation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_capacity_block_reservation` |
| CapacityReservation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_capacity_reservation` |
| CarrierGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_carrier_gateway` |
| CustomerGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_customer_gateway` |
| DefaultNetworkACL | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_network_acl` |
| DefaultRouteTable | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_route_table` |
| DefaultSecurityGroup | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_security_group` |
| DefaultSubnet | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_subnet` |
| DefaultVPC | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_v_p_c` |
| DefaultVPCDHCPOptions | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_default_v_p_c_d_h_c_p_options` |
| EBSDefaultKMSKey | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_default_k_m_s_key` |
| EBSEncryptionByDefault | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_encryption_by_default` |
| EBSSnapshot | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_snapshot` |
| EBSSnapshotCopy | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_snapshot_copy` |
| EBSSnapshotImport | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_snapshot_import` |
| EBSVolume | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_b_s_volume` |
| EgressOnlyInternetGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_egress_only_internet_gateway` |
| EIP | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_ip` |
| EIPAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_e_ip_association` |
| Fleet | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_fleet` |
| FlowLog | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_flow_log` |
| Host | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_host` |
| Instance | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_instance` |
| InstanceState | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_instance_state` |
| InternetGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_internet_gateway` |
| KeyPair | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_key_pair` |
| LaunchTemplate | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_launch_template` |
| MainRouteTableAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_main_route_table_association` |
| ManagedPrefixList | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_managed_prefix_list` |
| ManagedPrefixListEntry | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_managed_prefix_list_entry` |
| NATGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_n_a_t_gateway` |
| NetworkACL | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_acl` |
| NetworkACLRule | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_acl_rule` |
| NetworkInsightsAnalysis | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_insights_analysis` |
| NetworkInsightsPath | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_insights_path` |
| NetworkInterface | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_interface` |
| NetworkInterfaceAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_interface_attachment` |
| NetworkInterfaceSgAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_network_interface_sg_attachment` |
| PlacementGroup | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_placement_group` |
| Route | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route` |
| RouteTable | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route_table` |
| RouteTableAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_route_table_association` |
| SecurityGroup | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group` |
| SecurityGroupEgressRule | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group_egress_rule` |
| SecurityGroupIngressRule | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group_ingress_rule` |
| SecurityGroupRule | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_security_group_rule` |
| SerialConsoleAccess | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_serial_console_access` |
| SnapshotCreateVolumePermission | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_snapshot_create_volume_permission` |
| SpotDatafeedSubscription | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_spot_datafeed_subscription` |
| SpotFleetRequest | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_spot_fleet_request` |
| SpotInstanceRequest | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_spot_instance_request` |
| Subnet | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_subnet` |
| SubnetCidrReservation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_subnet_cidr_reservation` |
| Tag | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_tag` |
| TrafficMirrorFilter | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_traffic_mirror_filter` |
| TrafficMirrorFilterRule | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_traffic_mirror_filter_rule` |
| TransitGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway` |
| TransitGatewayConnect | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_connect` |
| TransitGatewayConnectPeer | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_connect_peer` |
| TransitGatewayMulticastDomain | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_multicast_domain` |
| TransitGatewayMulticastDomainAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_multicast_domain_association` |
| TransitGatewayMulticastGroupMember | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_multicast_group_member` |
| TransitGatewayMulticastGroupSource | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_multicast_group_source` |
| TransitGatewayPeeringAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_peering_attachment` |
| TransitGatewayPeeringAttachmentAccepter | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_peering_attachment_accepter` |
| TransitGatewayPolicyTable | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_policy_table` |
| TransitGatewayPrefixListReference | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_prefix_list_reference` |
| TransitGatewayRoute | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route` |
| TransitGatewayRouteTable | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table` |
| TransitGatewayRouteTableAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table_association` |
| TransitGatewayRouteTablePropagation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_route_table_propagation` |
| TransitGatewayVPCAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_v_p_c_attachment` |
| TransitGatewayVPCAttachmentAccepter | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_transit_gateway_v_p_c_attachment_accepter` |
| VolumeAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_volume_attachment` |
| VPC | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c` |
| VPCDHCPOptions | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_d_h_c_p_options` |
| VPCDHCPOptionsAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_d_h_c_p_options_association` |
| VPCEndpoint | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint` |
| VPCEndpointConnectionAccepter | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_connection_accepter` |
| VPCEndpointConnectionNotification | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_connection_notification` |
| VPCEndpointRouteTableAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_route_table_association` |
| VPCEndpointSecurityGroupAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_security_group_association` |
| VPCEndpointService | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_service` |
| VPCEndpointServiceAllowedPrincipal | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_service_allowed_principal` |
| VPCEndpointSubnetAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_endpoint_subnet_association` |
| VPCIpam | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ipam` |
| VPCIpamPool | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ipam_pool` |
| VPCIpamPoolCidr | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ipam_pool_cidr` |
| VPCIpamPoolCidrAllocation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ipam_pool_cidr_allocation` |
| VPCIpamScope | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ipam_scope` |
| VPCIPv4CidrBlockAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ip_v4_cidr_block_association` |
| VPCIPv6CidrBlockAssociation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_ip_v6_cidr_block_association` |
| VPCPeeringConnection | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_peering_connection` |
| VPCPeeringConnectionAccepter | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_peering_connection_accepter` |
| VPCPeeringConnectionOptions | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_c_peering_connection_options` |
| VPNConnection | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_n_connection` |
| VPNConnectionRoute | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_n_connection_route` |
| VPNGateway | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_n_gateway` |
| VPNGatewayAttachment | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_n_gateway_attachment` |
| VPNGatewayRoutePropagation | `aws_ec2.models.v1beta1.ec2_awsm_upbound_io_v1beta1_v_p_n_gateway_route_propagation` |
