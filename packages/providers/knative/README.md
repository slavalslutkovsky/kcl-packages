# knative

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed knative`.

Source: knative/serving@knative-v1.23.0 (config/core/300-resources); service=service,configuration,revision,route,domain-mapping; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
knative = { path = "<relative path>/packages/providers/knative" }
```

Then import a model:

```python
import knative.models.v1.serving_knative_dev_v1_configuration as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| Configuration | `knative.models.v1.serving_knative_dev_v1_configuration` |
| Revision | `knative.models.v1.serving_knative_dev_v1_revision` |
| Route | `knative.models.v1.serving_knative_dev_v1_route` |
| Service | `knative.models.v1.serving_knative_dev_v1_service` |

### v1beta1

| kind | import |
| --- | --- |
| DomainMapping | `knative.models.v1beta1.serving_knative_dev_v1beta1_domain_mapping` |
