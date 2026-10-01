# pricing

Prices a described estate on every cloud the committed rate card covers and
sorts the answers cheapest-first, so the `compositionSelector` choice behind a
portable `size: medium` comes with a monthly number. The size ladders are not
copied: the nine `vm`, `cluster` and `postgres` backends for aws, gcp and azure
are path dependencies, and their exported ladders are called directly, so a
ladder change either prices or fails the build. A missing rate is always
fatal. The output is a report, not a manifest. Background, coverage and
provenance: [docs/pricing.md](../../../docs/pricing.md).

## Usage

```bash
just price                                         # examples/values.yaml
just price <values.yaml> [env]                     # your own, optional overlay
kcl run packages/platform/pricing -D values=estate.yaml -q
kcl run packages/platform/pricing -q               # built-in demo estate (no values.yaml in cwd)
kcl run packages/platform/pricing -D skus=true -q  # SKU inventory, not a price report
```

- `-D values=` — an explicit path that does not exist fails the render; with
  none, `values.yaml` in the current directory is read if it exists, otherwise
  the built-in demo estate is priced.
- `-D env=` — deep-merges `<stem>.<env>.yaml` next to the values file
  (`app.mergeValues`, overlay wins); a missing overlay fails the render.
- `-D skus=true` — the `PricedSkus` inventory the size ladders produce per
  cloud; `just price-refresh` reads it to know which SKUs to fetch.

`just price-refresh [aws|gcp|azure]...` rewrites `rates.k` from the vendor
APIs and `just price-check` fails on drift or a block older than 90 days; both
run `tools/pricing/src/refresh-rates.ts` and need network (and credentials for
aws and gcp, see [docs/pricing.md](../../../docs/pricing.md)).

## Inputs

Values file, validated as `lib.Estate`:

| key | type | default | meaning |
| --- | --- | --- | --- |
| `regionSet` | string | `us` | one logical region spelled per cloud (`rates.region_sets`; `us` = `us-east-1` / `us-central1` / `eastus`) |
| `clouds` | [string] | `[aws, gcp, azure]` | clouds to quote |
| `items` | [Item] | required | at least one; names must be unique |

A `clouds` list shorter than the default does not narrow the comparison
today: unpacked into `Estate`, it is merged index by index with the default
(`clouds: [gcp]` quotes gcp, gcp, azure; an overlay setting `[aws, gcp]`
leaves all three). List all three, in any order.

`Item` fields use the XRDs' own names:

| key | capability | meaning (default when omitted) |
| --- | --- | --- |
| `name` | all | required; the report key |
| `capability` | all | `vm`, `cluster`, `postgres` or `bucket` |
| `size` | vm | `small`…`xlarge` rung (`small`) |
| `diskGb` | vm | root disk (30) |
| `nodeSize`, `nodeCount` | cluster | node rung (`small`), node count (2); one control-plane fee is added |
| `machineType` | vm, cluster | native machine type, bypasses the ladder |
| `memoryGb`, `storageGb` | postgres | drive each cloud's class ladder (2) and storage (20) |
| `highAvailability` | postgres | not priced; adds a note saying the estimate is a floor |
| `instanceClass` | postgres | native class, bypasses the ladder |
| `storageGb` | bucket | required; capacity only |

## Outputs

A YAML stream with `kind` and deliberately no `apiVersion`:

- `PriceComparison`, one per item: `regions`, `cheapest`, and `estimates`
  sorted cheapest-first, each with `machine`, `usdMonth`, `usdHour`,
  `breakdown.{compute,storage}`, the `rates` used (SKU, unit, `asOf`),
  `notes`, and `deltaUsdMonth` / `deltaPct` against the cheapest.
- `PriceSummary`: whole-estate `totals` per cloud (cheapest first),
  `cheapest`, `asOf` per cloud, `mixedAsOf` when the card's blocks have
  different dates, and the global caveats.

## Examples

- `examples/values.yaml` — a small production estate on all three clouds: a
  3-node `medium` cluster, an 8 GiB / 100 GiB Postgres, a 500 GiB bucket and a
  `small` bastion VM. The default of `just price`.

## Layout

| file | content |
| --- | --- |
| `main.k` | `-D values=` / `-D env=` / `-D skus=` contract and the demo estate |
| `lib.k` | `Rate`, `Breakdown`, `Estimate`, `Item`, `Comparison`, `Estate`; ladder dispatch, asserting rate lookups, `estimate` / `compare` / `render`, `render_skus` |
| `rates.k` | the rate card: `region_sets`, `hours_per_month` (730), one generated block per cloud with its `as_of` |
| `pricing_test.k` | drift guard (every ladder rung priced in every region), ordering, delta and 730-hour arithmetic, backend quirks |

## Development

```bash
pnpm exec nx run pricing:test     # kcl test
pnpm exec nx run pricing:lint     # kcl lint
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
