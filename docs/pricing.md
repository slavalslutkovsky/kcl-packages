# Pricing

`size: medium` is one word that means an `m5.large`, an `e2-standard-2` or a
`Standard_D2s_v5` depending on one `compositionSelector` label — and those are
not the same monthly bill. The `pricing` package prices a described estate on
every cloud the rate card covers and sorts the answers cheapest-first, so that
choice can be made with a number attached.

```
just price                                          the shipped example estate
just price <values.yaml> [env]                      your own
just price-refresh [aws|gcp|azure]...               re-fetch the card
just price-check [aws|gcp|azure]...                 fail on drift or staleness
```

**The output is a report, not a manifest.** The documents carry `kind`
(`PriceComparison`, `PriceSummary`) so `yq` can select them, and deliberately
no `apiVersion`: piping this into `kubectl apply` must fail outright rather
than half-work. Same rule as the Backstage catalog recipes
([docs/backstage.md](backstage.md)).

```yaml
regionSet: us                  # us-east-1 / us-central1 / eastus
clouds: [aws, gcp, azure]
items:
  - name: platform
    capability: cluster        # vm | cluster | postgres | bucket
    nodeSize: medium           # the portable rung, not a machine type
    nodeCount: 3
  - name: platform-db
    capability: postgres
    memoryGb: 8
    storageGb: 100
```

`packages/platform/pricing/examples/values.yaml` is the full worked example.
Field names are the XRDs' own, so an item can be checked against a real
`spec:` without a translation table.

## Why a Composition cannot do this

`function-kcl` is hermetic: no network, no clock, no filesystem beyond the
module. A Composition therefore *cannot* look a price up while it renders —
and that is a feature, not a gap. A render whose output depended on a live
price feed would be non-deterministic, un-reviewable and unreproducible; the
same XR would compose differently on Tuesday.

So pricing happens outside composition, against **committed data**: a rate
card in version control that you can diff, date and blame. The cost of that
choice is staleness, which is why every block carries an `as_of` and why
`just price-check` exists. The alternative — a Composition that phones a
vendor mid-reconcile — trades a staleness problem you can see for a
determinism problem you cannot.

## The ladders are not redefined here

A rate card carrying its own copy of `small -> t3.medium` would drift out of
step with the backend the first time someone changed one and not the other,
and the drift would be **invisible**: both files would still be internally
consistent and the price would just be wrong.

So `packages/platform/pricing` takes the nine backend packages as relative
path dependencies and calls their exported ladders:

| capability | what pricing calls | owned by |
|---|---|---|
| `vm` | `vm.machine_for(size)` | `packages/cloud/vm/{aws,gcp,azure}` |
| `cluster` | `cluster.machine_for(spec)` (different signature — it folds the `machineType` override in itself) | `packages/cloud/cluster/{aws,gcp,azure}` |
| `postgres` | `postgres.class_for(gb)` / `tier_for(gb)` / `sku_for(gb, ha)` | `packages/cloud/postgres/{aws,gcp,azure}` |

The price of that honesty is the nine provider schema trees those backends
import. Measured: `kcl run packages/platform/pricing` is **1.1–1.3s warm**
(0.17s for the nine backends alone; the rest is `packages/app`, pulled in only
for `app.lib.mergeValues`, i.e. the `-D env=` overlay). That is cheaper than
the `nx build` it runs inside.

**The drift guard.** `pricing_test.k` walks every rung of every ladder in
every region the card claims to cover and demands a rate. The abstract size
rungs are read out of the XRDs themselves, not retyped, so adding `2xlarge` to
`packages/cloud/vm/xrd/xrd.yaml` fails the pricing build until the card prices
it. Verified by breaking it: renaming the `m5.xlarge` key in `rates.k` makes
both ladder tests fail with

```
pricing: no aws compute rate for 'm5.xlarge' in us-east-1. A size ladder
produces that machine type but the rate card does not price it — refresh the
card (`just price-refresh aws`), or fix the ladder in packages/cloud/{vm,cluster}/aws.
```

