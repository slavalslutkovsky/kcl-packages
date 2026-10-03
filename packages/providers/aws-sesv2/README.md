# aws-sesv2

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-sesv2`.

Source: ghcr.io/crossplane-contrib/provider-aws-sesv2:v2.6.0 (scope=namespaced; service=sesv2)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-sesv2 = { path = "<relative path>/packages/providers/aws-sesv2" }
```

Then import a model:

```python
import aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_configuration_set as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ConfigurationSet | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_configuration_set` |
| ConfigurationSetEventDestination | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_configuration_set_event_destination` |
| DedicatedIPPool | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_dedicated_ip_pool` |
| EmailIdentity | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_email_identity` |
| EmailIdentityFeedbackAttributes | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_email_identity_feedback_attributes` |
| EmailIdentityMailFromAttributes | `aws_sesv2.models.v1beta1.sesv2_awsm_upbound_io_v1beta1_email_identity_mail_from_attributes` |
