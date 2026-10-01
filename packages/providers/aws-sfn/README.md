# aws-sfn

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-sfn`.

Source: ghcr.io/crossplane-contrib/provider-aws-sfn:v2.6.0 (scope=namespaced; service=sfn)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-sfn = { path = "<relative path>/packages/providers/aws-sfn" }
```

Then import a model:

```python
import aws_sfn.models.v1beta1.sfn_awsm_upbound_io_v1beta1_activity as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Activity | `aws_sfn.models.v1beta1.sfn_awsm_upbound_io_v1beta1_activity` |
| StateMachine | `aws_sfn.models.v1beta1.sfn_awsm_upbound_io_v1beta1_state_machine` |
