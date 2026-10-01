# istio

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed istio`.

Source: istio/istio@1.28.1 (manifests/charts/base/files); service=crd-all; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
istio = { path = "<relative path>/packages/providers/istio" }
```

Then import a model:

```python
import istio.models.v1.security_istio_io_v1_authorization_policy as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| AuthorizationPolicy | `istio.models.v1.security_istio_io_v1_authorization_policy` |
| DestinationRule | `istio.models.v1.networking_istio_io_v1_destination_rule` |
| Gateway | `istio.models.v1.networking_istio_io_v1_gateway` |
| PeerAuthentication | `istio.models.v1.security_istio_io_v1_peer_authentication` |
| RequestAuthentication | `istio.models.v1.security_istio_io_v1_request_authentication` |
| ServiceEntry | `istio.models.v1.networking_istio_io_v1_service_entry` |
| Sidecar | `istio.models.v1.networking_istio_io_v1_sidecar` |
| Telemetry | `istio.models.v1.telemetry_istio_io_v1_telemetry` |
| VirtualService | `istio.models.v1.networking_istio_io_v1_virtual_service` |
| WorkloadEntry | `istio.models.v1.networking_istio_io_v1_workload_entry` |
| WorkloadGroup | `istio.models.v1.networking_istio_io_v1_workload_group` |

### v1alpha1

| kind | import |
| --- | --- |
| Telemetry | `istio.models.v1alpha1.telemetry_istio_io_v1alpha1_telemetry` |
| WasmPlugin | `istio.models.v1alpha1.extensions_istio_io_v1alpha1_wasm_plugin` |

### v1alpha3

| kind | import |
| --- | --- |
| DestinationRule | `istio.models.v1alpha3.networking_istio_io_v1alpha3_destination_rule` |
| EnvoyFilter | `istio.models.v1alpha3.networking_istio_io_v1alpha3_envoy_filter` |
| Gateway | `istio.models.v1alpha3.networking_istio_io_v1alpha3_gateway` |
| ServiceEntry | `istio.models.v1alpha3.networking_istio_io_v1alpha3_service_entry` |
| Sidecar | `istio.models.v1alpha3.networking_istio_io_v1alpha3_sidecar` |
| VirtualService | `istio.models.v1alpha3.networking_istio_io_v1alpha3_virtual_service` |
| WorkloadEntry | `istio.models.v1alpha3.networking_istio_io_v1alpha3_workload_entry` |
| WorkloadGroup | `istio.models.v1alpha3.networking_istio_io_v1alpha3_workload_group` |

### v1beta1

| kind | import |
| --- | --- |
| AuthorizationPolicy | `istio.models.v1beta1.security_istio_io_v1beta1_authorization_policy` |
| DestinationRule | `istio.models.v1beta1.networking_istio_io_v1beta1_destination_rule` |
| Gateway | `istio.models.v1beta1.networking_istio_io_v1beta1_gateway` |
| PeerAuthentication | `istio.models.v1beta1.security_istio_io_v1beta1_peer_authentication` |
| ProxyConfig | `istio.models.v1beta1.networking_istio_io_v1beta1_proxy_config` |
| RequestAuthentication | `istio.models.v1beta1.security_istio_io_v1beta1_request_authentication` |
| ServiceEntry | `istio.models.v1beta1.networking_istio_io_v1beta1_service_entry` |
| Sidecar | `istio.models.v1beta1.networking_istio_io_v1beta1_sidecar` |
| VirtualService | `istio.models.v1beta1.networking_istio_io_v1beta1_virtual_service` |
| WorkloadEntry | `istio.models.v1beta1.networking_istio_io_v1beta1_workload_entry` |
| WorkloadGroup | `istio.models.v1beta1.networking_istio_io_v1beta1_workload_group` |
