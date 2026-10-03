# azure-cdn

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-cdn`.

Source: ghcr.io/crossplane-contrib/provider-azure-cdn:v2.6.0 (scope=namespaced; service=cdn)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-cdn = { path = "<relative path>/packages/providers/azure-cdn" }
```

Then import a model:

```python
import azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_endpoint as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Endpoint | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_endpoint` |
| FrontdoorCustomDomain | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_custom_domain` |
| FrontdoorCustomDomainAssociation | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_custom_domain_association` |
| FrontdoorEndpoint | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_endpoint` |
| FrontdoorFirewallPolicy | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_firewall_policy` |
| FrontdoorOrigin | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_origin` |
| FrontdoorOriginGroup | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_origin_group` |
| FrontdoorProfile | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_profile` |
| FrontdoorRoute | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_route` |
| FrontdoorRule | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_rule` |
| FrontdoorRuleSet | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_rule_set` |
| FrontdoorSecret | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_secret` |
| FrontdoorSecurityPolicy | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_frontdoor_security_policy` |
| Profile | `azure_cdn.models.v1beta1.cdn_azurem_upbound_io_v1beta1_profile` |
