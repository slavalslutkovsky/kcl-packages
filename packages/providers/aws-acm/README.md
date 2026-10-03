# aws-acm

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-acm`.

Source: ghcr.io/crossplane-contrib/provider-aws-acm:v2.6.0 (scope=namespaced; service=acm)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-acm = { path = "<relative path>/packages/providers/aws-acm" }
```

Then import a model:

```python
import aws_acm.models.v1beta1.acm_awsm_upbound_io_v1beta1_certificate as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Certificate | `aws_acm.models.v1beta1.acm_awsm_upbound_io_v1beta1_certificate` |
| CertificateValidation | `aws_acm.models.v1beta1.acm_awsm_upbound_io_v1beta1_certificate_validation` |