A missing rate is always fatal. There is no `0.0 if unknown` path anywhere in
`lib.k`: a silent zero is how an estate gets moved to the cloud whose rates
were merely absent.

## Region sets

A comparison is only honest when each cloud is quoted in a region that means
the same thing. `rates.k` therefore keys everything by a **region set** — one
logical region spelled three ways — rather than by a raw region string:

| set | aws | gcp | azure |
|---|---|---|---|
| `us` | `us-east-1` | `us-central1` | `eastus` |

Adding a set means adding its three regions to all three blocks; the drift
test fails until every rate every ladder can produce exists in each of them.

## What the card prices

Per `(cloud, region)`:

- **compute** — on-demand USD/hour per native machine type, for every type the
  `vm` and `cluster` ladders produce (they overlap almost entirely, but are
  looked up separately so a divergence is priced rather than assumed away);
- **managed Kubernetes control plane** — USD/hour per cluster;
- **root/OS disk** — USD/GB-month on AWS and GCP; on Azure, the **S-tier
  ladder**, because Azure sells a managed disk by provisioned tier and not by
  the gigabyte. A 40 GiB Azure OS disk costs what a 64 GiB S6 costs, and the
  estimate names the tier it was billed at;
- **managed Postgres** — USD/hour per native instance class, plus USD/GB-month
  of its storage. Azure rounds a storage request up to a fixed step and bills
  the step, so `100 GiB` is charged as `128` and the estimate says so;
- **object storage** — USD/GB-month, standard/hot tier.

## What it does not price

Deliberately, and the estimate says so in its own `notes` rather than
quietly under-quoting:

| not priced | why |
|---|---|
| network egress | usage, not capacity; nothing in this repo knows the volume |
| IOPS / throughput beyond the free baseline | provisioned per volume, outside the XRD |
| snapshots, backups, PITR | not modelled by any capability's XRD |
| per-request API charges (S3/GCS/Blob operations) | usage again |
| support plans, marketplace, data transfer between AZs | account-level, not resource-level |
| cluster **worker root disks** | the `KubernetesCluster` XRD exposes no disk field, so each backend takes a different cloud default (EKS, GKE and AKS do not agree). Any number here would be invented |
| `highAvailability` on postgres | the card holds single-instance rates only. HA doubles Cloud SQL's meters and changes the Azure SKU family; rather than double a number nobody fetched, the estimate reports HA as **unpriced** and is therefore a floor |
| the in-cluster backends — `vm/kubevirt`, `postgres/cnpg`, `redis/valkey`, `bucket/rustfs`, `cluster/onprem` | a self-hosted backend has no vendor list price. Its cost *is* the underlying cluster's, which the `cluster` capability already prices |
| volume discounts, CUDs/RIs/Savings Plans, EDP, free tiers, credits | list price only; the invoice is the authority |

One number that looks like an omission and is not: the **AKS control plane is
$0.00**. `cluster/azure` never sets `skuTier`, so the cluster runs on the Free
tier, which is genuinely free and has no uptime SLA. Every Azure cluster
estimate carries a note saying exactly that, and `rates.k` records the
Standard-tier rate in a comment so switching is a one-cell change.

## Provenance — two tiers, and the difference matters

The card is **not** uniformly machine-generated.

