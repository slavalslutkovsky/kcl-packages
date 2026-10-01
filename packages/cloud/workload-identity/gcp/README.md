# workload-identity-gcp

GCP backend for the `WorkloadIdentity` XR (`cloud.example.org/v1alpha1`): GKE
Workload Identity. Typed against
[`gcp-cloudplatform`](../../../providers/gcp-cloudplatform) plus core
Kubernetes (`k8s`), it composes a Service Account, a ServiceAccountIAMMember
granting `roles/iam.workloadIdentityUser` to
`serviceAccount:<pool>[<ns>/<ksa>]`, one IAM member per `accessPolicies` entry
at project, folder or organization level, and the Kubernetes ServiceAccount
annotated with the service-account e-mail GKE reads. The
`workload-identity-gcp` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/workload-identity-gcp`, followed by
`function-auto-ready`.

The grant member (`serviceAccount:<email>`) and the annotation value exist only
once the service account is observed, so both are composed on the second
reconcile, from the observed composed resources (`ocds`), unless
`identity.existing` supplies the e-mail.

## Composed resources

IAM kinds are `cloudplatform.gcp.m.upbound.io/v1beta1`.

| resource | when | notes |
| --- | --- | --- |
| `ServiceAccount` (IAM) | `identity.existing` unset | resource name `managed`; external name (accountId) = `identity.name`, else the XR name |
| `ServiceAccountIAMMember` | always | resource name `binding`; `role: roles/iam.workloadIdentityUser`; targets the composed service account by controller reference, or `projects/-/serviceAccounts/<existing>` |
| `ProjectIAMMember` / `FolderIAMMember` / `OrganizationIAMMember` | one per `accessPolicies` entry, by `scopeType`, once the member is known | resource names `grant-<i>` |
| `ServiceAccount` (`v1`) | `serviceAccount.create` (default `true`) and the e-mail known | resource name `kubernetes-serviceaccount`; annotation `iam.gke.io/gcp-service-account` |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| spec field | maps to |
| --- | --- |
| `cluster.workloadIdentityPool` | the pool in the binding member; takes precedence over `project` |
| `cluster.project` | pool `<project>.svc.id.goog`; one of the two is required |
| `serviceAccount.name` / `namespace` | binding member and the composed ServiceAccount; namespace defaults to the XR's |
| `serviceAccount.create` | compose the ServiceAccount; with `true` the namespace must equal the XR's |
| `identity.name` | accountId |
| `identity.existing` | service-account e-mail to bind instead of creating one; `accessPolicies` must then be empty |
| `accessPolicies[].scopeType` | `project` (default) → `ProjectIAMMember`, `folder` → `FolderIAMMember`, `organization` → `OrganizationIAMMember` |
| `accessPolicies[].scope` | `project` (optional; ProviderConfig project when omitted) / `folder` / `orgId`; required for folder and organization |
| `accessPolicies[].role` | `role` |
| `accessPolicies[].condition` | IAM `condition`; `title` defaults to `<xr>-grant-<i>` |
| `displayName` | `ServiceAccount.displayName`; defaults to the XR name |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on the managed resources; otherwise the schema default `["*"]` |

The render fails on `region`, `resourceGroup`, `cluster.oidcIssuer` and
`cluster.audiences`. `tags` is not read.

Status written back to the XR:

| status | value |
| --- | --- |
| `provider` | `gcp` |
| `ready` | `true` once the e-mail is known |
| `name` | `identity.name`, else the XR name |
| `serviceAccount`, `subject` | `<ns>/<name>` and `serviceAccount:<pool>[<ns>/<name>]` |
| `email`, `annotation`, `principal` | e-mail, e-mail, `serviceAccount:<email>` |
| `id` | observed id |
| `cloud-url` | service-account console page, once `uniqueId` and `project` are observed |

## Usage

`main.k` renders the built-in `_example` XR when `option("params")` is absent.
Pass a real XR as `params.oxr`; add `params.ocds` with an observed `managed`
service account to see the second pass with the grant and ServiceAccount:

```bash
kcl run packages/cloud/workload-identity/gcp

kcl run packages/cloud/workload-identity/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/workload-identity/xrd/examples/workload-identity-gcp.yaml)"

kcl run packages/cloud/workload-identity/gcp \
    -D params="$(yq -o json -I0 '{"oxr": ., "ocds": {"managed": {"Resource": {"status": {"atProvider": {"email": "external-secrets@my-project.iam.gserviceaccount.com"}}}}}}' packages/cloud/workload-identity/xrd/examples/workload-identity-gcp.yaml)"
```

Through `function-kcl` and `crossplane render` against the working tree (needs
docker and the crossplane CLI), using
[`../xrd/examples/workload-identity-gcp.yaml`](../xrd/examples/workload-identity-gcp.yaml):

```bash
pnpm exec nx run workload-identity-gcp:render     # or: just render workload-identity-gcp
```

[`../xrd/examples/workload-identity-gcp-platform.yaml`](../xrd/examples/workload-identity-gcp-platform.yaml)
holds one WorkloadIdentity per platform controller (Crossplane, External
Secrets, cert-manager, Flux, monitoring, Pub/Sub, BigQuery).

On a Kind cluster: `just e2e workload-identity` (publish, install, apply every
example), `just install-module workload-identity` (XRD + Compositions only) or
`just workload workload-identity gcp` (module, providers, and this backend's
example). `just seed-iam-providers` regenerates the provider schema packages.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / `_example` entry point: `render` + `status` |
| `workload_identity.k` | `ksa_member`, `grant` (level → IAM member kind), `pool`, `render` and `status` |
| `workload_identity_test.k` | `kcl test` cases |
| `composition.yaml` | `workload-identity-gcp` Composition |

## Development

```bash
pnpm exec nx run workload-identity-gcp:test     # kcl test
pnpm exec nx run workload-identity-gcp:lint     # kcl lint
pnpm exec nx run workload-identity-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
