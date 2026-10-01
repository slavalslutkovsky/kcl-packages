# aws-codebuild

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-codebuild`.

Source: ghcr.io/crossplane-contrib/provider-aws-codebuild:v2.6.0 (scope=namespaced; service=codebuild)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-codebuild = { path = "<relative path>/packages/providers/aws-codebuild" }
```

Then import a model:

```python
import aws_codebuild.models.v1beta1.codebuild_awsm_upbound_io_v1beta1_project as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Project | `aws_codebuild.models.v1beta1.codebuild_awsm_upbound_io_v1beta1_project` |
| ReportGroup | `aws_codebuild.models.v1beta1.codebuild_awsm_upbound_io_v1beta1_report_group` |
| SourceCredential | `aws_codebuild.models.v1beta1.codebuild_awsm_upbound_io_v1beta1_source_credential` |
| Webhook | `aws_codebuild.models.v1beta1.codebuild_awsm_upbound_io_v1beta1_webhook` |
