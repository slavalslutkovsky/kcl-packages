# gateway-api

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed gateway-api`.

Source: kubernetes-sigs/gateway-api@v1.4.0 (config/crd/standard); service=gateway; scope=cluster

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
gateway-api = { path = "<relative path>/packages/providers/gateway-api" }
```

Then import a model:

```python
import gateway_api.models.v1.gateway_networking_k8s_io_v1_backend_tls_policy as model
```

## Kinds

### v1

| kind | import |
| --- | --- |
| BackendTLSPolicy | `gateway_api.models.v1.gateway_networking_k8s_io_v1_backend_tls_policy` |
| Gateway | `gateway_api.models.v1.gateway_networking_k8s_io_v1_gateway` |
| GatewayClass | `gateway_api.models.v1.gateway_networking_k8s_io_v1_gateway_class` |
| GRPCRoute | `gateway_api.models.v1.gateway_networking_k8s_io_v1_g_rpc_route` |
| HTTPRoute | `gateway_api.models.v1.gateway_networking_k8s_io_v1_http_route` |

### v1alpha3

| kind | import |
| --- | --- |
| BackendTLSPolicy | `gateway_api.models.v1alpha3.gateway_networking_k8s_io_v1alpha3_backend_tls_policy` |

### v1beta1

| kind | import |
| --- | --- |
| Gateway | `gateway_api.models.v1beta1.gateway_networking_k8s_io_v1beta1_gateway` |
| GatewayClass | `gateway_api.models.v1beta1.gateway_networking_k8s_io_v1beta1_gateway_class` |
| HTTPRoute | `gateway_api.models.v1beta1.gateway_networking_k8s_io_v1beta1_http_route` |
| ReferenceGrant | `gateway_api.models.v1beta1.gateway_networking_k8s_io_v1beta1_reference_grant` |
