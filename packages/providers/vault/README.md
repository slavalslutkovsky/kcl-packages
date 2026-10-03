# vault

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed vault`.

Source: xpkg.upbound.io/upbound/provider-vault:v4.0.3 (scope=namespaced; service=vault,transit)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
vault = { path = "<relative path>/packages/providers/vault" }
```

Then import a model:

```python
import vault.models.v1beta1.vaultm_upbound_io_v1beta1_cluster_provider_config as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ClusterProviderConfig | `vault.models.v1beta1.vaultm_upbound_io_v1beta1_cluster_provider_config` |
| ProviderConfig | `vault.models.v1beta1.vaultm_upbound_io_v1beta1_provider_config` |
| ProviderConfigUsage | `vault.models.v1beta1.vaultm_upbound_io_v1beta1_provider_config_usage` |

### unknown

Import the directory as one package — `import vault.models.unknown as m` — and use `m.<kind>`.

- Audit
- Mount
- Policy
- SecretBackendKey
- Token
- VaultNamespace
