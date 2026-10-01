# workflow-aws

AWS backend for the `Workflow` XR (`cloud.example.org/v1alpha1`), Composition
`workflow-aws` (label `provider: aws`). Typed against the
[aws-sfn](../../../providers/aws-sfn/) and [aws-iam](../../../providers/aws-iam/)
schema packages, it maps the portable workflow onto a Step Functions
`StateMachine` carrying the Amazon States Language definition verbatim, plus
an execution Role unless the XR names one. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/workflow-aws`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `StateMachine` (`sfn.aws.m.upbound.io`) | `managed` | always | external name pinned to the XR name |
| `Role` (`iam.aws.m.upbound.io`) | `role` | `serviceAccount` unset | trusted by `states.amazonaws.com`, **no permissions attached**: attach what the Task states call |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `StateMachine.region` |
| `definition` | `definition` (ASL JSON, verbatim) |
| `serviceAccount` | `roleArn` (existing role); unset → controller-ref to the composed Role |
| `encryptionKmsKeyId` | `encryptionConfiguration` `{type: CUSTOMER_MANAGED_KMS_KEY, kmsKeyId}` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` on StateMachine and Role |

Ignored: `resourceGroup` (Azure-only).

Status written back: `provider: aws`, `name` (the XR name), `ready`
(`atProvider.status == ACTIVE`), `arn` and `id` (state machine ARN),
`cloud-url` (Step Functions console), `revision`, `identity` (role ARN).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` Workflow (single `Succeed` state in `us-east-1`):

```bash
kcl run packages/cloud/workflow/aws
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/workflow/aws -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"Workflow","metadata":{"name":"wf"},"spec":{"region":"eu-west-1","definition":"{\"StartAt\":\"Done\",\"States\":{\"Done\":{\"Type\":\"Succeed\"}}}","serviceAccount":"arn:aws:iam::123456789012:role/wf"}}}'
```

In a cluster (needs docker/kind): `just e2e workflow` publishes the module's
packages to the local registry and applies every example XR;
`just install-module workflow` applies only the XRD and the Compositions,
repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `workflow.k` | `render` (managed resources) and `status` (XR status) |
| `workflow_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run workflow-aws:test     # kcl test
pnpm exec nx run workflow-aws:lint     # kcl lint
pnpm exec nx run workflow-aws:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
