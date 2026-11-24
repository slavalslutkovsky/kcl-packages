# landingzone-gcp

Tier 1 of a `LandingZone` XR (`cloud.example.org/v1alpha1`) on gcp: a
composite of composites. It reads the spec and the tier-0 facts Pulumi wrote
into `spec.foundation`, and composes child XRs, each rendered by its own
`gcp` Composition (`spec.crossplane.compositionSelector.matchLabels.provider: gcp`).
The `landingzone-gcp` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/landingzone-gcp`, then `function-auto-ready`.
See [../README.md](../README.md) for the tier split.

## Validation

`render` and `status` start with `contract.checked(oxr)`
([landingzone-contract](../contract)): every rule runs on every reconcile and the
first broken one fails the render with its message. `spec.provider` must be
`gcp`. Without `spec.foundation` nothing is composed and only status
(`ready: false`) is published.

## Composed resources

Every child: namespace = the XR's, `region`, `deletionPolicy` = `spec.deletionPolicy`,
`tags` = `spec.labels`, the `gcp` composition selector.

| kind | composition-resource-name | name | when | notes |
| --- | --- | --- | --- | --- |
| `Network` | `network-<env>` | `<prefix>-<env>` | always | `cidr` = `env.cidr` (the block); one subnetwork `<prefix>-<env>-<region>` over `env.nodes` with secondary ranges `pods` / `services` when set; `natGateway`, `allowInternalIngress` |
| `NetworkHub` | `hub` | `<prefix>-hub` | always | `topology` = `network.hub.topology` (default `isolated`); spokes below |
| `EncryptionKey` | `key-<env>` | `<prefix>-<env>-cmek` | always | `encrypt-decrypt`, `symmetric`, `rotationDays: 90`; — |
| `KubernetesCluster` | `cluster-<env>` | `<prefix>-<env>` | `env.cluster`, once the env Network is ready and reports a subnet | `network = {id: <VPC selfLink>, subnets: [<first subnetwork selfLink>]}`; `spot` passed through; `nodeCount` = max(1, minNodes), `autoscaling` = {minNodes, maxNodes} |

Hub spokes: `mgmt` (`foundation.network.mgmt.id`, shared) always, plus one
per environment whose Network reports `status.selfLink` (`shared` = `env.shared`).
Spokes and clusters stay composed once composed, with the reference they were
composed against, so a flapping child status never deletes them.

GCP children carry no project: they land in the project of the `gcp` ProviderConfig the child Compositions use. `foundation.containers` is checked by the contract but not read here.

## Status

| field | source |
| --- | --- |
| `ready` | foundation set, hub ready, every env Network ready (and its cluster, when it has one) |
| `provider` | `gcp` |
| `foundation` | `spec.foundation` as given |
| `hub` | NetworkHub `status.hubId` / `status.attachedCount` |
| `environments[]` | `name`, `ready`, `networkId` (`status.selfLink`), `subnetIds` (`status.subnets[].selfLink`), `keyUri`, `clusterName`, `clusterEndpoint` — only what is observed |

## Run

```sh
kcl test                # landingzone_test.k
kcl run main.k          # renders example.gcp + example.foundation.gcp
```
