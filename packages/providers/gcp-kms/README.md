# gcp-kms

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-kms`.

Source: ghcr.io/crossplane-contrib/provider-gcp-kms:v2.6.0 (scope=namespaced; service=kms)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-kms = { path = "<relative path>/packages/providers/gcp-kms" }
```

Then import a model:

```python
import gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| CryptoKey | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key` |
| CryptoKeyIAMMember | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key_i_a_m_member` |
| CryptoKeyVersion | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_crypto_key_version` |
| KeyRing | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_key_ring` |
| KeyRingIAMMember | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_key_ring_i_a_m_member` |
| KeyRingImportJob | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_key_ring_import_job` |
| SecretCiphertext | `gcp_kms.models.v1beta1.kms_gcpm_upbound_io_v1beta1_secret_ciphertext` |
