# workflow-xrd

The `Workflow` XRD (`workflows.cloud.example.org`, group `cloud.example.org`,
version `v1alpha1`, `Namespaced`): portable managed workflow orchestration
mapped onto GCP Workflows, AWS Step Functions or Azure Logic Apps. The KCL
schemas under `models/` are generated from `xrd.yaml` with
`just xrd-schema workflow` (`kcl import -m crd`) and are not hand-edited;
import the composite type as
`workflow_xrd.models.v1alpha1.cloud_example_org_v1alpha1_workflow`.

The workflow source is not translated: `definition` is written in the language
of the backend the XR selects.

## Spec

| field | type | required | default | meaning |
| --- | --- | :-: | --- | --- |
| `region` | string | ✓ | | Region (GCP Workflows region / Step Functions region / Logic App location) |
| `definition` | string | ✓ | | Source, verbatim: gcp Workflows YAML/JSON (128 KB max); aws Amazon States Language JSON; azure Workflow Definition Language JSON object (`triggers`, `actions`, optional `parameters`, `$schema`, `contentVersion`; non-empty `outputs` rejected) |
| `resourceGroup` | string | azure | | Existing resource group for the Logic App; ignored elsewhere |
| `serviceAccount` | string | | | Runtime identity: GCP SA email (unset → default compute SA); AWS existing role ARN (unset → composed Role with no permissions); Azure user-assigned identity ARM id (unset → system-assigned) |
| `encryptionKmsKeyId` | string | | | CMEK: GCP `cryptoKeyName`; AWS `kmsKeyId` (role needs `kms:Decrypt`, `kms:GenerateDataKey`); ignored on azure |
| `deletionPolicy` | `Delete` \| `Orphan` | | `Delete` | `Orphan` keeps backing resources (managementPolicies) |
| `tags` | map[string]string | | | GCP labels, AWS tags (state machine and role), Azure tags |

Status: `ready`, `provider`, `name`, `id`, `arn` (AWS), `revision` (GCP/AWS),
`identity`, `cloud-url`. Printer columns: `READY`, `PROVIDER`, `WORKFLOW`.

## Backends

Selected with `spec.crossplane.compositionSelector.matchLabels.provider`.

| dir | Composition | native resources |
| --- | --- | --- |
| [`../aws/`](../aws/) | `workflow-aws` | Step Functions `StateMachine` (+ execution `Role`) |
| [`../azure/`](../azure/) | `workflow-azure` | Logic Apps `AppWorkflow` + one `AppTriggerCustom` / `AppActionCustom` per definition entry |
| [`../gcp/`](../gcp/) | `workflow-gcp` | Workflows `Workflow` |

## Manifests

| file | content |
| --- | --- |
| `xrd.yaml` | the CompositeResourceDefinition |
| `providers.yaml` | Crossplane providers: `provider-gcp-workflows`, `provider-aws-sfn`, `provider-aws-iam`, `provider-azure-logic`; install only those for the backends you use. Each needs a ProviderConfig with real credentials of your own (none shipped) |
| `functions.yaml` | pinned `function-kcl` and `function-auto-ready` from ghcr.io |
| `examples/workflow-aws.yaml` | `order-fulfilment` in `eu-west-1`: ASL Pass → Succeed, composed role |
| `examples/workflow-azure.yaml` | `order-fulfilment` in `westeurope`, `orders-rg`: HTTP trigger, `Reserve` HTTP action, `Respond` |
| `examples/workflow-gcp.yaml` | `order-fulfilment` in `europe-west1`: OIDC `http.post` then return, explicit service account |

## Usage

Needs a cluster with Crossplane (docker/kind for `e2e`):

```bash
just e2e workflow                # kind cluster, publish, install, providers, apply examples
just install-module workflow     # xrd.yaml + every ../*/composition.yaml, repointed at the local registry
kubectl apply -f packages/cloud/workflow/xrd/examples/workflow-gcp.yaml
```

## Development

```bash
pnpm exec nx run workflow-xrd:test     # kcl test
pnpm exec nx run workflow-xrd:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
