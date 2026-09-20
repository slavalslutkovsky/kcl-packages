# Unit tests for the rate card and the estimator.
#
# Contract under test:
#   vm_machine / node_machine / db_machine  -> the BACKENDS' ladders, not a copy
#   compute_rate / db_rate / *_rate(...)    -> a Rate, or a named fatal error
#   estimate(item, cloud, region)           -> Estimate {usdHour, usdMonth, breakdown}
#   compare(item, regionSet, clouds)        -> Comparison, cheapest first, deltas filled
#
# The test that matters most is the DRIFT GUARD: every machine type, RDS
# class, Cloud SQL tier and Flexible Server SKU that a ladder can produce must
# have a rate in every region the card claims to cover. It walks the ladders by
# calling them — the size enums come out of the XRDs themselves — so adding a
# rung to a backend, or a size to an XRD, fails here until the card prices it.
# That is the whole reason this package takes nine path dependencies instead of
# keeping its own copy of the mapping.
#
# A KCL test cannot catch an assert, so "a missing rate is fatal" cannot be
# asserted directly (same limitation `packages/platform/entitlement/lib_test.k`
# documents). What is pinned instead is the property that makes the assert the
# only possible outcome: every lookup below goes through the asserting path,
# and `test_no_silent_zero` proves no code path returns 0 for an unknown rate.
#
# Paths are relative to this package, because `kcl test` runs with the package
# directory as its working directory (nx-kcl's `test` target sets cwd).
import .lib
import .rates
import yaml
import file

# ---- helpers ----------------------------------------------------------------
# NOTE: helper names must not collide with a lambda parameter — KCL normalizes
# the leading underscore, so a helper named `_item` would shadow one.

# The abstract size rungs, read out of the XRD rather than retyped: the enum is
# the API's promise, and a rung added there with no rate is exactly the drift
# this file exists to catch.
_xrd_enum = lambda path: str, field: str -> [str] {
    assert file.exists(path), "pricing_test: cannot read '${path}' from ${file.workdir()} — run `kcl test` from packages/platform/pricing (or `nx test pricing`), which is where the relative XRD paths resolve."
    _props = yaml.decode(file.read(path)).spec.versions[0].schema.openAPIV3Schema.properties.spec.properties
    assert field in _props, "pricing_test: the XRD at '${path}' has no spec.${field}"
    _props[field].enum
}

vm_sizes = _xrd_enum("../../cloud/vm/xrd/xrd.yaml", "size")
cluster_sizes = _xrd_enum("../../cloud/cluster/xrd/xrd.yaml", "nodeSize")

# Every (cloud, region) pair the card claims to cover, flattened once.
places = sum([[{cloud = _c, region = _r} for _c, _r in _regions] for _set, _regions in rates.region_sets], [])

# Memory sizes to walk the Postgres ladders with. Every whole GiB from the
# XRD's minimum to the top RDS rung hits every rung of all three ladders on the
# way past; the two fractions are Cloud SQL's N1 rung boundaries, and 512 is
# above every ladder's top so the clamp is covered too.
pg_probe_gb = [float(_g) for _g in range(1, 129)] + [3.75, 7.5, 512]

# `|` on dicts is a UNION in KCL: overlapping keys are a hard error, not an
# override (the same trap packages/cloud/redis/valkey/redis.k documents), so
# a case that wants its own `name` has to be merged explicitly.
_item = lambda cap: str, extra: {str:any} -> lib.Item {
    _base = {name = "probe", capability = cap}
    lib.Item {**({_k: (extra[_k] if _k in extra else _base[_k]) for _k in _base} | {_k: extra[_k] for _k in extra if _k not in _base})}
}

# ---- drift guard: every ladder rung is priced --------------------------------
test_size_rungs_mirror_the_xrd_enums = lambda {
    # `lib.size_rungs` is what `-D skus=true` walks, and therefore what
    # `just price-refresh` fetches. If an XRD grows a rung and this list does
    # not, the refresher would never ask the vendor for its price.
    assert lib.size_rungs == vm_sizes, "lib.size_rungs must equal the VirtualMachine XRD's size enum: ${lib.size_rungs} vs ${vm_sizes}"
    assert lib.size_rungs == cluster_sizes, "lib.size_rungs must equal the KubernetesCluster XRD's nodeSize enum: ${lib.size_rungs} vs ${cluster_sizes}"
}

