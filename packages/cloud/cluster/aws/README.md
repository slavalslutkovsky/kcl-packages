# cluster-aws

AWS backend for the `KubernetesCluster` XR (`cloud.example.org/v1alpha1`).
Typed against the `aws-eks` and `aws-iam` schema packages
(`packages/providers/aws-eks`, `packages/providers/aws-iam`), it composes an EKS
`Cluster` and a managed `NodeGroup`, the two IAM roles EKS needs (control plane
and node, each with its AWS-managed policies), and a `ClusterAuth` that
publishes the kubeconfig. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/cluster-aws` through the `cluster-aws`
Composition (label `provider: aws`).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Role` (`iam.aws.m.upbound.io`) `cluster-role` | always | external-name `<xr>-cluster`, trust `eks.amazonaws.com`, label `role: cluster` |
| `RolePolicyAttachment` (`iam.aws.m.upbound.io`) `cluster-policy-0` | always | `AmazonEKSClusterPolicy` |
| `Role` (`iam.aws.m.upbound.io`) `node-role` | always | external-name `<xr>-node`, trust `ec2.amazonaws.com`, label `role: node` |
| `RolePolicyAttachment` (`iam.aws.m.upbound.io`) `node-policy-0..2` | always | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |
| `Cluster` (`eks.aws.m.upbound.io`) `managed` | always | external-name = XR name; role ARN by selector on `role: cluster`; `vpcConfig.subnetIds` |
| `NodeGroup` (`eks.aws.m.upbound.io`) `nodes` | always | external-name `<xr>-nodes`; node role by selector on `role: node` |
| `ClusterAuth` (`eks.aws.m.upbound.io`) `auth` | always | connection secret `<xr>-kubeconfig` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.region` on `Cluster`, `NodeGroup`, `ClusterAuth` |
| `version` | `Cluster.version` and `NodeGroup.version`, when set |
| `nodeCount` | `scalingConfig.desiredSize` (default `2`); also min/max without `autoscaling` |
| `autoscaling.min` / `.max` | `scalingConfig.minSize` / `maxSize` |
| `nodeSize` | `instanceTypes`: `small` t3.medium, `medium` m5.large, `large` m5.xlarge, `xlarge` m5.2xlarge (default `small`) |
| `machineType` | `instanceTypes`, overriding `nodeSize` |
| `spot` | `capacityType: SPOT` |
| `network.subnets` | `vpcConfig.subnetIds` and `NodeGroup.subnetIds` (required) |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` on roles, `Cluster`, `NodeGroup` |

Ignored: `network.id` (subnets pin the VPC), `resourceGroup`. The render fails
without `network.subnets` and when `kubeconfigSecret` or `bootstrap` (onprem
only) is set.

Status written back: `provider: aws`, `ready` (observed `endpoint`), `name`
(observed `id`, else the XR name), `kubeconfigSecret: <xr>-kubeconfig`,
`cloud-url` (EKS console), and once observed `endpoint`, `version`, `id` (ARN).

## Usage

Without `option("params")`, `main.k` renders a built-in example: `us-east-1`,
one subnet, everything else defaulted.

```bash
kcl run packages/cloud/cluster/aws

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/cluster/aws \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/cluster/xrd/examples/cluster-aws.yaml)}"
```

`items` holds the managed resources, then the `KubernetesCluster` carrying
status.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/cluster-aws.yaml`:

```bash
pnpm exec nx run cluster-aws:render
```

On a cluster: `just install-module cluster`, or `just e2e cluster` end to end.
Install both `provider-aws-eks` and `provider-aws-iam` from
[`../xrd/providers.yaml`](../xrd/providers.yaml).

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `cluster.k` | `render(oxr, ocds)`, `status(oxr, ocds)`, `machine_for`, `service_trust` |
| `cluster_test.k` | Roles, cluster, node group, sizing, autoscaling/spot, auth, deletion policy, status |
| `composition.yaml` | `cluster-aws` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run cluster-aws:test     # kcl test
pnpm exec nx run cluster-aws:lint     # kcl lint
pnpm exec nx run cluster-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
