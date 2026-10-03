"""
pricing/lib — types and arithmetic over the committed rate card.

WHAT THIS IS FOR

The portable XRDs let a team ask for `size: medium` and get an m5.large, an
e2-standard-2 or a Standard_D2s_v5 depending on one `compositionSelector`
label. That is a one-line change with a three-figure monthly consequence, and
until now nothing in the repo could tell you what that consequence was. This
module prices a described estate on every cloud the card covers and sorts the
answers cheapest-first.

THE SIZE LADDERS ARE NOT REDEFINED HERE

A rate card that carried its own copy of `small -> t3.medium` would drift out
of step with the backend the first time someone changed one and not the
other, and the drift would be invisible: both files would still be internally
consistent and the price would just be wrong. So this module takes the nine
backend packages as relative path dependencies and CALLS their exported
ladders — `vm.machine_for`, `cluster.machine_for`, `postgres.class_for` /
`tier_for` / `sku_for`. A ladder change now either prices correctly or fails
the build, because the lookups below `assert` on a machine type the card does
not carry and `pricing_test.k` walks every rung of every ladder.

The cost of that honesty is that this package pulls in the aws-ec2, gcp-
compute, azure-compute/network, aws-eks/iam, gcp-container,
azure-containerservice, aws-rds, gcp-sql and azure-dbforpostgresql schema
packages. Measured: `kcl run packages/platform/pricing` is 0.83s cold and
0.17s warm, which is cheaper than the `nx build` it runs inside.

WHY A COMPOSITION CANNOT DO THIS

function-kcl is hermetic — no network, no clock, no filesystem beyond the
module. A Composition therefore cannot look a price up at render time, and
that is a feature: a render whose output depended on a live price feed would
be non-deterministic and un-reviewable. Pricing happens here, in a values
file you can diff, against a card you can date. See docs/pricing.md.

A MISSING RATE IS ALWAYS FATAL. There is no "0.0 if unknown" path anywhere in
this file: a silent zero is how an estate gets moved to the cloud whose rates
were merely absent.
"""

import .rates

# The size ladders, imported from the backends that own them. Aliased
# <cloud>_<capability> so a call site reads like the thing it prices.
import vm_aws.vm as aws_vm
import vm_gcp.vm as gcp_vm
import vm_azure.vm as azure_vm
import cluster_aws.cluster as aws_cluster
import cluster_gcp.cluster as gcp_cluster
import cluster_azure.cluster as azure_cluster
import postgres_aws.postgres as aws_pg
import postgres_gcp.postgres as gcp_pg
import postgres_azure.postgres as azure_pg

# XRD defaults, repeated here because an item that omits a field must be
# priced the way the cluster would actually provision it. Keep in step with
# packages/cloud/{vm,cluster,postgres}/xrd/xrd.yaml.
# vm.spec.size and cluster.spec.nodeSize
default_size = "small"
# cluster.spec.nodeCount
default_node_count = 2
# vm.spec.diskGb (the backends' own fallback, not the XRD's)
default_disk_gb = 30
# postgres.spec.memoryGb
default_memory_gb = 2
# postgres.spec.storageGb
default_storage_gb = 20

schema Rate:
    """
    One cell of the rate card, resolved for one lookup.

    Carried into the estimate rather than folded away so the output shows its
    own workings: which native SKU was priced, at what unit rate, and — the
    part that matters six months from now — how old the number is.

    unit
        `hour` for compute and control planes, `gb-month` for storage billed
        by the gigabyte, `disk-month` for storage billed by provisioned tier
        (Azure managed disks), where `usd` is the whole disk's monthly price.
    """
    cloud: str
    region: str
    sku: str
    usd: float
    unit: "hour" | "gb-month" | "disk-month"
    asOf: str

schema Breakdown:
    """Monthly cost split the only two ways every capability here splits."""
    compute: float = 0
    storage: float = 0