test_generator_inventory_covers_every_ladder_output = lambda {
    # The dense memory probe above is the truth about what the ladders emit;
    # `lib.memory_rungs` is the coarse list the generator walks. A rung the
    # dense probe reaches but the coarse list misses would be priced today
    # (someone hand-added the cell) and silently dropped on the next refresh.
    _inventory_db = sum([lib.required_skus(_p.cloud).db for _p in places], [])
    _inventory_compute = sum([lib.required_skus(_p.cloud).compute for _p in places], [])
    _dense_db = sum([sum([[lib.db_machine(_p.cloud, _gb, _ha) for _gb in pg_probe_gb] for _ha in [False, True]], []) for _p in places], [])
    _dense_compute = sum([[lib.vm_machine(_p.cloud, _s) for _s in vm_sizes] + [lib.node_machine(_p.cloud, _s) for _s in cluster_sizes] for _p in places], [])
    _missing_db = [_s for _s in _dense_db if _s not in _inventory_db]
    _missing_compute = [_s for _s in _dense_compute if _s not in _inventory_compute]
    assert not _missing_db, "the refresh generator's inventory misses instance classes the ladders can produce: ${_missing_db}"
    assert not _missing_compute, "the refresh generator's inventory misses machine types the ladders can produce: ${_missing_compute}"
}

test_vm_ladder_is_priced_everywhere = lambda {
    _rs = sum([[lib.compute_rate(_p.cloud, _p.region, lib.vm_machine(_p.cloud, _s)) for _s in vm_sizes] for _p in places], [])
    assert len(_rs) == len(places) * len(vm_sizes), "every VirtualMachine size must resolve to a priced machine type on every cloud the card covers"
    assert all _r in _rs {_r.usd > 0}, "a VM machine type priced at zero is a missing rate wearing a number: ${[_r.sku for _r in _rs if _r.usd <= 0.0]}"
}

test_cluster_ladder_is_priced_everywhere = lambda {
    _rs = sum([[lib.compute_rate(_p.cloud, _p.region, lib.node_machine(_p.cloud, _s)) for _s in cluster_sizes] for _p in places], [])
    assert len(_rs) == len(places) * len(cluster_sizes), "every KubernetesCluster nodeSize must resolve to a priced machine type on every cloud the card covers"
    assert all _r in _rs {_r.usd > 0}, "a node machine type priced at zero is a missing rate wearing a number: ${[_r.sku for _r in _rs if _r.usd <= 0.0]}"
}

test_postgres_ladder_is_priced_everywhere = lambda {
    # Both HA settings, because postgres/azure bumps off the Burstable family
    # when highAvailability is on and the bumped SKU needs a rate of its own.
    _rs = sum([sum([[lib.db_rate(_p.cloud, _p.region, lib.db_machine(_p.cloud, _gb, _ha)) for _gb in pg_probe_gb] for _ha in [False, True]], []) for _p in places], [])
    assert len(_rs) == len(places) * len(pg_probe_gb) * 2, "every memoryGb the PostgresInstance XRD allows must resolve to a priced instance class on every cloud"
    assert all _r in _rs {_r.usd > 0}, "a managed-Postgres class priced at zero is a missing rate: ${[_r.sku for _r in _rs if _r.usd <= 0.0]}"
}

test_every_region_has_every_table = lambda {
    # The ladders above only exercise compute_hour and db_instance_hour. These
    # are the four scalar tables, so a region added to region_sets with half a
    # block behind it fails here rather than at the first estate that uses it.
    _cp = [lib.control_plane_rate(_p.cloud, _p.region) for _p in places]
    _ds = [lib.db_storage_rate(_p.cloud, _p.region) for _p in places]
    _ob = [lib.object_rate(_p.cloud, _p.region) for _p in places]
    _rd = [lib.root_disk_rate(_p.cloud, _p.region, 30) for _p in places]
    _storage = _ds + _ob + _rd
    assert all _r in _storage {_r.usd > 0}, "no storage rate may be zero"

    # Control planes are the one rate that is legitimately free — AKS leaves
    # skuTier unset, so the cluster/azure backend really is billed nothing for
    # it. Pin the exception so a NEW zero cannot slip in unnoticed.
    assert all _r in _cp {_r.usd > 0 or _r.cloud == "azure"}, "only the Azure (AKS Free tier) control plane may cost nothing: ${[_r.cloud for _r in _cp if _r.usd <= 0.0]}"
}

# ---- comparison: ordering and deltas -----------------------------------------
test_cheapest_first = lambda {
    _c = lib.compare(_item("cluster", {nodeSize = "large", nodeCount = 4}), "us", rates.clouds)
    assert len(_c.estimates) == len(rates.clouds), "a comparison must quote every cloud it was asked for"
    _pairs = range(1, len(_c.estimates))
    assert all _i in _pairs {_c.estimates[_i - 1].usdMonth <= _c.estimates[_i].usdMonth}, "estimates must be sorted cheapest-first, got ${[_e.cloud for _e in _c.estimates]} at ${[_e.usdMonth for _e in _c.estimates]}"
    assert _c.cheapest == _c.estimates[0].cloud, "`cheapest` must name the first estimate's cloud"
}

