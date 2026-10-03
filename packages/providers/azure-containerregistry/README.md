# azure-containerregistry

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-containerregistry`.

Source: ghcr.io/crossplane-contrib/provider-azure-containerregistry:v2.6.0 (scope=namespaced; service=containerregistry)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-containerregistry = { path = "<relative path>/packages/providers/azure-containerregistry" }
```

Then import a model:

```python
import azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_agent_pool as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AgentPool | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_agent_pool` |
| CacheRule | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_cache_rule` |
| ContainerConnectedRegistry | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_container_connected_registry` |
| CredentialSet | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_credential_set` |
| Registry | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_registry` |
| ScopeMap | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_scope_map` |
| Token | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_token` |
| TokenPassword | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_token_password` |
| Webhook | `azure_containerregistry.models.v1beta1.containerregistry_azurem_upbound_io_v1beta1_webhook` |
