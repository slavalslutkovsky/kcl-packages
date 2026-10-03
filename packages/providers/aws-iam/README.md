# aws-iam

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed aws-iam`.

Source: ghcr.io/crossplane-contrib/provider-aws-iam:v2.6.0 (scope=namespaced; service=iam)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
aws-iam = { path = "<relative path>/packages/providers/aws-iam" }
```

Then import a model:

```python
import aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_access_key as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| AccessKey | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_access_key` |
| AccountAlias | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_account_alias` |
| AccountPasswordPolicy | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_account_password_policy` |
| Group | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_group` |
| GroupMembership | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_group_membership` |
| GroupPolicyAttachment | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_group_policy_attachment` |
| InstanceProfile | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_instance_profile` |
| OpenIDConnectProvider | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_open_id_connect_provider` |
| Policy | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_policy` |
| Role | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role` |
| RolePolicy | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy` |
| RolePolicyAttachment | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_role_policy_attachment` |
| SAMLProvider | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_s_a_m_l_provider` |
| ServerCertificate | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_server_certificate` |
| ServiceLinkedRole | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_service_linked_role` |
| ServiceSpecificCredential | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_service_specific_credential` |
| SigningCertificate | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_signing_certificate` |
| User | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_user` |
| UserGroupMembership | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_user_group_membership` |
| UserLoginProfile | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_user_login_profile` |
| UserPolicyAttachment | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_user_policy_attachment` |
| UserSSHKey | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_user_ssh_key` |
| VirtualMfaDevice | `aws_iam.models.v1beta1.iam_awsm_upbound_io_v1beta1_virtual_mfa_device` |