schema Estimate:
    """
    What one item costs on one cloud.

    `usdMonth` is the primary figure and `usdHour` is derived from it, so the
    730-hour month is applied exactly once (to the compute rates) on the way
    in and divided out once on the way back. Storage rates are already
    monthly and are never multiplied by anything.

    `deltaUsdMonth` / `deltaPct` are zero until `compare` fills them in;
    `estimate` on its own has nothing to be cheaper than.
    """
    cloud: str
    region: str
    machine: str = ""
    usdHour: float
    usdMonth: float
    breakdown: Breakdown
    rates: [Rate]
    notes: [str] = []
    deltaUsdMonth: float = 0
    deltaPct: float = 0

schema Item:
    """
    One thing to price. Field names are the XRD's, not invented ones, so a
    values file reads like the XRs it is estimating and a reviewer can check
    it against a real `spec:` without a translation table.
    """
    name: str
    capability: "vm" | "cluster" | "postgres" | "bucket"
    # vm
    size?: "small" | "medium" | "large" | "xlarge"
    diskGb?: int
    # cluster
    nodeSize?: "small" | "medium" | "large" | "xlarge"
    nodeCount?: int
    # vm + cluster escape hatch
    machineType?: str
    # postgres
    memoryGb?: float
    storageGb?: int
    highAvailability?: bool
    instanceClass?: str

    check:
        name, "every priced item needs a name — it is what the comparison is reported under"
        capability != "bucket" or storageGb, "item '${name}': a bucket is priced entirely on storageGb, so it must say how big it is"
        not nodeCount or nodeCount >= 1, "item '${name}': nodeCount must be at least 1 (matching the KubernetesCluster XRD), got ${nodeCount}"
        not storageGb or storageGb >= 1, "item '${name}': storageGb must be at least 1, got ${storageGb}"
        not diskGb or diskGb >= 1, "item '${name}': diskGb must be at least 1, got ${diskGb}"
        not memoryGb or memoryGb >= 1, "item '${name}': memoryGb must be at least 1 (matching the PostgresInstance XRD), got ${memoryGb}"

schema Comparison:
    """One item priced on every requested cloud, cheapest first."""
    name: str
    capability: str
    regions: {str:str}
    cheapest: str
    estimates: [Estimate]

schema Estate:
    """
    The whole thing to price: a set of items, one region triple, and which
    clouds to quote. The default is every cloud the card covers, because a
    comparison that quietly drops one is worse than no comparison.
    """
    regionSet: str = "us"
    clouds: [str] = rates.clouds
    items: [Item]

    check:
        items, "an estate with no items prices nothing; add at least one item"
        len([i.name for i in items]) == len({i.name: "" for i in items}), "item names must be unique — they are the join key of the summary"

# ── Ladder lookups ───────────────────────────────────────────────────────────
# Each of these is a thin dispatch onto the backend that owns the mapping.
# They exist so the branch on `cloud` happens once, and so a new cloud shows
# up as one missing `elif` rather than as a wrong price.
vm_machine = lambda cloud: str, size: str -> str {
    _m = ""
    if cloud == "aws":
        _m = aws_vm.machine_for(size)
    elif cloud == "gcp":
        _m = gcp_vm.machine_for(size)
    else:
        _m = azure_vm.machine_for(size)
    _m
}

# The cluster ladders take the whole spec and fold the machineType override
# in themselves, so they are handed a spec carrying only nodeSize; the
# override is applied by the caller, uniformly with vm.
node_machine = lambda cloud: str, size: str -> str {
    _m = ""
    if cloud == "aws":
        _m = aws_cluster.machine_for({nodeSize = size})
    elif cloud == "gcp":
        _m = gcp_cluster.machine_for({nodeSize = size})
    else:
        _m = azure_cluster.machine_for({nodeSize = size})
    _m
}

# Three different shapes on purpose: AWS picks the smallest RDS class that
# holds the memory, GCP derives a db-custom tier, and Azure additionally bumps
# off the Burstable family when HA is on, because zone-redundant HA is
# unsupported there. Pricing the pre-bump SKU would under-quote every HA
# Azure database.
db_machine = lambda cloud: str, memory_gb: float, ha: bool -> str {
    _m = ""
    if cloud == "aws":
        _m = aws_pg.class_for(memory_gb)
    elif cloud == "gcp":
        _m = gcp_pg.tier_for(memory_gb)
    else:
        _m = azure_pg.sku_for(memory_gb, ha)
    _m
}

