# landingzone

A multi-cloud landing zone (gcp, azure) behind one input/output contract: the
`LandingZone` XR (`cloud.example.org/v1alpha1`, namespaced).

| package | what |
| --- | --- |
| [xrd](xrd) (`landingzone-xrd`) | the XRD — `spec` is the input, `status` the output — and its generated KCL models; [functions.yaml](xrd/functions.yaml), [examples](xrd/examples) |
| [contract](contract) (`landingzone-contract`) | the rules a spec must satisfy (address plan, cross-field and per-cloud requirements), the shared helpers and the example specs |
| [gcp](gcp) (`landingzone-gcp`) | tier-1 Composition logic on GCP |
| [azure](azure) (`landingzone-azure`) | tier-1 Composition logic on Azure |

## Two tiers, one contract

- **Tier 0 — Pulumi** (`@org/landing-zone`, shluviza/infra). Everything the
  control plane itself stands on, so it cannot be composed by a Crossplane
  running on it: the hierarchy (gcp folders and projects / azure management
  groups and resource groups), guardrails (organization policies / Azure
  Policy), the platform keys and registry, the audit archive, the mgmt network
  and the mgmt cluster with Crossplane's keyless identity and the Flux hand-off.
  Before creating anything it runs `kcl run contract/main.k -D specFile=…` to
  validate the spec and take it back with every XRD default applied.
- **Tier 1 — this Composition.** Everything per environment, as child XRs that
  each have their own per-cloud Composition: networks, the hub joining them to
  mgmt, keys and, opt-in, workload clusters.

The same `contract.LandingZone` rules run in both tiers: in Pulumi's preview
and on every reconcile of the XR (`contract.checked(oxr)` is the first line of
`render` and `status`).

## Hand-off

Pulumi creates (or updates) the `LandingZone` XR with the spec it validated and
`spec.foundation` filled from its outputs: scopes, containers (projects /
resource groups), the mgmt network, keys, registry, audit and control-plane
facts. `spec.foundation` is the only thing tier 1 reads from tier 0; until it
is set the Composition composes nothing and publishes `status.ready: false`.
With it, the spec must also satisfy `contract.Composed` (a container for
platform and every environment, the mgmt network id).

`status` is the single output: `provider` and `foundation` (tier 0, echoed
back) plus `hub` and `environments[]` (tier 1, observed from the children), so
one object holds both tiers. Pulumi returns the same shape from its stack.

## Children per cloud

| composition-resource-name | kind | gcp | azure |
| --- | --- | --- | --- |
| `network-<env>` | `Network` `<prefix>-<env>` | VPC: block `env.cidr`, subnetwork over `env.nodes` with `pods` / `services` secondary ranges | VNet over `env.nodes` only (one subnet `nodes`), in `containers[<env>]`; pods / services are AKS overlay CIDRs |
| `hub` | `NetworkHub` `<prefix>-hub` | NCC hub | Virtual hub over `network.hub.cidr`, in `containers.network` or `containers.platform` |
| `key-<env>` | `EncryptionKey` `<prefix>-<env>-cmek` | Cloud KMS key | Key Vault key in `containers[<env>]`, `organization.tenantId` |
| `cluster-<env>` | `KubernetesCluster` `<prefix>-<env>` | GKE in the env subnetwork (spot allowed) | AKS in the env subnet, `containers[<env>]` |

Hub spokes are `mgmt` (shared) plus every environment whose network has
reported its id; a cluster waits for its network to be ready with a subnet.
Both stay composed once composed. The Composition is chosen by
`spec.crossplane.compositionSelector.matchLabels.provider`, which must match
`spec.provider`.
