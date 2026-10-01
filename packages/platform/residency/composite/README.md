# residency

The only backend for the `Residency` XR (`platform.example.org/v1alpha1`,
Composition `residency`): where an organization may keep data and the
encryption keys that live there. A composite of composites — for every
(location, key) pair it emits one `EncryptionKey` child XR
(`cloud.example.org/v1alpha1`) in the region the logical location resolves to
on the chosen backend. Children are typed against the
[kms-xrd](../../../cloud/kms/xrd/) schema package; the kms capability owns the
cloud mapping. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/residency`.

## Composed resources

| resource (API group) | composition-resource-name | name | when |
| --- | --- | --- | --- |
| `EncryptionKey` (`cloud.example.org`) | `<location>-<key>` | `<residency>-<location>-<key>` | one per key per location; `keys[].locations` narrows a key, unset means every location |

A key is only ever created in its location's region, never replicated.

## Location catalog

`regions.k` maps a location to a region in the same country on every backend,
or not at all:

| location | jurisdiction | aws | gcp | azure | oci |
| --- | --- | --- | --- | --- | --- |
| `il` | Israel | `il-central-1` | `me-west1` | `israelcentral` | `il-jerusalem-1` |
| `de` | Germany | `eu-central-1` | `europe-west3` | `germanywestcentral` | `eu-frankfurt-1` |
| `nl` | Netherlands | — | `europe-west4` | `westeurope` | `eu-amsterdam-1` |
| `gb` | United Kingdom | `eu-west-2` | `europe-west2` | `uksouth` | `uk-london-1` |
| `us-va` | United States (Virginia) | `us-east-1` | `us-east4` | `eastus` | `us-ashburn-1` |

`locations[].region` always wins. Without it, an id outside the catalog, or a
catalog id with no region on the backend (`nl` on aws), fails the render.
`openbao` has no regions: every location resolves to `in-cluster`.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `provider` | `aws`, `gcp`, `azure`, `oci`, `openbao`; catalog column and every child's composition selector |
| `locations[].name`, `.region` | child `region` via the catalog or the explicit region; names must be unique |
| `keys[].name`, `.locations` | the pairs; names must be unique, `locations` may only name entries of `spec.locations` |
| `keys[].purpose` | `purpose`, default `encrypt-decrypt` |
| `keys[].algorithm` | `algorithm`, default `symmetric` |
| `keys[].protectionLevel` | `protectionLevel`, default `software` |
| `keys[].rotationDays` | `rotationDays`, default 90 (always sent; the bare EncryptionKey has none) |
| `keys[].deletionWindowDays` | `deletionWindowDays`, default 30 |
| `deletionPolicy` | every key's `deletionPolicy`, default `Orphan` |
| `tags` | every key's `tags`, plus `residency-location: <location>` |
| `resourceGroup`, `tenantId` | azure only, required there |
| `compartmentId` | oci only, required there |

On azure `<residency>-<location>-<key>` must be at most 24 characters (Key
Vault name limit) or the render fails.

Status written back: `provider`, `ready` (every key ready), `keysReady`
(`<ready>/<total>`), and `locations.<name>.{region, jurisdiction, ready,
keys}` — `region` as reported by the keys once they exist, the catalog answer
before; `keys` maps key id to the child's `keyUri`.

## Usage

`main.k` renders `render(oxr) + [status(oxr, ocds)]` under `items`. Without
`option("params")` it uses the built-in `_example` (gcp, one `app-data` key in
`il`):

```bash
kcl run packages/platform/residency/composite
```

Pass a real XR the way function-kcl does:

```bash
kcl run packages/platform/residency/composite \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/residency/xrd/examples/residency-gcp.yaml)}"
```

`pnpm exec nx run residency:render` (or `just render residency`) renders
`composition.yaml` through function-kcl against the first `residency-*.yaml`
example; `--example residency-oci` picks another. Needs docker.

In a cluster (needs docker/kind): `just e2e residency` publishes the package,
installs the XRD and Composition and applies the examples;
`just install-module residency` applies only the XRD and the Composition,
repointed at the local registry. The module ships no providers: the keys only
resolve once the `kms` module is installed.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `residency.k` | `pairs`, `render` (typed EncryptionKeys) and `status` |
| `regions.k` | location catalog: `catalog`, `jurisdiction`, `resolve` |
| `residency_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run residency:test     # kcl test
pnpm exec nx run residency:lint     # kcl lint
pnpm exec nx run residency:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
