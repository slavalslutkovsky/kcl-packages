# aws-cloudfront

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-cloudfront`.

Source: ghcr.io/crossplane-contrib/provider-aws-cloudfront:v2.6.0 (scope=namespaced; service=cloudfront)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-cloudfront = { path = "<relative path>/packages/providers/aws-cloudfront" }
```

Then import a model:

```python
import aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_cache_policy as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| CachePolicy | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_cache_policy` |
| Distribution | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_distribution` |
| FieldLevelEncryptionConfig | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_field_level_encryption_config` |
| FieldLevelEncryptionProfile | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_field_level_encryption_profile` |
| Function | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_function` |
| KeyGroup | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_key_group` |
| MonitoringSubscription | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_monitoring_subscription` |
| OriginAccessControl | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_origin_access_control` |
| OriginAccessIdentity | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_origin_access_identity` |
| OriginRequestPolicy | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_origin_request_policy` |
| PublicKey | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_public_key` |
| RealtimeLogConfig | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_realtime_log_config` |
| ResponseHeadersPolicy | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_response_headers_policy` |
| VPCOrigin | `aws_cloudfront.models.v1beta1.cloudfront_awsm_upbound_io_v1beta1_v_p_c_origin` |
