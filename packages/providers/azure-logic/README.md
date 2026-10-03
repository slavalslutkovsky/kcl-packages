# azure-logic

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-logic`.

Source: ghcr.io/crossplane-contrib/provider-azure-logic:v2.6.0 (scope=namespaced; service=logic)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-logic = { path = "<relative path>/packages/providers/azure-logic" }
```

Then import a model:

```python
import azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_action_custom as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AppActionCustom | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_action_custom` |
| AppActionHTTP | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_action_http` |
| AppIntegrationAccount | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_integration_account` |
| AppIntegrationAccountBatchConfiguration | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_integration_account_batch_configuration` |
| AppIntegrationAccountPartner | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_integration_account_partner` |
| AppIntegrationAccountSchema | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_integration_account_schema` |
| AppIntegrationAccountSession | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_integration_account_session` |
| AppTriggerCustom | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_trigger_custom` |
| AppTriggerHTTPRequest | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_trigger_http_request` |
| AppTriggerRecurrence | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_trigger_recurrence` |
| AppWorkflow | `azure_logic.models.v1beta1.logic_azurem_upbound_io_v1beta1_app_workflow` |
