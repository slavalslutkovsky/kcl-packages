# azure-dbforpostgresql

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-dbforpostgresql`.

Source: ghcr.io/crossplane-contrib/provider-azure-dbforpostgresql:v2.6.0 (scope=namespaced; service=dbforpostgresql)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-dbforpostgresql = { path = "<relative path>/packages/providers/azure-dbforpostgresql" }
```

Then import a model:

```python
import azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_active_directory_administrator as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ActiveDirectoryAdministrator | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_active_directory_administrator` |
| Configuration | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_configuration` |
| Database | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_database` |
| FirewallRule | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_firewall_rule` |
| FlexibleServer | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server` |
| FlexibleServerActiveDirectoryAdministrator | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_active_directory_administrator` |
| FlexibleServerBackup | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_backup` |
| FlexibleServerConfiguration | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_configuration` |
| FlexibleServerDatabase | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_database` |
| FlexibleServerFirewallRule | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_firewall_rule` |
| FlexibleServerVirtualEndpoint | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_flexible_server_virtual_endpoint` |
| Server | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_server` |
| ServerKey | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_server_key` |
| VirtualNetworkRule | `azure_dbforpostgresql.models.v1beta1.dbforpostgresql_azurem_upbound_io_v1beta1_virtual_network_rule` |
