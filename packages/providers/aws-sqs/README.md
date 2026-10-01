# aws-sqs

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-sqs`.

Source: ghcr.io/crossplane-contrib/provider-aws-sqs:v2.6.0 (scope=namespaced; service=sqs)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-sqs = { path = "<relative path>/packages/providers/aws-sqs" }
```

Then import a model:

```python
import aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Queue | `aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue` |
| QueuePolicy | `aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue_policy` |
| QueueRedriveAllowPolicy | `aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue_redrive_allow_policy` |
| QueueRedrivePolicy | `aws_sqs.models.v1beta1.sqs_awsm_upbound_io_v1beta1_queue_redrive_policy` |