test_delta_is_measured_from_the_cheapest = lambda {
    _c = lib.compare(_item("postgres", {memoryGb = 8, storageGb = 100}), "us", rates.clouds)
    _floor = _c.estimates[0].usdMonth
    assert _c.estimates[0].deltaUsdMonth == 0, "the cheapest estimate is zero above itself"
    assert _c.estimates[0].deltaPct == 0, "the cheapest estimate is zero percent above itself"
    assert all _e in _c.estimates {_e.deltaUsdMonth == round(_e.usdMonth - _floor, 6)}, "deltaUsdMonth must be this estimate's month minus the cheapest month"
    assert all _e in _c.estimates {_e.deltaPct == round((_e.usdMonth - _floor) / _floor * 100, 2)}, "deltaPct must be the same delta as a percentage of the cheapest"
    assert all _e in _c.estimates {_e.deltaUsdMonth >= 0}, "nothing can be cheaper than the cheapest"
}

test_comparing_a_subset_is_still_a_comparison = lambda {
    _c = lib.compare(_item("bucket", {storageGb = 1000}), "us", ["aws", "gcp"])
    assert [_e.cloud for _e in _c.estimates] == ["gcp", "aws"], "GCS at $0.02/GB-month must undercut S3 at $0.023 for a 1 TB bucket, got ${[_e.cloud for _e in _c.estimates]} at ${[_e.usdMonth for _e in _c.estimates]}"
    assert _c.regions == {aws = "us-east-1", gcp = "us-central1"}, "the reported regions must be exactly the clouds asked for"
}

# ---- arithmetic --------------------------------------------------------------
test_month_is_hour_times_730 = lambda {
    # The 730-hour month is applied in exactly one place (`_compute_month`) and
    # divided back out in exactly one place, so the two figures must agree for
    # every capability — including the bucket, which has no hourly rate at all.
    _es = sum([lib.compare(_i, "us", rates.clouds).estimates for _i in [
        _item("vm", {size = "large", diskGb = 100})
        _item("cluster", {nodeSize = "small", nodeCount = 2})
        _item("postgres", {memoryGb = 4, storageGb = 50})
        _item("bucket", {storageGb = 250})
    ]], [])
    _off = [_e.cloud for _e in _es if abs(_e.usdHour * rates.hours_per_month - _e.usdMonth) >= 0.00001]
    assert not _off, "usdMonth and usdHour must describe the same number, but they disagree on ${_off}"
    assert all _e in _es {round(_e.breakdown.compute + _e.breakdown.storage, 6) == _e.usdMonth}, "the breakdown must add up to the total"
}

test_compute_is_the_rate_times_the_month_times_the_count = lambda {
    # Spelled out on one known cell so the chain rate -> hours -> nodes is
    # pinned by a number a reader can check against rates.k by hand.
    _e = lib.estimate(_item("cluster", {nodeSize = "medium", nodeCount = 3}), "aws", "us-east-1")
    assert _e.machine == "m5.large", "medium must still be m5.large on AWS (cluster/aws owns that mapping)"
    assert _e.breakdown.compute == round(0.096 * 730 * 3 + 0.1 * 730, 6), "3 x m5.large at $0.096/h plus the $0.10/h EKS fee, over a 730-hour month"
    assert _e.breakdown.storage == 0, "cluster worker disks are deliberately unpriced"
}

test_storage_only_items_have_no_compute = lambda {
    _e = lib.estimate(_item("bucket", {storageGb = 500}), "gcp", "us-central1")
    assert _e.breakdown.compute == 0, "a bucket has no compute"
    assert _e.breakdown.storage == round(500 * 0.02, 6), "500 GiB of Cloud Storage Standard at $0.02/GB-month"
    assert _e.usdMonth == _e.breakdown.storage, "a bucket's total is its storage"
}

test_no_silent_zero = lambda {
    # There is no "unknown rate -> 0.0" path: every Rate in every estimate is
    # either positive or the one documented free control plane. If a lookup
    # ever started swallowing a miss, this is what would notice.
    _es = sum([lib.compare(_i, "us", rates.clouds).estimates for _i in [
        _item("vm", {size = "xlarge", diskGb = 200})
        _item("cluster", {nodeSize = "xlarge", nodeCount = 1})
        _item("postgres", {memoryGb = 64, storageGb = 1000})
        _item("bucket", {storageGb = 10})
    ]], [])
    assert all _e in _es {_e.rates}, "every estimate must show the rates it was built from"
    assert all _e in _es {all _r in _e.rates {_r.usd > 0 or _r.sku == "AKS Free tier"}}, "the only rate allowed to be zero is the AKS Free tier control plane"
    assert all _e in _es {_e.usdMonth > 0}, "no estate item is free"
}

