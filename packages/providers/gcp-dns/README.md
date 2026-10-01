# gcp-dns

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-dns`.

Source: ghcr.io/crossplane-contrib/provider-gcp-dns:v2.6.0 (scope=namespaced; service=dns)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-dns = { path = "<relative path>/packages/providers/gcp-dns" }
```

Then import a model:

```python
import gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ManagedZone | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone` |
| ManagedZoneIAMMember | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_managed_zone_i_a_m_member` |
| Policy | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_policy` |
| RecordSet | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_record_set` |
| ResponsePolicy | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_response_policy` |
| ResponsePolicyRule | `gcp_dns.models.v1beta1.dns_gcpm_upbound_io_v1beta1_response_policy_rule` |
