# Tests for the control-plane factory: per-env conventions, overrides, what
# the XRD schemas reject, and the prerequisites report.
# Run: kcl test
import runtime

# Test helpers share the package scope with lib.k: every one is prefixed `_fx`.
_fxDefaults = Defaults {
  spec = {
    region = "me-west1"
    prefix = "demo"
    billingAccount = "000000-000000-000000"
    domain = "example.com"
    keys.gkeSecrets = "projects/demo-security/locations/me-west1/keyRings/cmek/cryptoKeys/gke-secrets"
    cluster = {minNodesPerZone = 1, maxNodesPerZone = 3}
    dns.enabled = False
  }
}

_fxXr = lambda _fxEnv: Env {
  [o for o in render(_fxDefaults, _fxEnv) if o.kind == "Mgmt"][0]
}

test_nonprod_conventions = lambda {
  _x = _fxXr(Env {name = "dev"})
  assert _x.metadata.namespace == "cp-dev"
  assert _x.spec.projectId == "demo-mgmt-dev"
  assert _x.spec.folders.platform == "\${DEV_FOLDER_ID}"
  assert _x.spec.cluster.name == "mgmt-dev"
  assert _x.spec.network.hostProject == "demo-net-dev"
  assert _x.spec.network.subnetwork.endswith("/regions/me-west1/subnetworks/mgmt-dev")
  assert not _x.spec.providerConfigName
}

test_prod_runs_as_prod_provider_config = lambda {
  _x = _fxXr(Env {name = "prod"})
  assert _x.spec.providerConfigName == "prod"
  assert _x.spec.network.hostProject == "demo-net-prod"
  # Any env may be prod; the name only picks the default tier.
  assert _fxXr(Env {name = "eu", tier = "prod"}).spec.providerConfigName == "prod"
}

test_env_spec_merges_over_defaults = lambda {
  _x = _fxXr(Env {name = "qa", spec = {zone = "me-west1-c", cluster.maxNodesPerZone = 6}})
  assert _x.spec.zone == "me-west1-c"
  assert _x.spec.cluster.maxNodesPerZone == 6
  assert _x.spec.cluster.minNodesPerZone == 1
  assert _x.spec.cluster.name == "mgmt-qa"
}

# runtime.catch returns the error message, or Undefined when nothing failed.
# The generated XRD checks carry no message, so a pattern failure returns "".
_fxFails = lambda _fxEnv: Env -> bool {
  typeof(runtime.catch(lambda {
    _fxXr(_fxEnv)
  })) == "str"
}

test_xrd_rejects_unknown_fields = lambda {
  assert "No attribute named 'nodeMachineType'" in runtime.catch(lambda {
    _fxXr(Env {name = "qa", spec = {nodeMachineType = "e2-standard-8"}})
  }), "nodeMachineType belongs under cluster"
}

test_xrd_rejects_bad_billing_account = lambda {
  assert _fxFails(Env {name = "qa", spec = {billingAccount = "REPLACE_ME"}})
  assert not _fxFails(Env {name = "qa"})
}

test_xrd_rejects_long_project_id = lambda {
  # averylongprefix-mgmt-abcdefghijkl: 33 characters, GCP allows 30.
  assert _fxFails(Env {name = "abcdefghijkl", spec = {prefix = "averylongprefix"}})
}

test_env_name_shape = lambda {
  assert "needs 2-12 characters" in runtime.catch(lambda {
    Env {name = "Dev_1"}
  })
}

test_prerequisites = lambda {
  _r = prerequisites(_fxDefaults, Env {name = "dev"})
  assert _r.identity == "crossplane@"
  assert any_true(["DEV_FOLDER_ID in cluster-identity" in g for g in _r.gitops])
  assert len(_r.keys) == 1, "the shared security key needs a grant"
  assert _r.other == []
  _own = prerequisites(_fxDefaults, Env {name = "dev", folder = "123456789012", spec = {keys.gkeSecrets = "projects/demo-mgmt-dev/locations/me-west1/keyRings/k/cryptoKeys/gke", postgres.enabled = True, keys.cloudsql = "projects/demo-mgmt-dev/locations/me-west1/keyRings/k/cryptoKeys/sql"}})
  assert _own.keys == [], "keys in the env's own project need no foreign grant"
  assert not any_true(["cluster-identity" in g for g in _own.gitops]), "a literal folder id needs no substitution"
  assert any_true(["sqladmin.googleapis.com" in o for o in _own.other])
}