# Azure only accepts fixed storage steps and bills the step, not the request.
# The other two bill what was asked for.
db_billed_storage_gb = lambda cloud: str, storage_gb: int -> int {
    azure_pg.storage_mb_for(storage_gb) // 1024 if cloud == "azure" else storage_gb
}

# ── Rate lookups ─────────────────────────────────────────────────────────────
# Every one of these ends in a `Rate` or an `assert`. The messages name the
# cloud, the region and the SKU, and say which of the two sides to fix,
# because "no rate" is ambiguous between a stale card and a changed ladder.

# The card's three cloud blocks do not have identical shapes (Azure's root
# disk is a tier ladder, everyone else's is a per-GB rate), so KCL infers a
# union for `card[cloud][name]` and refuses to index it. The annotation says
# "this is a region-keyed table"; the callers below are what actually know
# the value shape.
_table = lambda cloud: str, name: str, region: str -> any {
    assert cloud in rates.card, "pricing: unknown cloud '${cloud}' — the rate card covers ${rates.clouds}. Add a block to rates.k, or fix the values file."
    _block: {str:any} = rates.card[cloud]
    _t: {str:any} = _block[name]
    assert region in _t, "pricing: the ${cloud} rate card has no '${name}' rates for region '${region}' (it covers ${[_r for _r in _t]}). Add the region with `just price-refresh ${cloud}`."
    _t[region]
}

compute_rate = lambda cloud: str, region: str, machine: str -> Rate {
    _t = _table(cloud, "compute_hour", region)
    assert machine in _t, "pricing: no ${cloud} compute rate for '${machine}' in ${region}. A size ladder produces that machine type but the rate card does not price it — refresh the card (`just price-refresh ${cloud}`), or fix the ladder in packages/cloud/{vm,cluster}/${cloud}."
    Rate {cloud = cloud, region = region, sku = machine, usd = _t[machine], unit = "hour", asOf = rates.as_of[cloud]}
}

control_plane_rate = lambda cloud: str, region: str -> Rate {
    _e = _table(cloud, "control_plane", region)
    Rate {cloud = cloud, region = region, sku = _e.sku, usd = _e.usd_hour, unit = "hour", asOf = rates.as_of[cloud]}
}

db_rate = lambda cloud: str, region: str, machine: str -> Rate {
    _t = _table(cloud, "db_instance_hour", region)
    assert machine in _t, "pricing: no ${cloud} managed-Postgres rate for '${machine}' in ${region}. The memory ladder in packages/cloud/postgres/${cloud} produces that class but the rate card does not price it — refresh the card (`just price-refresh ${cloud}`), or fix the ladder."
    Rate {cloud = cloud, region = region, sku = machine, usd = _t[machine], unit = "hour", asOf = rates.as_of[cloud]}
}

db_storage_rate = lambda cloud: str, region: str -> Rate {
    _e = _table(cloud, "db_storage", region)
    Rate {cloud = cloud, region = region, sku = _e.sku, usd = _e.gb_month, unit = "gb-month", asOf = rates.as_of[cloud]}
}

object_rate = lambda cloud: str, region: str -> Rate {
    _e = _table(cloud, "object", region)
    Rate {cloud = cloud, region = region, sku = _e.sku, usd = _e.gb_month, unit = "gb-month", asOf = rates.as_of[cloud]}
}

# Root/OS disks are the one place the three clouds do not even agree on the
# unit: AWS and GCP sell provisioned gigabytes, Azure sells a disk from a
# fixed S-tier ladder and bills the tier. Both shapes come back as a `Rate`
# whose `unit` says which, and `_storage_month` below does the right
# multiplication — so no caller has to know.
root_disk_rate = lambda cloud: str, region: str, gb: int -> Rate {
    _e = _table(cloud, "root_disk", region)
    _rate = Rate {cloud = cloud, region = region, sku = _e.sku, usd = 0, unit = "gb-month", asOf = rates.as_of[cloud]}
    if "gb_month" in _e:
        _rate = Rate {cloud = cloud, region = region, sku = _e.sku, usd = _e.gb_month, unit = "gb-month", asOf = rates.as_of[cloud]}
    else:
        _fits = [_t for _t in _e.tiers if _t.gb >= gb]
        assert _fits, "pricing: a ${gb} GiB root disk is larger than the biggest ${cloud} tier in ${region} (${_e.tiers[-1].gb} GiB). Reduce diskGb, or extend the ladder in rates.k."
        _rate = Rate {cloud = cloud, region = region, sku = "${_e.sku} ${_fits[0].gb}GiB", usd = _fits[0].usd_month, unit = "disk-month", asOf = rates.as_of[cloud]}
    _rate
}

