# prometheus-operator

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed prometheus-operator`.

Source: prometheus-operator/prometheus-operator@v0.85.0 (example/prometheus-operator-crd); service=monitoring.coreos.com_servicemonitors,monitoring.coreos.com_podmonitors,monitoring.coreos.com_prometheusrules; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
prometheus-operator = { path = "<relative path>/packages/providers/prometheus-operator" }
```

Then import a model:

```python
import prometheus_operator.models.unknown as m

_t = m.PodMonitor
```

## Kinds

### unknown

Import the directory as one package — `import prometheus_operator.models.unknown as m` — and use `m.<kind>`.

- PodMonitor
- PrometheusRule
- ServiceMonitor