| block | how | can `just price-check` verify it? |
|---|---|---|
| **azure** | machine-fetched from the [Azure Retail Prices API](https://prices.azure.com/api/retail/prices) by `tools/pricing/src/refresh-rates.ts` | **yes, by anyone** — the API is anonymous, no credentials of any kind |
| **aws** | machine-fetched from the AWS Price List Query API (`AWSPriceListService.GetProducts`, SigV4-signed) by the same tool | **yes, with credentials** — see below |
| **gcp** | **hand-entered** from the public pricing pages cited above each table in `rates.k` | **no** — it exits non-zero naming `GOOGLE_API_KEY` rather than pretending the numbers passed |

The GCP Cloud Billing Catalog API rejects unauthenticated callers outright
(*"Method doesn't allow unregistered callers"*) and this repo holds no Google
credentials on purpose — `just secrets-check` refuses credential files. So the
`gcp` block was transcribed from the vendor's own published tables, with the
URL and the read value written above every cell, and the arithmetic of every
derived cell written beside it.

**The weakest cell, named as such in the file:** Cloud SQL SSD storage
(`0.17`/GB-month). Unlike the compute tables, the storage table on
<https://cloud.google.com/sql/pricing> carries no region selector, so
`us-central1` is inferred from the section it sits in rather than read off a
label. The hourly SKU it derives from (`$0.000232877`/GiB-hour × 730) lands
exactly on Google's published `$0.170`/GB-month, so it is almost certainly
right — but it is the first number a `GOOGLE_API_KEY` should be pointed at.

**`buildGcp()` in the refresh tool has never executed.** No `GOOGLE_API_KEY`
existed when it was written, so its Cloud Billing SKU matchers — `E2 Instance
Core running in`, `E2 Instance Ram running in`, `Storage PD Capacity`,
`Cluster Management Fee` + `Zonal`, `Cloud SQL for PostgreSQL: Zonal -
vCPU`/`RAM`/`Standard storage`, `Standard Storage` + `RegionalStorage` — are
written from Google's documented SKU taxonomy and are **untested strings**.
Every one is wrapped in an exact-one-or-fail guard, so a wrong matcher throws
naming the cell rather than writing a wrong number; but the first person with
a key should expect to fix a string or two, and should treat that as the
tool's bug, not the card's.

### Derived cells

Two kinds of cell are arithmetic rather than one fetched SKU, because that is
how the vendor actually bills. The arithmetic is printed next to the number so
the cell can be checked against a public page without running anything.

- a `$/GB-month` storage rate whose SKU is published per GiB-**hour** is
  `hourly × 730`, rounded to 5 decimals;
- a managed-Postgres `$/hour` whose vendor prices **components** rather than
  instances: GCP bills Cloud SQL as vCPU + memory (`db-custom-4-15360` =
  `4 × $0.0413 + 15 × $0.007`), Azure bills General Purpose Flexible Server
  per vCore (`GP_Standard_D8s_v3` = `8 × $0.0855`) while Burstable is metered
  per instance.

## Refreshing the card, and the `as_of` contract

Every block carries an `as_of` date. **A block more than 90 days old is
stale**, and `just price-check` fails on it. That is the whole contract: KCL
has no clock (a hermetic render must be reproducible), so nothing inside the
package can enforce it — the tool does. What the package *can* check without a
clock is that the three blocks were refreshed **together**; the summary
document reports `mixedAsOf: true` when they disagree, because a card whose
clouds are dated differently is comparing prices from different days.

```
just price-refresh azure                        needs nothing
just price-refresh aws azure                    needs AWS credentials
GOOGLE_API_KEY=... just price-refresh gcp       needs a key this repo has none of
just price-refresh                              tries all three
just price-check aws azure                      re-fetch and diff, exit 1 on drift
```

| cloud | credential | notes |
|---|---|---|
| azure | none | anonymous REST, works offline-of-credentials in CI and on a laptop |
| aws | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (the tool also accepts the non-standard `AWS_SECRET_KEY` as a fallback) | `GetProducts` is free and needs only `pricing:GetProducts`. **The committed `aws` block was refreshed using the AWS keys present in the agent/CI execution environment, not from a developer laptop** — if `just price-refresh aws` fails for you with "no credentials are set", that is why: the keys are in that environment, not in your shell |
| gcp | `GOOGLE_API_KEY` | create an API key at <https://console.cloud.google.com/apis/credentials> with the Cloud Billing API enabled. Without it the tool exits 1 naming the variable, the API and the working alternative |

`price-check` is deliberately **not** a pre-commit hook: it is a network call
to three vendors, and a rate card going stale is a Monday problem, not a
reason to block a commit.

### What the refresher fetches is not hardcoded

The tool does not carry its own list of machine types. It runs

```
kcl run packages/platform/pricing -D skus=true -q --format json
```

and fetches exactly the SKUs the ladders produce. Add a rung to a backend and
the next refresh picks it up; `test_generator_inventory_covers_every_ladder_output`
fails if the inventory the tool walks ever falls behind what the ladders can
emit. Every vendor lookup is **exact-match-or-throw**: zero products, several
products, or several candidate price dimensions is an error naming the cell,
never a number chosen by position.

## The cost-allocation hole

A price comparison tells you what an estate *will* cost. Attributing what it
*did* cost is a different problem, and this platform only half-solves it.

`.claude/skills/org-governance/SKILL.md` records the gap: **`tags` reach is
partial**. Full coverage on `postgres/aws`, `redis/aws+gcp+valkey`,
`cluster/aws+gcp+azure`, `serverless/*`, `queue/aws+gcp`, `email/aws`,
`kms/azure`. Parent-only on `vm/aws` (the Instance is tagged, the composed
KeyPair is not), `vm/azure` (NIC and PublicIP get none), `bucket/aws`
(companion MRs get none), and `postgres/gcp` + `postgres/azure` (the companion
`Database`/`User`/`Configuration` resources get none). DNS records are
untaggable on both clouds, so `dns/*` is parent-only by vendor limitation.
None at all on `bucket/azure`, `bucket/rustfs`, `cluster/onprem`, `name/*` and
`packages/app`.

Consequences for anyone using these numbers:

- **`tags` is optional everywhere**, so a `cost-center` is advisory. Making it
  mandatory would need defaulting at the XRD level *plus* the missing backend
  mappings — see item 6 of the org-governance skill.
- A cloud cost report grouped by `cost-center` will **under-count** every
  capability in the parent-only list: the parent resource carries the tag, the
  composed companions do not, and on `vm/azure` the NIC and PublicIP are real
  line items.
- The estimate this package produces has **no such hole** — it prices what the
  backends compose, companions included where they cost money — which means a
  forecast and a tagged invoice will not reconcile until the tag mappings do.

## Files

| file | role |
|---|---|
| `packages/platform/pricing/rates.k` | the rate card: data only, no imports, no logic. One `# >>> GENERATED <cloud>` block per cloud, each with its `as_of`, its source and its derivations |
| `packages/platform/pricing/lib.k` | `Rate`, `Breakdown`, `Estimate`, `Item`, `Comparison`, `Estate`; the ladder dispatch, the asserting rate lookups, `estimate` / `compare` / `render`, and the `-D skus=true` inventory the refresher reads |
| `packages/platform/pricing/main.k` | the `-D values=` / `-D env=` contract, the built-in demo estate so `nx build pricing` still smoke-tests, and `-D skus=true` |
| `packages/platform/pricing/pricing_test.k` | the drift guard (every ladder rung priced in every region, size rungs cross-checked against the XRD enums), cheapest-first ordering, delta arithmetic, the 730-hour month, and the backend quirks the estimate must not smooth over |
| `packages/platform/pricing/examples/values.yaml` | a realistic small estate: a 3-node cluster, its database, its bucket, a bastion |
| `packages/platform/pricing/kcl.mod` | the nine backend path dependencies that make the ladders the single source of truth, plus `app` for `mergeValues` |
| `tools/pricing/src/refresh-rates.ts` | the refresher: SigV4 for AWS, anonymous REST for Azure, Cloud Billing Catalog for GCP; block splicing, `--check` with a line diff, and the staleness gate |
| `justfile` | `just price`, `just price-refresh`, `just price-check` |
| `packages/cloud/{vm,cluster,postgres}/*/` | where the size ladders actually live — change them there, never here |
| `.claude/skills/org-governance/SKILL.md` | the `tags` / cost-centre coverage table this doc's last section summarises |
