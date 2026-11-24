# landingzone-azure

Tier 1 of a `LandingZone` XR (`cloud.example.org/v1alpha1`) on azure: a
composite of composites. It reads the spec and the tier-0 facts Pulumi wrote
into `spec.foundation`, and composes child XRs, each rendered by its own
`azure` Composition (`spec.crossplane.compositionSelector.matchLabels.provider: azure`).
The `landingzone-azure` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/landingzone-azure`, then `function-auto-ready`.
See [../README.md](../README.md) for the tier split.

## Validation

`render` and `status` start with `contract.checked(oxr)`
([landingzone-contract](../contract)): every rule runs on every reconcile and the
first broken one fails the render with its message. `spec.provider` must be
`azure`. Without `spec.foundation` nothing is composed and only status
(`ready: false`) is published.

## Composed resources

Every child: namespace = the XR's, `region`, `deletionPolicy` = `spec.deletionPolicy`,
`tags` = `spec.labels`, the `azure` composition selector.

| kind | composition-resource-name | name | when | notes |
| --- | --- | --- | --- | --- |
| `Network` | `network-<env>` | `<prefix>-<env>` | always | `cidr` = `env.nodes` only (pods / services are AKS CNI Overlay CIDRs outside the VNet); one subnet `nodes` over `env.nodes`; `resourceGroup` = `foundation.containers[<env>]`; `natGateway`, `allowInternalIngress` |
| `NetworkHub` | `hub` | `<prefix>-hub` | always | `resourceGroup` = `foundation.containers.network`, else `containers.platform`; `hubCidr` = `network.hub.cidr`; `topology` = `network.hub.topology` (default `isolated`); spokes below |
| `EncryptionKey` | `key-<env>` | `<prefix>-<env>-cmek` | always | `encrypt-decrypt`, `symmetric`, `rotationDays: 90`; `resourceGroup` = `foundation.containers[<env>]`, `tenantId` = `organization.tenantId` |
| `KubernetesCluster` | `cluster-<env>` | `<prefix>-<env>` | `env.cluster`, once the env Network is ready and reports a subnet | `network = {subnets: [<first subnet id>]}`; `resourceGroup` = `foundation.containers[<env>]`; no `spot` (the contract rejects it on azure); `nodeCount` = max(1, minNodes), `autoscaling` = {minNodes, maxNodes} |

Hub spokes: `mgmt` (`foundation.network.mgmt.id`, shared) always, plus one
per environment whose Network reports `status.id` (`shared` = `env.shared`).
Spokes and clusters stay composed once composed, with the reference they were
composed against, so a flapping child status never deletes them.

Placement is explicit: every environment child goes into its own resource group from the foundation.

## Status

| field | source |
| --- | --- |
| `ready` | foundation set, hub ready, every env Network ready (and its cluster, when it has one) |
| `provider` | `azure` |
| `foundation` | `spec.foundation` as given |
| `hub` | NetworkHub `status.hubId` / `status.attachedCount` |
| `environments[]` | `name`, `ready`, `networkId` (`status.id`), `subnetIds` (`status.subnets[].id`), `keyUri`, `clusterName`, `clusterEndpoint` — only what is observed |

## Run

```sh
kcl test                # landingzone_test.k
kcl run main.k          # renders example.azure + example.foundation.azure
```
