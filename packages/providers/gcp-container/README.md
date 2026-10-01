# gcp-container

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gcp-container`.

Source: ghcr.io/crossplane-contrib/provider-gcp-container:v2.6.0 (scope=namespaced; service=container)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gcp-container = { path = "<relative path>/packages/providers/gcp-container" }
```

Then import a model:

```python
import gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_cluster as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Cluster | `gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_cluster` |
| NodePool | `gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_node_pool` |
| Registry | `gcp_container.models.v1beta1.container_gcpm_upbound_io_v1beta1_registry` |
