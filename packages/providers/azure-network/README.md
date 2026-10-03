# azure-network

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-network`.

Source: ghcr.io/crossplane-contrib/provider-azure-network:v2.6.0 (scope=namespaced; service=network)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-network = { path = "<relative path>/packages/providers/azure-network" }
```

Then import a model:

```python
import azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_application_gateway as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ApplicationGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_application_gateway` |
| ApplicationSecurityGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_application_security_group` |
| BastionHost | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_bastion_host` |
| ConnectionMonitor | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_connection_monitor` |
| DDoSProtectionPlan | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_d_do_s_protection_plan` |
| DNSAAAARecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_a_a_a_a_record` |
| DNSARecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_a_record` |
| DNSCAARecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_c_a_a_record` |
| DNSCNAMERecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_c_n_a_m_e_record` |
| DNSMXRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_m_x_record` |
| DNSNSRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_n_s_record` |
| DNSPTRRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_p_t_r_record` |
| DNSSRVRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_s_r_v_record` |
| DNSTXTRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_t_x_t_record` |
| DNSZone | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_dns_zone` |
| ExpressRouteCircuit | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_circuit` |
| ExpressRouteCircuitAuthorization | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_circuit_authorization` |
| ExpressRouteCircuitConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_circuit_connection` |
| ExpressRouteCircuitPeering | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_circuit_peering` |
| ExpressRouteConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_connection` |
| ExpressRouteGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_gateway` |
| ExpressRoutePort | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_express_route_port` |
| Firewall | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall` |
| FirewallApplicationRuleCollection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall_application_rule_collection` |
| FirewallNATRuleCollection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall_n_a_t_rule_collection` |
| FirewallNetworkRuleCollection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall_network_rule_collection` |
| FirewallPolicy | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall_policy` |
| FirewallPolicyRuleCollectionGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_firewall_policy_rule_collection_group` |
| FrontDoor | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_front_door` |
| FrontdoorCustomHTTPSConfiguration | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_frontdoor_custom_https_configuration` |
| FrontdoorFirewallPolicy | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_frontdoor_firewall_policy` |
| FrontdoorRulesEngine | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_frontdoor_rules_engine` |
| IPGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_ip_group` |
| LoadBalancer | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer` |
| LoadBalancerBackendAddressPool | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_backend_address_pool` |
| LoadBalancerBackendAddressPoolAddress | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_backend_address_pool_address` |
| LoadBalancerNatPool | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_nat_pool` |
| LoadBalancerNatRule | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_nat_rule` |
| LoadBalancerOutboundRule | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_outbound_rule` |
| LoadBalancerProbe | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_probe` |
| LoadBalancerRule | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_load_balancer_rule` |
| LocalNetworkGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_local_network_gateway` |
| Manager | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager` |
| ManagerIpamPool | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_ipam_pool` |
| ManagerManagementGroupConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_management_group_connection` |
| ManagerNetworkGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_network_group` |
| ManagerRoutingConfiguration | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_routing_configuration` |
| ManagerStaticMember | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_static_member` |
| ManagerSubscriptionConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_subscription_connection` |
| ManagerVerifierWorkspace | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_manager_verifier_workspace` |
| NATGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_n_a_t_gateway` |
| NATGatewayPublicIPAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_n_a_t_gateway_public_ip_association` |
| NATGatewayPublicIPPrefixAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_n_a_t_gateway_public_ip_prefix_association` |
| NetworkInterface | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface` |
| NetworkInterfaceApplicationSecurityGroupAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface_application_security_group_association` |
| NetworkInterfaceBackendAddressPoolAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface_backend_address_pool_association` |
| NetworkInterfaceNatRuleAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface_nat_rule_association` |
| NetworkInterfaceSecurityGroupAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_network_interface_security_group_association` |
| PacketCapture | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_packet_capture` |
| PointToSiteVPNGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_point_to_site_v_p_n_gateway` |
| PrivateDNSAAAARecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_a_a_a_a_record` |
| PrivateDNSARecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_a_record` |
| PrivateDNSCNAMERecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_c_n_a_m_e_record` |
| PrivateDNSMXRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_m_x_record` |
| PrivateDNSPTRRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_p_t_r_record` |
| PrivateDNSResolver | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver` |
| PrivateDNSResolverDNSForwardingRuleset | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver_dns_forwarding_ruleset` |
| PrivateDNSResolverForwardingRule | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver_forwarding_rule` |
| PrivateDNSResolverInboundEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver_inbound_endpoint` |
| PrivateDNSResolverOutboundEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver_outbound_endpoint` |
| PrivateDNSResolverVirtualNetworkLink | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_resolver_virtual_network_link` |
| PrivateDNSSRVRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_s_r_v_record` |
| PrivateDNSTXTRecord | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_t_x_t_record` |
| PrivateDNSZone | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_zone` |
| PrivateDNSZoneVirtualNetworkLink | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_dns_zone_virtual_network_link` |
| PrivateEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_endpoint` |
| PrivateEndpointApplicationSecurityGroupAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_endpoint_application_security_group_association` |
| PrivateLinkService | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_private_link_service` |
| Profile | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_profile` |
| PublicIP | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_public_ip` |
| PublicIPPrefix | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_public_ip_prefix` |
| Route | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route` |
| RouteFilter | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route_filter` |
| RouteMap | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route_map` |
| RouteServer | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route_server` |
| RouteServerBGPConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route_server_b_g_p_connection` |
| RouteTable | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_route_table` |
| SecurityGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_security_group` |
| SecurityRule | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_security_rule` |
| Subnet | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet` |
| SubnetNATGatewayAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_n_a_t_gateway_association` |
| SubnetNetworkSecurityGroupAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_network_security_group_association` |
| SubnetRouteTableAssociation | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_route_table_association` |
| SubnetServiceEndpointStoragePolicy | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_subnet_service_endpoint_storage_policy` |
| TrafficManagerAzureEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_traffic_manager_azure_endpoint` |
| TrafficManagerExternalEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_traffic_manager_external_endpoint` |
| TrafficManagerNestedEndpoint | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_traffic_manager_nested_endpoint` |
| TrafficManagerProfile | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_traffic_manager_profile` |
| VirtualHub | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub` |
| VirtualHubConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_connection` |
| VirtualHubIP | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_ip` |
| VirtualHubRouteTable | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_route_table` |
| VirtualHubRouteTableRoute | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_route_table_route` |
| VirtualHubRoutingIntent | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_routing_intent` |
| VirtualHubSecurityPartnerProvider | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_hub_security_partner_provider` |
| VirtualNetwork | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network` |
| VirtualNetworkDNSServers | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network_dns_servers` |
| VirtualNetworkGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network_gateway` |
| VirtualNetworkGatewayConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network_gateway_connection` |
| VirtualNetworkPeering | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_network_peering` |
| VirtualWAN | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_virtual_w_a_n` |
| VPNGateway | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_v_p_n_gateway` |
| VPNGatewayConnection | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_v_p_n_gateway_connection` |
| VPNServerConfiguration | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_v_p_n_server_configuration` |
| VPNServerConfigurationPolicyGroup | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_v_p_n_server_configuration_policy_group` |
| VPNSite | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_v_p_n_site` |
| Watcher | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_watcher` |
| WatcherFlowLog | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_watcher_flow_log` |
| WebApplicationFirewallPolicy | `azure_network.models.v1beta1.network_azurem_upbound_io_v1beta1_web_application_firewall_policy` |