# ── Arithmetic ───────────────────────────────────────────────────────────────

# Money is rounded to six decimals, not two: an hourly rate of $0.0416 is
# already four, and rounding a per-GB rate to cents turns a 500 GB bucket into
# a rounding error. Presentation can round further; the model must not.
_usd = lambda x: float -> float {
    round(x, 6)
}

# The ONLY place hours become a month. Compute rates are per hour, storage
# rates are already per month, and nothing else in this file multiplies or
# divides by 730.
_compute_month = lambda rate: Rate, count: int -> float {
    rate.usd * rates.hours_per_month * count
}

_storage_month = lambda rate: Rate, gb: float -> float {
    rate.usd * gb if rate.unit == "gb-month" else rate.usd
}

_estimate = lambda {
    cloud: str,
    region: str,
    machine: str,
    compute: float,
    storage: float,
    rs: [Rate],
    notes: [str],
} -> Estimate {
    _month = _usd(compute + storage)
    Estimate {
        cloud = cloud
        region = region
        machine = machine
        usdMonth = _month
        usdHour = round(_month / rates.hours_per_month, 8)
        breakdown = Breakdown {compute = _usd(compute), storage = _usd(storage)}
        rates = rs
        notes = notes
    }
}

estimate = lambda item: Item, cloud: str, region: str -> Estimate {
    """
    Price one item on one cloud. Fails — loudly, naming the SKU — rather than
    return a number it cannot justify.
    """
    _e = Estimate {cloud = cloud, region = region, usdHour = 0, usdMonth = 0, breakdown = Breakdown {}, rates = []}

    if item.capability == "vm":
        _machine = item.machineType or vm_machine(cloud, item.size or default_size)
        _gb = item.diskGb or default_disk_gb
        _cr = compute_rate(cloud, region, _machine)
        _dr = root_disk_rate(cloud, region, _gb)
        _e = _estimate(cloud, region, _machine, _compute_month(_cr, 1), _storage_month(_dr, float(_gb)), [_cr, _dr], [])
    elif item.capability == "cluster":
        _machine = item.machineType or node_machine(cloud, item.nodeSize or default_size)
        _count = item.nodeCount or default_node_count
        _cr = compute_rate(cloud, region, _machine)
        _pr = control_plane_rate(cloud, region)

        # Worker root disks are deliberately absent: the KubernetesCluster XRD
        # exposes no disk field, so each backend takes a different cloud
        # default and any number here would be invented. Say so in the output
        # instead of quietly under-quoting.
        _notes = ["worker root disks are not priced: the KubernetesCluster XRD exposes no disk field, so each backend takes its cloud's default"]
        if _pr.usd == 0:
            _notes = _notes + ["${_pr.sku}: a real $0 control plane with no uptime SLA, not a missing rate"]

        _e = _estimate(cloud, region, _machine, _compute_month(_cr, _count) + _compute_month(_pr, 1), 0, [_cr, _pr], _notes)
    elif item.capability == "postgres":
        _mem = item.memoryGb or default_memory_gb
        _ha = item.highAvailability or False
        _machine = item.instanceClass or db_machine(cloud, float(_mem), _ha)
        _asked = item.storageGb or default_storage_gb
        _billed = db_billed_storage_gb(cloud, _asked)
        _cr = db_rate(cloud, region, _machine)
        _sr = db_storage_rate(cloud, region)
        _notes = []
        if _billed != _asked:
            _notes = _notes + ["${cloud} bills fixed storage steps: ${_asked} GiB requested, ${_billed} GiB provisioned and charged"]

        if _ha:
            # HA doubles Cloud SQL's vCPU/memory meters and Azure's server
            # count, and adds a standby to RDS Multi-AZ. The card holds
            # single-instance rates only, so say what is missing instead of
            # doubling a number nobody fetched.
            _notes = _notes + ["highAvailability is NOT priced: the card carries single-instance rates only, so this estimate is a floor"]

        _e = _estimate(cloud, region, _machine, _compute_month(_cr, 1), _storage_month(_sr, float(_billed)), [_cr, _sr], _notes)
    else:
        _gb = item.storageGb
        _or = object_rate(cloud, region)

        # Requests, retrieval and egress are usage, not capacity; a card
        # cannot know them and this repo has no telemetry that could.
        _e = _estimate(cloud, region, _or.sku, 0, _storage_month(_or, float(_gb)), [_or], ["capacity only: requests, retrieval and egress are not priced"])
    _e
}

