# iam-azure

Azure backend for the `Identity` XR (`cloud.example.org/v1alpha1`). Typed
against [`azure-managedidentity`](../../../providers/azure-managedidentity) and
[`azure-authorization`](../../../providers/azure-authorization), it composes a
User Assigned Identity, one FederatedIdentityCredential per
`trust.federated` subject and one RoleAssignment per `accessPolicies` entry.
The `iam-azure` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/iam-azure`, followed by `function-auto-ready`.

A RoleAssignment needs the identity's principal (object) id, which exists only
once the identity is observed, so grants are composed on the second reconcile,
from the observed composed resources (`ocds`).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `UserAssignedIdentity` (`managedidentity.azure.m.upbound.io`) | always | resource name `managed`; `name` = XR name |
| `FederatedIdentityCredential` (`managedidentity.azure.m.upbound.io`) | one per `trust.federated.subjects` entry | resource names `federation-<i>`; external name `<xr>-federation-<i>`; parent bound by controller reference |
| `RoleAssignment` (`authorization.azure.m.upbound.io`) | one per `accessPolicies` entry, once `principalId` is observed | resource names `grant-<i>`; `principalType: ServicePrincipal`, `skipServicePrincipalAadCheck: true` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | identity `location`; required, the render fails without it |
| `resourceGroup` | `resourceGroupName` of the identity and its credentials; required |
| `trust.federated.issuer` / `subjects` | credential `issuer` / `subject` |
| `trust.federated.audiences` | credential `audience`; defaults to `[api://AzureADTokenExchange]` |
| `accessPolicies[].role` | `roleDefinitionId` when it starts with `/`, else `roleDefinitionName` |
| `accessPolicies[].scope` | `scope`; required on every entry |
| `accessPolicies[].condition.expression` | `condition`, with `conditionVersion: "2.0"` |
| `tags` | identity `tags` |
| `displayName` | identity tag `display-name` (identities have no description field) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; otherwise the schema default `["*"]` |

The render fails on `inlinePolicy`, `permissionsBoundary`, `trust.services`
(AWS-only) and `trust.identities` (not expressible for a User Assigned
Identity; use `trust.federated`).

Status written back to the XR, from the observed `managed` identity:

| status | value |
| --- | --- |
| `provider` | `azure` |
| `ready` | `true` once `atProvider.principalId` is set |
| `name` | XR name |
| `principalId`, `principal` | observed principal id |
| `clientId`, `tenantId` | observed, when set |
| `id`, `cloud-url` | ARM id and its Azure portal page |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`; add `params.ocds` with an observed `managed`
identity to see the second pass with the RoleAssignments:

```bash
kcl run packages/cloud/iam/azure

kcl run packages/cloud/iam/azure \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/iam/xrd/examples/iam-azure.yaml)"

kcl run packages/cloud/iam/azure \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"managed": {"Resource": {"status": {"atProvider": {"principalId": "00000000-0000-0000-0000-000000000000"}}}}}}' packages/cloud/iam/xrd/examples/iam-azure.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/iam-azure.yaml`](../xrd/examples/iam-azure.yaml):

```bash
pnpm exec nx run iam-azure:render     # or: just render iam-azure
```

On a Kind cluster: `just e2e iam` (publish, install, apply every example),
`just install-module iam` (XRD + Compositions only) or `just workload iam azure`
(module, providers, and this backend's example). `just seed-iam-providers`
regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `iam.k` | `render` (identity, credentials, assignments) and `status` |
| `iam_test.k` | `kcl test` cases |
| `composition.yaml` | `iam-azure` Composition |

## Development

```bash
pnpm exec nx run iam-azure:test     # kcl test
pnpm exec nx run iam-azure:lint     # kcl lint
pnpm exec nx run iam-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
