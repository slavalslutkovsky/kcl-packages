# mgmt-gcp

GCP backend for the `Mgmt` XR (`cloud.example.org/v1alpha1`): the infra repo's
`mgmt` Pulumi stack (`apps/mgmt/index.ts`, with the `gcp-gke`, `gcp-postgres`
and `gcp-apis` components) as Crossplane managed resources. The `mgmt-gcp`
Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/mgmt-gcp`, followed by `function-auto-ready`.

[`packages/pulumi-mgmt`](../../../pulumi-mgmt) renders the same stack as a
Pulumi spec; this package is its Crossplane counterpart. Every GCP name matches
the stack's (`<prefix>-mgmt`, `gke-nodes`, cluster `mgmt`, pools `default` and
`ci`, repository `ci`, bucket `<project>-nx-cache`, zone `<domain with dashes>`,
address `main-gateway`, secret `flux-github-app`), and those resources carry it
as `crossplane.io/external-name`, so an XR adopts what the stack created
instead of creating a second copy.

## Inputs from other stacks

The Pulumi stack reads three StackReferences. Here they are spec fields:

| Pulumi | XR field | filled from |
| --- | --- | --- |
| `organization` `*FolderId` | `folders.{platform,dev,staging,network,prod}` | Organization XR `status.folders[].folderId` |
| `network` `networkHosts.mgmt` | `network.{hostProject,network,subnetwork,podsRange,servicesRange}` | Network XR `status.selfLink`, `status.subnets[].selfLink` ([network-gcp-gke.yaml](../../network/xrd/examples/network-gcp-gke.yaml)) |
| `network` `networkHosts.dev` | `devNetwork.{hostProject,subnetwork}` | same |
| `security` key ids | `keys.{gkeSecrets,cloudsql,openbaoUnseal}` | Kms XR status |

Stack config maps one to one: `gcp:region` → `region`, `org:prefix` →
`prefix`, `org:billingAccount` → `billingAccount`, `org:orgDomain` → `domain`,
`mgmt:zone` → `zone`, `mgmt:{nodeMachineType,minNodesPerZone,maxNodesPerZone,ciMachineType,ciMaxNodesPerZone}`
→ `cluster.*`, `mgmt:postgres` → `postgres.enabled`, `mgmt:postgresTier` →
`postgres.tier`, `mgmt:{adminGroup,developerGroup}` → `groups.*`,
`mgmt:{crossplaneKsa,esoKsa}` → `serviceAccounts.*`.

## Composed resources

All kinds are namespaced `*.gcp.m.upbound.io/v1beta1`.

| composition-resource-name | kind | Pulumi |
| --- | --- | --- |
| `project` | `Project` | `mgmt` |
| `api-<api>` | `ProjectService` × 25 (+ `additionalApis`) | `mgmt-apis` |
| `attachment` | `SharedVPCServiceProject` | `mgmt-on-net-mgmt` |
| `subnet-network-user-{gke,apis}-agent` | `SubnetworkIAMMember` | same |
| `host-service-agent-user`, `host-firewall-admin` | `ProjectIAMMember` (host) | same |
| `gke-agent-uses-gke-secrets`, `cloudsql-agent-uses-cloudsql` | `CryptoKeyIAMMember` | same |
| `sa-<id>` | `ServiceAccount` × 7 | `nodeSa`, `crossplane`, ... |
| `crossplane-{dev,staging,network,prod}-<role>` | `FolderIAMMember` | same; only for folders given |
| `<id>-<role>` | `ProjectIAMMember` | gke-nodes, crossplane(-prod) quota, grafana |
| `openbao-<role>` | `CryptoKeyIAMMember` | same; with `keys.openbaoUnseal` |
| `crossplane-impersonates-crossplane-prod`, `<id>-workload-identity` | `ServiceAccountIAMMember` | same |
| `crossplane-net-dev-network-user` | `SubnetworkIAMMember` | same; with `devNetwork` |
| `binary-authorization` | binaryauthorization `Policy` | `mgmt` |
| `gke`, `node-pool-{default,ci}` | `Cluster`, `NodePool` | `GkeCluster` `mgmt` |
| `cloud-sql`, `db-<name>`, `db-<name>-user` | `DatabaseInstance`, `Database`, `User` | `PostgresInstance`, `PostgresDatabase` |
| `ci-repo`, `ci-{ci-builder-writer,gke-nodes-reader}` | `RegistryRepository`, `RegistryRepositoryIAMMember` | same |
| `nx-cache-bucket`, `nx-cache-<role>` | `Bucket`, `BucketIAMMember` | same |
| `admins-container-admin`, `developers-cluster-viewer` | `ProjectIAMMember` | same |
| `dns-zone`, `gateway-ip`, `dns-<id>`, `dns-wildcard`, `cert-manager-dns` | `ManagedZone`, `Address`, `RecordSet`, `ManagedZoneIAMMember` | same |
| `github-app-secret`, `flux-github-app-admins` | secretmanager `Secret`, `SecretIAMMember` | same |

The cluster matches `GkeCluster`: private nodes, DNS endpoint only (IP
endpoints off), Workload Identity, CMEK Secrets encryption, shielded COS nodes,
REGULAR channel with the Fri/Sat maintenance window, Gateway API, cost
management, Managed Prometheus, Binary Authorization with the project policy,
and registration to the project's own GKE fleet (`fleet.project` = the mgmt
project; `gkehub.googleapis.com` is in the API list).
The deleted default pool's `nodeConfig` goes in `spec.initProvider`, the
Crossplane form of `ignoreChanges: ['nodeConfig']`.

## Ordering

A Composition has no `dependsOn`. A resource whose prerequisite is not
observed yet stays out of the desired state, and `status.pending` lists it:

| held back | until |
| --- | --- |
| service agent grants, nx-cache and cert-manager principals | `project` reports `number` (the agents' emails and the Workload Identity pool's principal embed it) |
| `gke`, `node-pool-*` | `attachment`, both subnet grants, both host grants, the key grant, `api-container-googleapis-com` and `api-gkehub-googleapis-com` are Ready |
| `cloud-sql` | `cloudsql-agent-uses-cloudsql` is Ready (CMEK is set at creation only) |
| `db-*` | `cloud-sql` is Ready |
| `*-workload-identity`, principals | `gke` is Ready (it creates the identity pool) |
| `dns-wildcard` | `gateway-ip` reports an address |

A held-back resource that has been composed once stays composed whatever its
prerequisites report later: dropping it would delete it.

## Not composed

| Pulumi | why |
| --- | --- |
| `billing/accountIamMember` × 4 (crossplane@, crossplane-prod@: `billing.user`, `billing.costsManager`) | provider-gcp has no billing account IAM kind; grant out of band |
| `projects/serviceIdentity` × 2 | no Crossplane kind. The GKE agent appears with `container.googleapis.com`; the Cloud SQL agent may need `gcloud beta services identity create --service=sqladmin.googleapis.com --project=<project>` before `cloudsql-agent-uses-cloudsql` can succeed |
| database password secrets in Secret Manager (`<name>-db-password`) | Cloud SQL cannot generate a password; a `User` is composed only for a database with `passwordSecretRef`, read from a Kubernetes Secret in the XR's namespace |
| `bootstrapFlux` (`src/flux.ts`) | an in-cluster install with a secret from Secret Manager, not a cloud resource |
| StackReferences | inputs (see above) |

## Status

`ready` (DNS endpoint observed and both pools Ready), `projectId`,
`projectNumber`, `clusterName`, `location`, `dnsEndpoint`, `workloadPool`,
`serviceAccounts` (emails by role), `dnsNameServers`, `gatewayAddress`,
`postgresConnectionName`, `postgresPrivateIp`, `clusterIdentity` (the
`flux-system/cluster-identity` values the stack exports), `getCredentials`,
`pending`, `cloud-url`.

## Usage

Without `option("params")`, `main.k` renders a built-in example (placeholder
organization, nothing observed yet, so only the first wave):

```bash
kcl run packages/cloud/mgmt/gcp
kcl run packages/cloud/mgmt/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/mgmt/xrd/examples/mgmt-gcp.yaml)"
pnpm exec nx run mgmt-gcp:render     # crossplane render (docker)
```

The ProviderConfig it runs with (`spec.providerConfigName`, or the provider
default) needs organization-level rights: project creation in the platform
folder, folder IAM on dev/staging/network/prod, Shared VPC admin on the host,
IAM on the security keys. `just seed-mgmt-providers` regenerates the ten schema
packages; [../xrd/providers.yaml](../xrd/providers.yaml) installs them.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `mgmt.k` | `plan` (every resource + the gates), `render`, `status` |
| `mgmt_test.k` | `kcl test`: gates, stickiness, cluster/pool shape, Cloud SQL, DNS, folder grants, Orphan/providerConfig, status |
| `composition.yaml` | `mgmt-gcp` Composition (`provider: gcp` label) |

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
