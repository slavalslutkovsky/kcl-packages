# cluster-gcp

GCP backend for the `KubernetesCluster` XR (`cloud.example.org/v1alpha1`).
Typed against the `gcp-container` schema package
(`packages/providers/gcp-container`), it composes a GKE `Cluster` (default node
pool removed) and a managed `NodePool`. GKE's own `deletionProtection` is off;
lifecycle is governed by `deletionPolicy`. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/cluster-gcp` through the `cluster-gcp`
Composition (label `provider: gcp`).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Cluster` (`container.gcp.m.upbound.io`) `managed` | always | external-name = XR name; `removeDefaultNodePool: true`, `initialNodeCount: 1`, `deletionProtection: false`; connection secret `<xr>-kubeconfig` |
| `NodePool` (`container.gcp.m.upbound.io`) `nodes` | always | external-name `<xr>-nodes`; cluster by `matchControllerRef` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` of `Cluster` and `NodePool` |
| `version` | `Cluster.minMasterVersion`, when set |
| `nodeCount` | `NodePool.nodeCount` (default `2`); with `autoscaling`, `initialNodeCount` instead |
| `autoscaling.min` / `.max` | `NodePool.autoscaling.minNodeCount` / `maxNodeCount` |
| `nodeSize` | `nodeConfig.machineType`: `small` e2-medium, `medium` e2-standard-2, `large` e2-standard-4, `xlarge` e2-standard-8 (default `small`) |
| `machineType` | `nodeConfig.machineType`, overriding `nodeSize` |
| `spot` | `nodeConfig.spot: true` |
| `network.id` | `Cluster.network` |
| `network.subnets[0]` | `Cluster.subnetwork` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `Cluster.resourceLabels` and `nodeConfig.labels` |

Ignored: `resourceGroup`. The render fails when `kubeconfigSecret` or
`bootstrap` (onprem only) is set.

Status written back: `provider: gcp`, `ready` (observed `endpoint`), `name`
(XR name), `kubeconfigSecret: <xr>-kubeconfig`, and once observed `endpoint`,
`version` (`masterVersion`), `id`, `cloud-url` (GKE console, project parsed
from `id`).

## Usage

Without `option("params")`, `main.k` renders a built-in example: `us-central1`,
everything else defaulted.

```bash
kcl run packages/cloud/cluster/gcp

# a real XR: params = {oxr: <XR>, ocds: <observed composed resources>}
kcl run packages/cloud/cluster/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/cluster/xrd/examples/cluster-gcp.yaml)}"
```

`items` holds the managed resources, then the `KubernetesCluster` carrying
status.

Through the real function (needs docker and the `crossplane` CLI), against
`../xrd/examples/cluster-gcp.yaml`:

```bash
pnpm exec nx run cluster-gcp:render
```

On a cluster: `just install-module cluster`, or `just e2e cluster` end to end.

## Layout

| file | content |
| --- | --- |
| `main.k` | Entry point: `option("params")` or the built-in example → `items` |
| `cluster.k` | `render(oxr, ocds)`, `status(oxr, ocds)`, `machine_for` |
| `cluster_test.k` | `kcl test` cases |
| `composition.yaml` | `cluster-gcp` Composition: `function-kcl` then `function-auto-ready` |

## Development

```bash
pnpm exec nx run cluster-gcp:test     # kcl test
pnpm exec nx run cluster-gcp:lint     # kcl lint
pnpm exec nx run cluster-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
