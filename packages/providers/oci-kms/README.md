# oci-kms

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed oci-kms`.

Source: ghcr.io/oracle/provider-oci-kms:v2.0.0 (scope=namespaced; service=kms)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
oci-kms = { path = "<relative path>/packages/providers/oci-kms" }
```

Then import a model:

```python
import oci_kms.models.unknown as m

_t = m.EkmsPrivateEndpoint
```

## Kinds

### unknown

Import the directory as one package — `import oci_kms.models.unknown as m` — and use `m.<kind>`.

- EkmsPrivateEndpoint
- EncryptedData
- GeneratedKey
- Key
- KeyVersion
- Sign
- Vault
- VaultReplication
- Verify
