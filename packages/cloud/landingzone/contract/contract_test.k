# Tests for the landing-zone contract: both examples pass, and every rule
# fails a spec that breaks it with a message naming the problem.
# Run: kcl test
import runtime
import .contract
import .example

# NOTE: KCL normalizes the leading underscore, so helpers are prefixed `_fx`
# to stay clear of contract.k's private names.
_fxErr = lambda _fxSpec {
  runtime.catch(lambda {
    contract.validate(_fxSpec)
  })
}

_fxEnv = lambda _fxOverrides {
  [example.azure.environments[0] | _fxOverrides]
}

test_examples_pass = lambda {
  assert contract.validate(example.gcp).provider == "gcp"
  assert contract.validate(example.azure).provider == "azure"
}

test_defaults_come_from_the_xrd = lambda {
  _s = contract.validate(example.azure)
  assert _s.deletionPolicy == "Orphan"
  assert _s.guardrails == None or _s.guardrails?.denyPublicIp != False
  assert _s.keys[0].rotationDays == 90
  assert _s.environments[1].shared == False
}

# ── address plan ─────────────────────────────────────────────────────────────
test_unaligned_cidr = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({cidr = "10.20.0.1/16"})})
  assert "not aligned IPv4 CIDRs" in _e and "environment dev block" in _e, _e
}

test_malformed_cidr = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({nodes = "10.20.0/22"})})
  assert "not aligned IPv4 CIDRs" in _e and "environment dev nodes" in _e, _e
}

test_overlapping_blocks = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({cidr = "10.10.0.0/16", nodes = "10.10.200.0/22", pods = None, services = None, cluster = None})})
  assert "mgmt block (10.10.0.0/16) overlaps environment dev block" in _e, _e
}

test_hub_overlaps_a_block = lambda {
  _e = _fxErr(example.azure | {network = example.azure.network | {
    hub = {cidr = "10.20.0.0/23"}
  }})
  assert "hub (10.20.0.0/23) overlaps environment dev block" in _e, _e
}

test_block_outside_address_space = lambda {
  _e = _fxErr(example.azure | {addressSpace = "10.0.0.0/12"})
  assert "environment dev block (10.20.0.0/16) is outside addressSpace" in _e, _e
}

test_range_outside_its_block = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({pods = "10.99.0.0/18"})})
  assert "environment dev pods (10.99.0.0/18) is outside environment dev block" in _e, _e
}

test_ranges_inside_a_block_overlap = lambda {
  _e = _fxErr(example.azure | {network = example.azure.network | {mgmt = example.azure.network.mgmt | {services = "10.10.0.0/22"}}})
  assert "mgmt nodes (10.10.0.0/24) overlaps mgmt services (10.10.0.0/22)" in _e, _e
}

test_cluster_needs_pods_and_services = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({pods = None, services = None})})
  assert "have a cluster but no pods/services ranges" in _e, _e
}

# ── names ────────────────────────────────────────────────────────────────────
test_duplicate_environments = lambda {
  _e = _fxErr(example.azure | {environments = example.azure.environments + [example.azure.environments[1] | {cidr = "10.40.0.0/16", nodes = "10.40.0.0/22", pods = None, services = None}]})
  assert "environment names must be unique" in _e, _e
}

test_reserved_environment_name = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({name = "platform"})})
  assert "reserved for tier-0 scopes" in _e, _e
}

test_keys_need_cluster_secrets_and_audit = lambda {
  _e = _fxErr(example.azure | {keys = [{name = "aa", purpose = "audit"}, {name = "bb"}]})
  assert "exactly one cluster-secrets and one audit key" in _e, _e
}

test_duplicate_keys = lambda {
  _e = _fxErr(example.azure | {keys = example.azure.keys + [{name = "audit"}]})
  assert "key names must be unique" in _e, _e
}

# ── clusters ─────────────────────────────────────────────────────────────────
test_every_pool_tainted = lambda {
  _pools = [_p | {taints = ["a=b:NoSchedule"]} for _p in example.azure.controlPlane.nodePools]
  _e = _fxErr(example.azure | {controlPlane = example.azure.controlPlane | {nodePools = _pools}})
  assert "every node pool is tainted" in _e, _e
}

test_bad_taint = lambda {
  _pools = [example.azure.controlPlane.nodePools[0], example.azure.controlPlane.nodePools[1] | {taints = ["ci"]}]
  _e = _fxErr(example.azure | {controlPlane = example.azure.controlPlane | {nodePools = _pools}})
  assert "taints must be key=value" in _e, _e
}

