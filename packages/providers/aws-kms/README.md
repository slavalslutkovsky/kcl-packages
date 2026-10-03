# aws-kms

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-kms`.

Source: ghcr.io/crossplane-contrib/provider-aws-kms:v2.6.0 (scope=namespaced; service=kms)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-kms = { path = "<relative path>/packages/providers/aws-kms" }
```

Then import a model:

```python
import aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_alias as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Alias | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_alias` |
| Ciphertext | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_ciphertext` |
| ExternalKey | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_external_key` |
| Grant | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_grant` |
| Key | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_key` |
| ReplicaExternalKey | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_replica_external_key` |
| ReplicaKey | `aws_kms.models.v1beta1.kms_awsm_upbound_io_v1beta1_replica_key` |
