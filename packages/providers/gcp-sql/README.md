# gcp-sql

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-sql`.

Source: ghcr.io/crossplane-contrib/provider-gcp-sql:v2.6.0 (scope=namespaced; service=sql)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-sql = { path = "<relative path>/packages/providers/gcp-sql" }
```

Then import a model:

```python
import gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Database | `gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database` |
| DatabaseInstance | `gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_database_instance` |
| SourceRepresentationInstance | `gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_source_representation_instance` |
| SSLCert | `gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_s_s_l_cert` |
| User | `gcp_sql.models.v1beta1.sql_gcpm_upbound_io_v1beta1_user` |
