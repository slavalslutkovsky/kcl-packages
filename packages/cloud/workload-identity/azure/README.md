# workload-identity-azure

Azure backend for the `WorkloadIdentity` XR (`cloud.example.org/v1alpha1`):
Azure Workload Identity. Typed against
[`azure-managedidentity`](../../../providers/azure-managedidentity),
[`azure-authorization`](../../../providers/azure-authorization) and core
Kubernetes (`k8s`), it composes a User Assigned Identity, a
FederatedIdentityCredential trusting `system:serviceaccount:<ns>:<name>` from
the cluster's OIDC issuer, one RoleAssignment per `accessPolicies` entry, and
the Kubernetes ServiceAccount annotated with the identity's client id. The
`workload-identity-azure` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/workload-identity-azure`, followed by
`function-auto-ready`.

RoleAssignments need the identity's principal id and the ServiceAccount needs
its client id; both exist only once the identity is observed, so they are
composed on the second reconcile, from the observed composed resources
(`ocds`).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `UserAssignedIdentity` (`managedidentity.azure.m.upbound.io`) | always | resource name `managed`; `name` = `identity.name`, else the XR name |
| `FederatedIdentityCredential` (`managedidentity.azure.m.upbound.io`) | always | resource name `binding`; external name `<identity>-<ns>-<ksa>`; parent bound by controller reference |
| `RoleAssignment` (`authorization.azure.m.upbound.io`) | one per `accessPolicies` entry, once `principalId` is observed | resource names `grant-<i>`; `principalType: ServicePrincipal`, `skipServicePrincipalAadCheck: true` |
| `ServiceAccount` (`v1`) | `serviceAccount.create` (default `true`) and `clientId` observed | resource name `kubernetes-serviceaccount`; annotation `azure.workload.identity/client-id`, label `azure.workload.identity/use: "true"` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `region` | identity `location`; required |
| `resourceGroup` | `resourceGroupName` of the identity and the credential; required |
| `cluster.oidcIssuer` | credential `issuer`; required |
| `cluster.audiences` | credential `audience`; defaults to `[api://AzureADTokenExchange]` |
| `serviceAccount.name` / `namespace` | credential `subject` and the composed ServiceAccount; namespace defaults to the XR's |
| `serviceAccount.create` | compose the ServiceAccount; with `true` the namespace must equal the XR's |
| `identity.name` | identity name |
| `accessPolicies[].role` | `roleDefinitionId` when it starts with `/`, else `roleDefinitionName` |
| `accessPolicies[].scope` | `scope`; required on every entry |
| `accessPolicies[].condition.expression` | `condition`, with `conditionVersion: "2.0"` |
| `tags` | identity `tags` |
| `displayName` | identity tag `display-name` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on the managed resources; otherwise the schema default `["*"]` |

The render fails on `cluster.project`, `cluster.workloadIdentityPool`,
`identity.existing` (a federated credential needs the identity as its parent)
and any `scopeType` other than `project`.

Status written back to the XR, from the observed `managed` identity:

| status | value |
| --- | --- |
| `provider` | `azure` |
| `ready` | `true` once `atProvider.clientId` is set |
| `name` | `identity.name`, else the XR name |
| `serviceAccount`, `subject` | `<ns>/<name>` and `system:serviceaccount:<ns>:<name>` |
| `clientId`, `annotation` | observed client id |
| `principalId`, `principal` | observed principal id |
| `tenantId` | observed tenant id |
| `id`, `cloud-url` | ARM id and its Azure portal page |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`; add `params.ocds` with an observed `managed`
identity to see the second pass with the RoleAssignment and ServiceAccount:

```bash
kcl run packages/cloud/workload-identity/azure

kcl run packages/cloud/workload-identity/azure \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/workload-identity/xrd/examples/workload-identity-azure.yaml)"

kcl run packages/cloud/workload-identity/azure \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"managed": {"Resource": {"status": {"atProvider": {"principalId": "00000000-0000-0000-0000-000000000000", "clientId": "11111111-1111-1111-1111-111111111111"}}}}}}' packages/cloud/workload-identity/xrd/examples/workload-identity-azure.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/workload-identity-azure.yaml`](../xrd/examples/workload-identity-azure.yaml):

```bash
pnpm exec nx run workload-identity-azure:render     # or: just render workload-identity-azure
```

On a Kind cluster: `just e2e workload-identity` (publish, install, apply every
example), `just install-module workload-identity` (XRD + Compositions only) or
`just workload workload-identity azure` (module, providers, and this backend's
example). `just seed-iam-providers` regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `workload_identity.k` | `ksa_subject`, `render` and `status` |
| `workload_identity_test.k` | `kcl test` cases |
| `composition.yaml` | `workload-identity-azure` Composition |

## Development

```bash
pnpm exec nx run workload-identity-azure:test     # kcl test
pnpm exec nx run workload-identity-azure:lint     # kcl lint
pnpm exec nx run workload-identity-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
