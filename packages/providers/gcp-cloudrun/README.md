# gcp-cloudrun

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-cloudrun`.

Source: ghcr.io/crossplane-contrib/provider-gcp-cloudrun:v2.6.0 (scope=namespaced; service=cloudrun)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-cloudrun = { path = "<relative path>/packages/providers/gcp-cloudrun" }
```

Then import a model:

```python
import gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_domain_mapping as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| DomainMapping | `gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_domain_mapping` |
| Service | `gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_service` |
| ServiceIAMMember | `gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_service_i_a_m_member` |
| V2Job | `gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_v2_job` |
| V2Service | `gcp_cloudrun.models.v1beta1.cloudrun_gcpm_upbound_io_v1beta1_v2_service` |
