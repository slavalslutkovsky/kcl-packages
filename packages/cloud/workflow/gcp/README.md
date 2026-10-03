# workflow-gcp

GCP backend for the `Workflow` XR (`cloud.example.org/v1alpha1`), Composition
`workflow-gcp` (label `provider: gcp`). Typed against the
[gcp-workflows](../../../providers/gcp-workflows/) schema package, it maps the
portable workflow onto exactly one Workflows `Workflow` carrying the whole
source in `sourceContents`. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/workflow-gcp`.

## Composed resources

| resource (API group) | composition-resource-name | when | notes |
| --- | --- | --- | --- |
| `Workflow` (`workflows.gcp.m.upbound.io`) | `managed` | always | `name` = XR name; `deletionProtection: false` so Delete does not hang |

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `region` |
| `definition` | `sourceContents` (Workflows YAML/JSON, verbatim) |
| `serviceAccount` | `serviceAccount`; unset → project default compute SA |
| `encryptionKmsKeyId` | `cryptoKeyName` |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | `labels` |

Ignored: `resourceGroup` (Azure-only).

Status written back: `provider: gcp`, `name`, `ready` (`state == ACTIVE`),
`cloud-url` (Workflows console; `?project=` added once observed), `id`,
`revision`, `identity` (service account).

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` Workflow (one `return: ok` step in `us-central1`):

```bash
kcl run packages/cloud/workflow/gcp
```

Pass a real XR (and optionally observed resources as `ocds`) the way
function-kcl does:

```bash
kcl run packages/cloud/workflow/gcp -D 'params={"oxr":{"apiVersion":"cloud.example.org/v1alpha1","kind":"Workflow","metadata":{"name":"wf"},"spec":{"region":"europe-west1","definition":"main: {}","deletionPolicy":"Orphan"}}}'
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
pnpm exec nx run workflow-gcp:test     # kcl test
pnpm exec nx run workflow-gcp:lint     # kcl lint
pnpm exec nx run workflow-gcp:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