# No sort-by-key in KCL, and at most a handful of clouds: rank each estimate
# by how many are strictly cheaper, ties broken by the order the clouds were
# asked for, then place each rank. Stable, and obvious enough to read.
_rank = lambda es: [Estimate], i: int -> int {
    len([_j for _j in range(0, len(es)) if es[_j].usdMonth < es[i].usdMonth or (es[_j].usdMonth == es[i].usdMonth and _j < i)])
}

cheapest_first = lambda es: [Estimate] -> [Estimate] {
    [[es[_i] for _i in range(0, len(es)) if _rank(es, _i) == _r][0] for _r in range(0, len(es))]
}

compare = lambda item: Item, region_set: str, clouds: [str] -> Comparison {
    """
    Price one item on every requested cloud, cheapest first, each row
    carrying what it costs over the cheapest.
    """
    assert region_set in rates.region_sets, "pricing: unknown region set '${region_set}' (the card defines ${[_k for _k in rates.region_sets]}). A region set is one logical region spelled once per cloud; add it to rates.k."
    _rs = rates.region_sets[region_set]
    assert clouds, "pricing: no clouds to compare for item '${item.name}'"
    assert all _c in clouds {_c in _rs}, "pricing: region set '${region_set}' does not name a region for every cloud in ${clouds} (it has ${_rs}). Comparing an item on a cloud with no region would price it somewhere arbitrary."

    _sorted = cheapest_first([estimate(item, _c, _rs[_c]) for _c in clouds])
    _floor = _sorted[0].usdMonth
    Comparison {
        name = item.name
        capability = item.capability
        regions = {_c: _rs[_c] for _c in clouds}
        cheapest = _sorted[0].cloud
        estimates = [Estimate {
            **_e
            deltaUsdMonth = _usd(_e.usdMonth - _floor)
            deltaPct = round((_e.usdMonth - _floor) / _floor * 100, 2) if _floor > 0 else 0
        } for _e in _sorted]
    }
}

# ── The inventory the refresh generator fetches ──────────────────────────────
# `tools/pricing/src/refresh-rates.ts` must know WHICH SKUs to ask the vendor
# APIs for, and the answer is "whatever the ladders produce" — which only the
# ladders know. Rather than keep a second list in TypeScript that would rot,
# the generator runs `kcl run packages/platform/pricing -D skus=true -q` and
# fetches exactly what comes back. Add a rung to a backend and the refresher
# picks it up on the next run.
skus_kind = "PricedSkus"

# The abstract rungs. Cross-checked against the `size` / `nodeSize` enums in
# the VirtualMachine and KubernetesCluster XRDs by pricing_test.k, so this
# list cannot quietly fall behind the API it mirrors.
size_rungs = ["small", "medium", "large", "xlarge"]

# Memory sizes that between them land on every rung of all three Postgres
# ladders (RDS class, Cloud SQL db-custom tier, Flexible Server SKU),
# including the fractional N1 boundaries Cloud SQL uses and one value above
# every ladder's top so the clamp is covered.
memory_rungs = [1, 2, 3.75, 4, 7.5, 8, 15, 16, 30, 32, 60, 64, 128, 512]

# Order-preserving de-duplication: the vm and cluster ladders overlap almost
# entirely, and a rate fetched twice is a rate that can disagree with itself.
_unique = lambda xs: [str] -> [str] {
    [xs[_i] for _i in range(0, len(xs)) if _i == [_j for _j in range(0, len(xs)) if xs[_j] == xs[_i]][0]]
}