test_pool_min_above_max = lambda {
  _pools = [example.azure.controlPlane.nodePools[0] | {minNodes = 5}]
  _e = _fxErr(example.azure | {controlPlane = example.azure.controlPlane | {nodePools = _pools}})
  assert "have minNodes > maxNodes" in _e, _e
}

test_environment_cluster_min_above_max = lambda {
  _e = _fxErr(example.azure | {environments = _fxEnv({
    cluster = {minNodes = 4, maxNodes = 2}
  })})
  assert "cluster.minNodes > maxNodes" in _e, _e
}

# ── guardrails ───────────────────────────────────────────────────────────────
test_region_must_be_allowed = lambda {
  _e = _fxErr(example.azure | {
    guardrails = {allowedLocations = ["westeurope"]}
  })
  assert "must contain region israelcentral" in _e, _e
}

test_allowed_locations_default = lambda {
  assert contract.allowed_locations(contract.validate(example.gcp)) == ["me-west1", "europe-west4"]
}

# ── per cloud ────────────────────────────────────────────────────────────────
test_gcp_needs_numeric_org_and_billing = lambda {
  assert "numeric organization id" in _fxErr(example.gcp | {organization = example.gcp.organization | {id = "shluviza.com"}})
  assert "needs organization.billingAccount" in _fxErr(example.gcp | {
    organization = {id = "231525148429", domain = "shluviza.com"}
  })
}

test_gcp_rejects_azure_fields = lambda {
  assert "azure-only" in _fxErr(example.gcp | {organization = example.gcp.organization | {tenantId = example.azure.organization.tenantId}})
}

test_azure_needs_tenant_and_platform_subscription = lambda {
  assert "needs organization.tenantId" in _fxErr(example.azure | {organization = example.azure.organization | {tenantId = "tenant"}})
  assert "subscriptions.platform" in _fxErr(example.azure | {organization = example.azure.organization | {
    subscriptions = {dev = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
  }})
}

test_azure_subscription_keys = lambda {
  _subs = {platform = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", staging = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
  _e = _fxErr(example.azure | {organization = example.azure.organization | {subscriptions = _subs}})
  assert "keys must be platform or an environment" in _e and "staging" in _e, _e
}

test_azure_rejects_billing_account = lambda {
  assert "billingAccount is gcp-only" in _fxErr(example.azure | {organization = example.azure.organization | {billingAccount = "0127E8-28899E-CC1469"}})
}

test_azure_hub_cidr = lambda {
  assert "needs network.hub.cidr" in _fxErr(example.azure | {network = example.azure.network | {
    hub = {topology = "mesh"}
  }})
  assert "/23 or larger" in _fxErr(example.azure | {network = example.azure.network | {
    hub = {cidr = "10.0.0.0/24"}
  }})
}

test_azure_rejects_spot_clusters = lambda {
  assert "cannot run its default pool on Spot" in _fxErr(example.azure | {environments = _fxEnv({
    cluster = {spot = True}
  })})
  # gcp may.
  assert contract.validate(example.gcp | {environments = [example.gcp.environments[0] | {
    cluster = {spot = True}
  }]})
}

# ── composed ─────────────────────────────────────────────────────────────────
_fxXr = lambda _fxSpec {
  {apiVersion = "cloud.example.org/v1alpha1", kind = "LandingZone", metadata = {name = "shl", namespace = "landing-zone"}, spec = _fxSpec | {
    crossplane = {compositionSelector.matchLabels.provider = _fxSpec.provider}
  }}
}

test_checked_without_foundation_is_still_validated = lambda {
  assert not contract.checked(_fxXr(example.azure)).foundation
  assert "reserved" in runtime.catch(lambda {
    contract.checked(_fxXr(example.azure | {environments = _fxEnv({name = "hub"})}))
  })
}

test_composed_needs_every_container = lambda {
  _f = example.foundation.azure | {
    containers = {platform = "shl-platform", dev = "shl-dev"}
  }
  _e = runtime.catch(lambda {
    contract.checked(_fxXr(example.azure | {foundation = _f}))
  })
  assert "foundation.containers lacks [prod]" in _e, _e
}

test_composed_needs_mgmt_network = lambda {
  _f = example.foundation.azure | {
    network = {
      mgmt = {subnet = "x"}
    }
  }
  _e = runtime.catch(lambda {
    contract.checked(_fxXr(example.azure | {foundation = _f}))
  })
  assert "foundation.network.mgmt.id is required" in _e, _e
}

test_composed_passes = lambda {
  assert contract.checked(_fxXr(example.gcp | {foundation = example.foundation.gcp})).foundation.containers.dev == "shl-lz-workloads"
}
