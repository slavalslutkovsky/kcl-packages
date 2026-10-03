# azure-containerapp

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-containerapp`.

Source: ghcr.io/crossplane-contrib/provider-azure-containerapp:v2.6.0 (scope=namespaced; service=containerapp)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-containerapp = { path = "<relative path>/packages/providers/azure-containerapp" }
```

Then import a model:

```python
import azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_container_app as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ContainerApp | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_container_app` |
| ContainerJob | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_container_job` |
| CustomDomain | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_custom_domain` |
| Environment | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment` |
| EnvironmentCertificate | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment_certificate` |
| EnvironmentCustomDomain | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment_custom_domain` |
| EnvironmentDaprComponent | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment_dapr_component` |
| EnvironmentStorage | `azure_containerapp.models.v1beta1.containerapp_azurem_upbound_io_v1beta1_environment_storage` |
