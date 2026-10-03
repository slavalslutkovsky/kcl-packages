# iam-aws

AWS backend for the `Identity` XR (`cloud.example.org/v1alpha1`). Typed against
[`aws-iam`](../../../providers/aws-iam), it composes an IAM Role: `spec.trust`
becomes the assume-role (trust) policy, each `accessPolicies` entry a
RolePolicyAttachment, `inlinePolicy` a RolePolicy and `permissionsBoundary` the
role's boundary. The `iam-aws` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/iam-aws`, followed by `function-auto-ready`.

## Composed resources

All kinds are `iam.aws.m.upbound.io/v1beta1`; children bind to the role by
controller reference.

| resource | when | notes |
| --- | --- | --- |
| `Role` | always | resource name `managed`; external name = XR name, so the role ARN is predictable |
| `RolePolicyAttachment` | one per `accessPolicies` entry | resource names `grant-<i>` |
| `RolePolicy` | `spec.inlinePolicy` set | resource name `inline-policy` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `trust.services` | `Allow sts:AssumeRole` for those service principals |
| `trust.identities` | `Allow sts:AssumeRole` for those AWS principal ARNs |
| `trust.federated` | `Allow sts:AssumeRoleWithWebIdentity` from `issuer`, conditioned on `<host>:sub` = `subjects` and, when set, `<host>:aud` = `audiences`; `<host>` is the issuer after `oidc-provider/` or without `https://` |
| `accessPolicies[].role` | `policyArn`; a value not starting with `arn:` becomes `arn:aws:iam::aws:policy/<role>` |
| `inlinePolicy` | `RolePolicy.policy` |
| `permissionsBoundary` | `Role.permissionsBoundary` |
| `displayName` | `Role.description` |
| `tags` | `Role.tags` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every resource; otherwise the schema default `["*"]` |

The render fails when `trust` allows no principal at all (AWS requires a trust
policy), and when any `accessPolicies[]` entry sets `scope` or `condition`,
which a policy attachment cannot express; put those in `inlinePolicy`.
`region` and `resourceGroup` are not read.

Status written back to the XR, from the observed `managed` role:

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once `atProvider.arn` is set |
| `name` | observed role id, else the XR name |
| `cloud-url` | IAM console page of the role |
| `arn`, `principal` | role ARN, once observed |
| `id` | observed role id |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`:

```bash
kcl run packages/cloud/iam/aws

kcl run packages/cloud/iam/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/iam/xrd/examples/iam-aws.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/iam-aws.yaml`](../xrd/examples/iam-aws.yaml):

```bash
pnpm exec nx run iam-aws:render     # or: just render iam-aws
```

On a Kind cluster: `just e2e iam` (publish, install, apply every example),
`just install-module iam` (XRD + Compositions only) or `just workload iam aws`
(module, providers, and this backend's example). `just seed-iam-providers`
regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `iam.k` | `policy_arn`, `oidc_host`, `assume_policy`, `render` and `status` |
| `iam_test.k` | `kcl test` cases |
| `composition.yaml` | `iam-aws` Composition |

## Development

```bash
pnpm exec nx run iam-aws:test     # kcl test
pnpm exec nx run iam-aws:lint     # kcl lint
pnpm exec nx run iam-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
