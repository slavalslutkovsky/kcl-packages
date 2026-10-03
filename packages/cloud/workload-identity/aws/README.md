# workload-identity-aws

AWS backend for the `WorkloadIdentity` XR (`cloud.example.org/v1alpha1`):
IRSA. Typed against [`aws-iam`](../../../providers/aws-iam) plus core
Kubernetes (`k8s`), it composes an IAM Role whose trust policy allows
`sts:AssumeRoleWithWebIdentity` only from the cluster's OIDC provider and only
for the subject `system:serviceaccount:<ns>:<name>`, one RolePolicyAttachment
per `accessPolicies` entry, and the Kubernetes ServiceAccount annotated with
the role ARN the AWS SDKs read. The `workload-identity-aws` Composition runs it
through `function-kcl` from `oci://docker.io/yurikrupnik/workload-identity-aws`,
followed by `function-auto-ready`.

The ARN exists only once the role is observed, so the annotated ServiceAccount
is composed on the second reconcile, from the observed composed resources
(`ocds`), unless `identity.existing` supplies it.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Role` (`iam.aws.m.upbound.io`) | `identity.existing` unset | resource name `managed`; external name = `identity.name`, else the XR name |
| `RolePolicyAttachment` (`iam.aws.m.upbound.io`) | one per `accessPolicies` entry | resource names `grant-<i>`; bound to the role by controller reference |
| `ServiceAccount` (`v1`) | `serviceAccount.create` (default `true`) and the role ARN known | resource name `kubernetes-serviceaccount`; annotation `eks.amazonaws.com/role-arn` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `cluster.oidcIssuer` | trust `Principal.Federated`, and the `<host>` of the `<host>:sub` / `<host>:aud` condition keys; required |
| `cluster.audiences` | `<host>:aud`; defaults to `[sts.amazonaws.com]` |
| `serviceAccount.name` / `namespace` | trust subject and the composed ServiceAccount; namespace defaults to the XR's |
| `serviceAccount.create` | compose the ServiceAccount; with `true` the namespace must equal the XR's |
| `identity.name` | IAM role name |
| `identity.existing` | role ARN to bind instead of creating a role; `accessPolicies` must then be empty |
| `accessPolicies[].role` | `policyArn`; a value not starting with `arn:` becomes `arn:aws:iam::aws:policy/<role>` |
| `displayName` | `Role.description` |
| `tags` | `Role.tags` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on the managed resources; otherwise the schema default `["*"]` |

The render fails on `region`, `resourceGroup`, `cluster.project`,
`cluster.workloadIdentityPool`, `accessPolicies[].scope`,
`accessPolicies[].condition` and any `scopeType` other than `project`.

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once the role ARN is known |
| `name` | observed role id, else `identity.name`, else the XR name |
| `serviceAccount`, `subject` | `<ns>/<name>` and `system:serviceaccount:<ns>:<name>` |
| `cloud-url` | IAM console page of the role |
| `arn`, `principal`, `annotation` | role ARN, once known |
| `id` | observed role id |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`; add `params.ocds` with an observed `managed`
role to see the second pass with the ServiceAccount:

```bash
kcl run packages/cloud/workload-identity/aws

kcl run packages/cloud/workload-identity/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/workload-identity/xrd/examples/workload-identity-aws.yaml)"

kcl run packages/cloud/workload-identity/aws \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"managed": {"Resource": {"status": {"atProvider": {"arn": "arn:aws:iam::123456789012:role/external-secrets"}}}}}}' packages/cloud/workload-identity/xrd/examples/workload-identity-aws.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/workload-identity-aws.yaml`](../xrd/examples/workload-identity-aws.yaml):

```bash
pnpm exec nx run workload-identity-aws:render     # or: just render workload-identity-aws
```

On a Kind cluster: `just e2e workload-identity` (publish, install, apply every
example), `just install-module workload-identity` (XRD + Compositions only) or
`just workload workload-identity aws` (module, providers, and this backend's
example). `just seed-iam-providers` regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `workload_identity.k` | `policy_arn`, `oidc_host`, `ksa_subject`, `assume_policy`, `render` and `status` |
| `workload_identity_test.k` | `kcl test` cases |
| `composition.yaml` | `workload-identity-aws` Composition |

## Development

```bash
pnpm exec nx run workload-identity-aws:test     # kcl test
pnpm exec nx run workload-identity-aws:lint     # kcl lint
pnpm exec nx run workload-identity-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
