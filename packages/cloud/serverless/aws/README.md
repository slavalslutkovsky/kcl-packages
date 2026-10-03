# serverless-aws

AWS backend for the `ServerlessApp` XR (`cloud.example.org/v1alpha1`),
Composition `serverless-aws` (label `provider: aws`). Typed against the
[aws-lambda](../../../providers/aws-lambda/) and
[aws-iam](../../../providers/aws-iam/) schema packages, it maps the portable
app onto a container-image Lambda Function fronted by a Function URL, plus an
execution Role unless the XR names one. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/serverless-aws`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Function` (`lambda.aws.m.upbound.io`) | `managed` | always | `packageType: Image`; role by `spec.serviceAccount` or controller-ref to the composed Role |
| `Role` (`iam.aws.m.upbound.io`) | `role` | `serviceAccount` unset | trusted by `lambda.amazonaws.com`; no region (IAM is global) |
| `RolePolicyAttachment` (`iam.aws.m.upbound.io`) | `role-policy` | `serviceAccount` unset | attaches `AWSLambdaBasicExecutionRole` (CloudWatch Logs) |
| `FunctionURL` (`lambda.aws.m.upbound.io`) | `url` | always | `authorizationType` `NONE` if public, else `AWS_IAM` |
| `Permission` (`lambda.aws.m.upbound.io`) | `url-permission` | `public` (default `true`) | `lambda:InvokeFunctionUrl` for principal `*`; `NONE` auth alone does not allow anonymous calls |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `image` | `Function.imageUri` |
| `region` | `region` of Function, FunctionURL, Permission |
| `memoryMb` | `memorySize`, default 512, clamped to 10240 |
| `timeoutSeconds` | `timeout`, default 60, clamped to 900 |
| `maxInstances` | `reservedConcurrentExecutions`; unset keeps the unreserved pool |
| `env` | `environment.variables` |
| `public` | FunctionURL auth type and the public Permission; default `true` |
| `serviceAccount` | existing execution role ARN; skips Role + attachment |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | `tags` on Function and Role |

Ignored: `port` (Lambda images speak the Runtime API), `cpu` (proportional to
memory), `minInstances` (would need provisioned concurrency).

Status written back: `provider: aws`, `ready` (Function URL observed), `url`
(trailing slash dropped), `host`, `arn`, `id`, and `cloud-url` (Lambda console).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` ServerlessApp (ECR image in `us-east-1`, public):

```bash
kcl run packages/cloud/serverless/aws
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/serverless/aws -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"ServerlessApp","metadata":{"name":"hello"},"spec":{"image":"123456789012.dkr.ecr.eu-west-1.amazonaws.com/hello:1","region":"eu-west-1","public":false}}}'
```

In a cluster (needs docker/kind): `just e2e serverless` publishes the module's
packages to the local registry and applies every example XR;
`just install-module serverless` applies only the XRD and the Compositions,
repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `serverless.k` | `render` (managed resources) and `status` (XR status) |
| `serverless_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run serverless-aws:test     # kcl test
pnpm exec nx run serverless-aws:lint     # kcl lint
pnpm exec nx run serverless-aws:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
