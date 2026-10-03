# azure-authorization

KCL schemas generated from CRDs by `kcl import -m crd` (the
`nx-kcl:import-crd` generator). Generated: do not edit.
Regenerate from its row in `packages/providers/registry.yaml` with `tools/providers.sh seed azure-authorization`.

Source: ghcr.io/crossplane-contrib/provider-azure-authorization:v2.6.0 (scope=namespaced; service=authorization)

## Usage

Depend on it by path from a package's `kcl.mod`:

```toml
[dependencies]
azure-authorization = { path = "<relative path>/packages/providers/azure-authorization" }
```

Then import a model:

```python
import azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_management_group_policy_assignment as model
```

## Kinds

### v1beta1

| kind | import |
| --- | --- |
| ManagementGroupPolicyAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_management_group_policy_assignment` |
| ManagementGroupPolicyExemption | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_management_group_policy_exemption` |
| ManagementLock | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_management_lock` |
| PimActiveRoleAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_pim_active_role_assignment` |
| PimEligibleRoleAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_pim_eligible_role_assignment` |
| PolicyDefinition | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_policy_definition` |
| PolicySetDefinition | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_policy_set_definition` |
| ResourceGroupPolicyAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_resource_group_policy_assignment` |
| ResourceGroupPolicyExemption | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_resource_group_policy_exemption` |
| ResourcePolicyAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_resource_policy_assignment` |
| ResourcePolicyExemption | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_resource_policy_exemption` |
| RoleAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_assignment` |
| RoleDefinition | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_definition` |
| RoleManagementPolicy | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_role_management_policy` |
| SubscriptionPolicyAssignment | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_subscription_policy_assignment` |
| SubscriptionPolicyExemption | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_subscription_policy_exemption` |
| TrustedAccessRoleBinding | `azure_authorization.models.v1beta1.authorization_azurem_upbound_io_v1beta1_trusted_access_role_binding` |
