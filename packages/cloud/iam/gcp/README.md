# iam-gcp

GCP backend for the `Identity` XR (`cloud.example.org/v1alpha1`). Typed against
[`gcp-cloudplatform`](../../../providers/gcp-cloudplatform), it composes a
Service Account, one ServiceAccountIAMMember granting
`roles/iam.serviceAccountTokenCreator` per `trust.identities` entry, and one
ProjectIAMMember per `accessPolicies` entry. The `iam-gcp` Composition runs it
through `function-kcl` from `oci://docker.io/yurikrupnik/iam-gcp`, followed by
`function-auto-ready`.

A grant's member string (`serviceAccount:<email>`) exists only once the
service account is observed, so grants are composed on the second reconcile,
from the observed composed resources (`ocds`).

## Composed resources

All kinds are `cloudplatform.gcp.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `ServiceAccount` | always | resource name `managed`; external name (accountId) = XR name: 6-30 chars, lowercase letters, digits, hyphens |
| `ServiceAccountIAMMember` | one per `trust.identities` entry | resource names `trust-<i>`; `role: roles/iam.serviceAccountTokenCreator`; bound to the service account by controller reference |
| `ProjectIAMMember` | one per `accessPolicies` entry, once the service account's `member` is observed | resource names `grant-<i>` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `displayName` | `ServiceAccount.displayName`; defaults to the XR name |
| `trust.identities` | `ServiceAccountIAMMember.member`, any IAM member (`user:…`, `principal://…`, `serviceAccount:…`) |
| `accessPolicies[].role` | `ProjectIAMMember.role` |
| `accessPolicies[].scope` | `ProjectIAMMember.project`; omitted → the ProviderConfig project |
| `accessPolicies[].condition` | IAM `condition`; `title` defaults to `<xr>-grant-<i>` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; otherwise the schema default `["*"]` |

The render fails on `inlinePolicy`, `permissionsBoundary`, `trust.services`
(AWS-only) and `trust.federated` (pass workload-identity members through
`trust.identities` instead). `region`, `resourceGroup` and `tags` are not read.

Status written back to the XR, from the observed `managed` service account:

| status | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | `true` once `atProvider.email` is set |
| `name` | XR name |
| `email`, `principal` | observed e-mail and `member` (else `serviceAccount:<email>`) |
| `id` | observed id |
| `cloud-url` | service-account console page, once `uniqueId` and `project` are observed |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`; add `params.ocds` with an observed `managed`
service account to see the second pass with the ProjectIAMMembers:

```bash
kcl run packages/cloud/iam/gcp

kcl run packages/cloud/iam/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/iam/xrd/examples/iam-gcp.yaml)"

kcl run packages/cloud/iam/gcp \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"managed": {"Resource": {"status": {"atProvider": {"email": "ci-deployer@my-project.iam.gserviceaccount.com", "member": "serviceAccount:ci-deployer@my-project.iam.gserviceaccount.com"}}}}}}' packages/cloud/iam/xrd/examples/iam-gcp.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/iam-gcp.yaml`](../xrd/examples/iam-gcp.yaml):

```bash
pnpm exec nx run iam-gcp:render     # or: just render iam-gcp
```

On a Kind cluster: `just e2e iam` (publish, install, apply every example),
`just install-module iam` (XRD + Compositions only) or `just workload iam gcp`
(module, providers, and this backend's example). `just seed-iam-providers`
regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `iam.k` | `render` (service account, trust members, grants) and `status` |
| `iam_test.k` | `kcl test` cases |
| `composition.yaml` | `iam-gcp` Composition |

## Development

```bash
pnpm exec nx run iam-gcp:test     # kcl test
pnpm exec nx run iam-gcp:lint     # kcl lint
pnpm exec nx run iam-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
