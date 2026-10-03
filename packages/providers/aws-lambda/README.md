# aws-lambda

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-lambda`.

Source: ghcr.io/crossplane-contrib/provider-aws-lambda:v2.6.0 (scope=namespaced; service=lambda)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-lambda = { path = "<relative path>/packages/providers/aws-lambda" }
```

Then import a model:

```python
import aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_alias as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Alias | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_alias` |
| CodeSigningConfig | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_code_signing_config` |
| EventSourceMapping | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_event_source_mapping` |
| Function | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_function` |
| FunctionEventInvokeConfig | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_function_event_invoke_config` |
| FunctionURL | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_function_url` |
| Invocation | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_invocation` |
| LayerVersion | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_layer_version` |
| LayerVersionPermission | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_layer_version_permission` |
| Permission | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_permission` |
| ProvisionedConcurrencyConfig | `aws_lambda.models.v1beta1.lambda_awsm_upbound_io_v1beta1_provisioned_concurrency_config` |
