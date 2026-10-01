# name-gcp

GCP backend for the `Name` XR (`cloud.example.org/v1alpha1`): one Cloud Storage
bucket with the portable storage tier mapped to its native storage class.
Typed against the vendored `gcp-storage` schema package
([../../../providers/gcp-storage](../../../providers/gcp-storage)). The
`name-gcp` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/name-gcp`, followed by `function-auto-ready`.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `Bucket` (`storage.gcp.m.upbound.io`) | always | composition-resource-name `managed` |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `forProvider.location` |
| `storageClass` | `forProvider.storageClass`: `standard` → `STANDARD`, `nearline` → `NEARLINE`, `cold` → `COLDLINE`, `archive` → `ARCHIVE`; omitted when unset |

No status is written back to the XR.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR (location
`us-central1`, no storage class):

```bash
kcl run packages/cloud/name/gcp
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>}`), so a real
XR renders like this:

```bash
kcl run packages/cloud/name/gcp \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/name/xrd/examples/name-gcp.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/name-gcp.yaml](../xrd/examples/name-gcp.yaml)):

```bash
pnpm exec nx run name-gcp:render
```

On a cluster: `just install-module name` applies the XRD and both Compositions
repointed at the local registry. The module ships no `providers.yaml`, so
`just e2e name` installs no provider for the GCS MR.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` |
| `name.k` | `render`: Bucket with the tier mapping |
| `name_test.k` | `kcl test` cases: bucket shape, storage class mapping |
| `composition.yaml` | `name-gcp` Composition (`provider: gcp` label) |

## Development

```bash
pnpm exec nx run name-gcp:test     # kcl test
pnpm exec nx run name-gcp:lint     # kcl lint
pnpm exec nx run name-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
