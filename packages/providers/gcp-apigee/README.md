# gcp-apigee

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-apigee`.

Source: ghcr.io/crossplane-contrib/provider-gcp-apigee:v2.6.0 (scope=namespaced; service=apigee)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-apigee = { path = "<relative path>/packages/providers/gcp-apigee" }
```

Then import a model:

```python
import gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_addons_config as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AddonsConfig | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_addons_config` |
| EndpointAttachment | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_endpoint_attachment` |
| Envgroup | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_envgroup` |
| EnvgroupAttachment | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_envgroup_attachment` |
| Environment | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_environment` |
| EnvironmentIAMMember | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_environment_i_a_m_member` |
| EnvKeystore | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_env_keystore` |
| EnvReferences | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_env_references` |
| Instance | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_instance` |
| InstanceAttachment | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_instance_attachment` |
| KeystoresAliasesKeyCertFile | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_keystores_aliases_key_cert_file` |
| NATAddress | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_n_a_t_address` |
| Organization | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_organization` |
| SyncAuthorization | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_sync_authorization` |
| TargetServer | `gcp_apigee.models.v1beta1.apigee_gcpm_upbound_io_v1beta1_target_server` |