required_skus = lambda cloud: str -> {str:[str]} {
    {
        compute = _unique([vm_machine(cloud, _s) for _s in size_rungs] + [node_machine(cloud, _s) for _s in size_rungs])
        db = _unique(sum([[db_machine(cloud, _g, _h) for _g in memory_rungs] for _h in [False, True]], []))
    }
}

render_skus = lambda region_set: str -> [any] {
    assert region_set in rates.region_sets, "pricing: unknown region set '${region_set}' (the card defines ${[_k for _k in rates.region_sets]})"
    _rs = rates.region_sets[region_set]
    [{
        kind = skus_kind
        cloud = _c
        region = _rs[_c]
        compute = required_skus(_c).compute
        db = required_skus(_c).db
    } for _c in rates.clouds]
}

# ── Rendering the report ─────────────────────────────────────────────────────
# The output is a REPORT, not a manifest: `kind` is there so `yq` can select a
# document, and there is deliberately no `apiVersion` — piping this into
# `kubectl apply` must fail obviously rather than half-work.
report_kind = "PriceComparison"
summary_kind = "PriceSummary"

# KCL has no clock (by design — a hermetic render must be reproducible), so
# staleness cannot be computed here; `just price-check` is what fails on a
# card older than its 90-day contract (docs/pricing.md). What CAN be checked
# without a clock is that the blocks were refreshed TOGETHER: a card whose
# clouds disagree on their as_of date is comparing prices from different days.
_as_of_spread = lambda clouds: [str] -> [str] {
    [rates.as_of[_c] for _c in clouds]
}

# Same ranking as `cheapest_first`, over the plain total dicts the summary
# builds. Kept separate rather than generalised: a lambda that took a key
# accessor would be harder to read than the eight lines of the same shape.
_total_rank = lambda ts: [any], i: int -> int {
    len([_j for _j in range(0, len(ts)) if ts[_j].usdMonth < ts[i].usdMonth or (ts[_j].usdMonth == ts[i].usdMonth and _j < i)])
}

cheapest_total_first = lambda ts: [any] -> [any] {
    [[ts[_i] for _i in range(0, len(ts)) if _total_rank(ts, _i) == _r][0] for _r in range(0, len(ts))]
}

render = lambda estate: Estate -> [any] {
    _comparisons = [compare(_i, estate.regionSet, estate.clouds) for _i in estate.items]
    _totals = [{
        cloud = _c
        usdMonth = _usd(sum([[_e.usdMonth for _e in _cmp.estimates if _e.cloud == _c][0] for _cmp in _comparisons], 0))
    } for _c in estate.clouds]
    _floor = min([_t.usdMonth for _t in _totals])
    _dates = _as_of_spread(estate.clouds)

    [{
        kind = report_kind
        name = _c.name
        capability = _c.capability
        regions = _c.regions
        cheapest = _c.cheapest
        estimates = _c.estimates
    } for _c in _comparisons] + [{
        kind = summary_kind
        regionSet = estate.regionSet
        items = len(estate.items)
        # Whole-estate totals, which is the number a decision is actually
        # made on — per-item cheapest is not additive, because nobody runs
        # one item on AWS and the next on GCP.
        totals = cheapest_total_first([{
            cloud = _t.cloud
            usdMonth = _t.usdMonth
            deltaUsdMonth = _usd(_t.usdMonth - _floor)
            deltaPct = round((_t.usdMonth - _floor) / _floor * 100, 2) if _floor > 0 else 0
        } for _t in _totals])
        cheapest = [_t.cloud for _t in _totals if _t.usdMonth == _floor][0]
        asOf = {_c: rates.as_of[_c] for _c in estate.clouds}
        mixedAsOf = len({_d: "" for _d in _dates}) > 1
        notes = [
            "public on-demand list prices, USD, pre-discount; ${rates.hours_per_month}-hour month"
            "no egress, IOPS, snapshots, backups, per-request charges or support plans"
            "in-cluster backends (kubevirt, cnpg, valkey, rustfs, onprem) have no vendor list price and are not comparable here"
        ]
    }]
}
