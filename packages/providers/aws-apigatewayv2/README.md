# aws-apigatewayv2

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-apigatewayv2`.

Source: ghcr.io/crossplane-contrib/provider-aws-apigatewayv2:v2.6.0 (scope=namespaced; service=apigatewayv2)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-apigatewayv2 = { path = "<relative path>/packages/providers/aws-apigatewayv2" }
```

Then import a model:

```python
import aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_api as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| API | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_api` |
| APIMapping | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_api_mapping` |
| Authorizer | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_authorizer` |
| Deployment | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_deployment` |
| DomainName | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_domain_name` |
| Integration | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_integration` |
| IntegrationResponse | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_integration_response` |
| Model | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_model` |
| Route | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_route` |
| RouteResponse | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_route_response` |
| Stage | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_stage` |
| VPCLink | `aws_apigatewayv2.models.v1beta1.apigatewayv2_awsm_upbound_io_v1beta1_v_p_c_link` |
