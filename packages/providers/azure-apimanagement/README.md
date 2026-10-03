# azure-apimanagement

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-apimanagement`.

Source: ghcr.io/crossplane-contrib/provider-azure-apimanagement:v2.6.0 (scope=namespaced; service=apimanagement)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-apimanagement = { path = "<relative path>/packages/providers/azure-apimanagement" }
```

Then import a model:

```python
import azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| API | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api` |
| APIDiagnostic | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_diagnostic` |
| APIOperation | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_operation` |
| APIOperationPolicy | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_operation_policy` |
| APIOperationTag | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_operation_tag` |
| APIPolicy | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_policy` |
| APIRelease | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_release` |
| APISchema | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_schema` |
| APITag | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_tag` |
| APIVersionSet | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_api_version_set` |
| AuthorizationServer | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_authorization_server` |
| Backend | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_backend` |
| Certificate | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_certificate` |
| CustomDomain | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_custom_domain` |
| Diagnostic | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_diagnostic` |
| EmailTemplate | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_email_template` |
| Gateway | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_gateway` |
| GatewayAPI | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_gateway_api` |
| GlobalSchema | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_global_schema` |
| Group | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_group` |
| IdentityProviderAAD | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_identity_provider_a_a_d` |
| IdentityProviderFacebook | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_identity_provider_facebook` |
| IdentityProviderGoogle | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_identity_provider_google` |
| IdentityProviderMicrosoft | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_identity_provider_microsoft` |
| IdentityProviderTwitter | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_identity_provider_twitter` |
| Logger | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_logger` |
| Management | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_management` |
| NamedValue | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_named_value` |
| NotificationRecipientEmail | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_notification_recipient_email` |
| NotificationRecipientUser | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_notification_recipient_user` |
| OpenIDConnectProvider | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_open_id_connect_provider` |
| Policy | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_policy` |
| PolicyFragment | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_policy_fragment` |
| Product | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_product` |
| ProductAPI | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_product_api` |
| ProductGroup | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_product_group` |
| ProductPolicy | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_product_policy` |
| ProductTag | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_product_tag` |
| RedisCache | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_redis_cache` |
| Subscription | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_subscription` |
| Tag | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_tag` |
| User | `azure_apimanagement.models.v1beta1.apimanagement_azurem_upbound_io_v1beta1_user` |
