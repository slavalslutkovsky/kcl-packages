# workflow-azure

Azure backend for the `Workflow` XR (`cloud.example.org/v1alpha1`),
Composition `workflow-azure` (label `provider: azure`). Typed against the
[azure-logic](../../../providers/azure-logic/) schema package, it maps the
portable workflow onto a Consumption Logic App. upjet-azure models every
trigger and action as its own resource, so the Workflow Definition Language
JSON in `spec.definition` is split: one `AppTriggerCustom` per `triggers`
entry and one `AppActionCustom` per `actions` entry, each bound to the
workflow by controller-ref. Actions keep their `runAfter`; nested actions stay
in their parent's body. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/workflow-azure`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `AppWorkflow` (`logic.azure.m.upbound.io`) | `managed` | always | external name pinned to the XR name |
| `AppTriggerCustom` (`logic.azure.m.upbound.io`) | `trigger-<key>` | per `triggers` key | external name = key; `body` = sorted-key JSON of the entry |
| `AppActionCustom` (`logic.azure.m.upbound.io`) | `action-<key>` | per `actions` key | external name = key; `body` = sorted-key JSON of the entry |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `resourceGroup` | `resourceGroupName`; **required**, the render fails without it |
| `region` | `AppWorkflow.location` |
| `definition` | split as above; `$schema` → `workflowSchema`, `contentVersion` → `workflowVersion`, `parameters` → `workflowParameters` (each a JSON string) |
| `serviceAccount` | `identity` `UserAssigned` with that ARM id; unset → `SystemAssigned` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR |
| `tags` | `AppWorkflow.tags` |

`definition` must be a JSON object; top-level keys other than `$schema`,
`contentVersion`, `parameters`, `triggers`, `actions`, `outputs` (e.g. the
portal's `{"definition": …}` envelope) fail the render, as does a non-empty
`outputs`. Ignored: `encryptionKmsKeyId` (Microsoft-managed keys only).

Status written back: `provider: azure`, `name`, `ready` (workflow id observed
and every trigger/action has an id), `id` (ARM id), `cloud-url` (Azure portal),
`identity` (system-assigned principal id, or the `serviceAccount`).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` Workflow (HTTP `manual` trigger and a `Respond` action in `westeurope`, resource group `example-rg`):

```bash
kcl run packages/cloud/workflow/azure
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/workflow/azure -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"Workflow","metadata":{"name":"wf"},"spec":{"region":"westeurope","resourceGroup":"rg","definition":"{\"triggers\":{\"manual\":{\"type\":\"Request\",\"kind\":\"Http\"}},\"actions\":{}}"}}}'
```

In a cluster (needs docker/kind): `just e2e workflow` publishes the module's
packages to the local registry and applies every example XR;
`just install-module workflow` applies only the XRD and the Compositions,
repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `workflow.k` | `render` (managed resources) and `status` (XR status) |
| `workflow_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run workflow-azure:test     # kcl test
pnpm exec nx run workflow-azure:lint     # kcl lint
pnpm exec nx run workflow-azure:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
