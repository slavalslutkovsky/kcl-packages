# cluster-azure

Azure backend for the `KubernetesCluster` XR (`cloud.example.org/v1alpha1`).
Typed against the `azure-containerservice` schema package
(`packages/providers/azure-containerservice`), it composes a single AKS
`KubernetesCluster`: the default node pool carries the workers, the cluster
runs with a system-assigned identity, and the kubeconfig is published as a
connection secret. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/cluster-azure` through the `cluster-azure`
Composition (label `provider: azure`).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `KubernetesCluster` (`containerservice.azure.m.upbound.io`) `managed` | always | external-name and `dnsPrefix` = XR name; `identity.type: SystemAssigned`; default node pool `default`; connection secret `<xr>-kubeconfig` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` (required) |
| `resourceGroup` | `resourceGroupName` (required) |
| `version` | `kubernetesVersion`, when set |
| `nodeCount` | `defaultNodePool.nodeCount` (default `2`) |
| `autoscaling.min` / `.max` | `autoScalingEnabled: true`, `minCount`, `maxCount` |
| `nodeSize` | `vmSize`: `small` Standard_B2s, `medium` Standard_D2s_v5, `large` Standard_D4s_v5, `xlarge` Standard_D8s_v5 (default `small`) |
| `machineType` | `vmSize`, overriding `nodeSize` |
| `network.subnets[0]` | `defaultNodePool.vnetSubnetId` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `tags` |

Ignored: `network.id` (the subnet pins the VNet). The render fails without
`region` or `resourceGroup`, when `spot` is set (AKS keeps its default node
pool on regular capacity), and when `kubeconfigSecret` or `bootstrap` (onprem
only) is set.

Status written back: `provider: azure`, `ready` (observed `fqdn`), `name` (XR
name), `kubeconfigSecret: <xr>-kubeconfig`, and once observed `endpoint`
(`fqdn`), `version` (`currentKubernetesVersion`, else `kubernetesVersion`),
`id`, `cloud-url` (portal).

## Usage

Without `option("params")`, `main.k` renders a built-in example: `westeurope`,
`example-rg`, everything else defaulted.

```bash
kcl run packages/cloud/cluster/azure

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/cluster/azure \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/cluster/xrd/examples/cluster-azure.yaml)}"
```

`items` holds the managed resource, then the `KubernetesCluster` XR carrying
status.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/cluster-azure.yaml`:

```bash
pnpm exec nx run cluster-azure:render
```

On a cluster: `just install-module cluster`, or `just e2e cluster` end to end.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `cluster.k` | `render(oxr, ocds)`, `status(oxr, ocds)`, `machine_for` |
| `cluster_test.k` | `kcl test` cases |
| `composition.yaml` | `cluster-azure` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run cluster-azure:test     # kcl test
pnpm exec nx run cluster-azure:lint     # kcl lint
pnpm exec nx run cluster-azure:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