# ---- the backend-specific behaviour the estimate must not smooth over ---------
test_azure_bills_the_storage_step_it_rounds_up_to = lambda {
    # postgres/azure rounds storageGb up to a fixed step and Azure bills the
    # step. Pricing the requested size would under-quote every Azure database
    # whose size is not already a step.
    _e = lib.estimate(_item("postgres", {memoryGb = 8, storageGb = 100}), "azure", "eastus")
    assert _e.breakdown.storage == round(128 * 0.115, 6), "100 GiB requested is billed as the 128 GiB step"
    assert any _n in _e.notes {"128 GiB provisioned" in _n}, "the rounding must be reported, not silently charged: ${_e.notes}"
}

test_azure_root_disks_are_billed_by_tier = lambda {
    # Azure sells managed disks from an S-tier ladder, so a 40 GiB disk costs
    # what a 64 GiB S6 costs. A per-GB model would under-quote it by a third.
    _e = lib.estimate(_item("vm", {size = "small", diskGb = 40}), "azure", "eastus")
    assert _e.breakdown.storage == 3.008, "a 40 GiB Azure OS disk is billed as an S6 (64 GiB) at $3.008/month"
    assert "64GiB" in _e.rates[1].sku, "the estimate must name the tier it was billed at, got '${_e.rates[1].sku}'"
}

test_high_availability_is_reported_unpriced_not_guessed = lambda {
    # The card holds single-instance rates only. Doubling them would be an
    # invented number; saying so keeps the estimate honest as a floor.
    _e = lib.estimate(_item("postgres", {memoryGb = 4, highAvailability = True}), "aws", "us-east-1")
    assert any _n in _e.notes {"highAvailability is NOT priced" in _n}, "an HA request must be flagged as unpriced: ${_e.notes}"
}

test_azure_ha_still_prices_the_bumped_sku = lambda {
    # postgres/azure moves off Burstable for HA because Azure rejects it there.
    # The estimate must follow the ladder, not the pre-bump SKU.
    _plain = lib.estimate(_item("postgres", {memoryGb = 4}), "azure", "eastus")
    _ha = lib.estimate(_item("postgres", {memoryGb = 4, highAvailability = True}), "azure", "eastus")
    assert _plain.machine == "B_Standard_B2s", "4 GiB without HA is still Burstable"
    assert _ha.machine == "GP_Standard_D2s_v3", "HA must be priced on the General Purpose SKU the backend would actually render"
    assert _ha.breakdown.compute > _plain.breakdown.compute, "the bump costs money and the estimate must show it"
}

test_machine_type_override_is_priced_as_asked = lambda {
    # The XRDs' escape hatch: an explicit native type bypasses the ladder, so
    # the card must price the type given rather than the rung's default.
    _e = lib.estimate(_item("vm", {size = "small", machineType = "m5.2xlarge", diskGb = 30}), "aws", "us-east-1")
    assert _e.machine == "m5.2xlarge", "an explicit machineType must override the size ladder"
    assert _e.breakdown.compute == round(0.384 * 730, 6), "and must be priced at its own rate, not the rung's"
}

# ---- the report --------------------------------------------------------------
test_render_totals_the_estate_per_cloud = lambda {
    _estate = lib.Estate {items = [
        _item("bucket", {name = "a", storageGb = 100})
        _item("bucket", {name = "b", storageGb = 100})
    ]}
    _docs = lib.render(_estate)
    assert len(_docs) == 3, "one PriceComparison per item plus one PriceSummary"
    _sum = _docs[-1]
    assert _sum.kind == lib.summary_kind, "the last document is the summary"
    assert _docs[0].kind == lib.report_kind and _docs[0].name == "a", "the comparisons come first, in the order the estate listed them"
    assert [_t.cloud for _t in _sum.totals] == ["gcp", "azure", "aws"], "estate totals must be cheapest-first too, got ${[_t.cloud for _t in _sum.totals]} at ${[_t.usdMonth for _t in _sum.totals]}"
    assert _sum.cheapest == "gcp", "200 GiB of standard object storage is cheapest on GCS"
    assert _sum.totals[0].usdMonth == round(200 * 0.02, 6), "two 100 GiB buckets at $0.02/GB-month"
    assert not _sum.mixedAsOf, "the three blocks of the committed card must share an as_of date"
}
