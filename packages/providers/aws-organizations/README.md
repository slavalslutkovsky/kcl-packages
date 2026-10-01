# aws-organizations

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-organizations`.

Source: ghcr.io/crossplane-contrib/provider-aws-organizations:v2.6.0 (scope=namespaced; service=organizations)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-organizations = { path = "<relative path>/packages/providers/aws-organizations" }
```

Then import a model:

```python
import aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_account as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| Account | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_account` |
| DelegatedAdministrator | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_delegated_administrator` |
| Organization | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_organization` |
| OrganizationalUnit | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_organizational_unit` |
| Policy | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_policy` |
| PolicyAttachment | `aws_organizations.models.v1beta1.organizations_awsm_upbound_io_v1beta1_policy_attachment` |
