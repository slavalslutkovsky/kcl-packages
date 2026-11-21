# Tests for the mgmt stack spec: stack-file parsing, the toggles, and the
# checks that keep a bad config or a URN collision from rendering.
# Run: kcl test
import runtime

# Test helpers share the package scope with lib.k: every one is prefixed `_fx`.
_fxStack = lambda _fxMgmt: {str:} {
  {
    config = {
      "gcp:region" = "me-west1"
      "org:orgId" = "123456789012"
      "org:customerId" = "C0demo00"
      "org:billingAccount" = "000000-000000-000000"
      "org:orgDomain" = "example.com"
      "org:bootstrapUser" = "admin@example.com"
      "org:githubOrg" = "example"
      "org:prefix" = "demo"
      "other:ignored" = "x"
    } | {"mgmt:${k}" = v for k, v in _fxMgmt}
  }
}

_fxRender = lambda _fxMgmt: {str:} {
  render(fromStack(_fxStack(_fxMgmt), "mgmt"), "mgmt", "prod")
}

_fxErr = lambda _fxMgmt: {str:} {
  runtime.catch(lambda {
    _fxRender(_fxMgmt)
  })
}

_fxNames = lambda _fxSpec, _fxType: str {
  [r.name for _, r in _fxSpec.resources if r.$type == _fxType]
}

test_stack_strings_are_typed_like_pulumi_config = lambda {
  _c = fromStack(_fxStack({postgres = "true", minNodesPerZone = "4"}), "mgmt")
  assert _c.mgmt.postgres == True
  assert _c.mgmt.minNodesPerZone == 4
  assert "is not a boolean" in _fxErr({postgres = "yes"})
  assert "is not an integer" in _fxErr({minNodesPerZone = "three"})
}

test_unknown_mgmt_key_fails = lambda {
  assert _fxErr({nodeMachinType = "e2-standard-8"}) != ""
}

test_org_shape_is_checked = lambda {
  _s = _fxStack({})
  _bad = {config = _s.config | {"org:billingAccount" = "REPLACE_ME"}}
  assert "not a billing account id" in runtime.catch(lambda {
    fromStack(_bad, "mgmt")
  })
}

test_postgres_toggle = lambda {
  _off = _fxRender({})
  assert _fxNames(_off, "app:db:PostgresInstance") == []
  assert "postgresPrivateIp" not in _off.outputs
  _on = _fxRender({postgres = "true"})
  assert _fxNames(_on, "app:db:PostgresDatabase") == ["mgmt-postgres-events", "mgmt-postgres-terran", "mgmt-postgres-todo", "mgmt-postgres-flagsmith"]
  assert _on.resources.cloudSql.options.dependsOn == ["\${apis}", "\${cloudsqlKeyGrant}"]
}

test_flux_bootstrap_needs_operator_version = lambda {
  assert "fluxOperatorVersion" in _fxErr({fluxBootstrap = "true"})
  _s = _fxRender({fluxBootstrap = "true", fluxOperatorVersion = "0.61.0"})
  assert _s.fluxBootstrap.args.webHostname == "flux.example.com"
  assert _s.fluxBootstrap.args.clusterIdentity.GCP_PROJECT_PREFIX == "demo"
  _off = _fxRender({})
  assert not _off.fluxBootstrap
}

test_prod_folder_gets_no_shared_vpc_admin = lambda {
  _folders = _fxNames(_fxRender({}), "gcp:folder/iAMMember:IAMMember")
  assert "crossplane-dev-compute-xpnAdmin" in _folders
  assert "crossplane-staging-compute-xpnAdmin" in _folders
  assert "crossplane-prod-compute-xpnAdmin" not in _folders
}

test_same_logical_name_on_different_types = lambda {
  # index.ts names the Project, the Binary Authorization policy and the cluster `mgmt`.
  _s = _fxRender({})
  assert [r.$type for _, r in _s.resources if r.name == "mgmt"] == ["gcp:organizations/project:Project", "gcp:binaryauthorization/policy:Policy", "org:gcp-gke:GkeCluster"]
}

test_urn_collision_fails = lambda {
  _r = Resource {$type = "gcp:projects/iAMMember:IAMMember", name = "dup", properties = {}}
  assert "URNs would collide" in runtime.catch(lambda {
    Spec {project = "mgmt", stack = "prod", config = fromStack(_fxStack({}), "mgmt"), variables = {}, resources = {a = _r, b = _r}, outputs = {}}
  })
}

test_cluster_needs_an_untainted_pool = lambda {
  _taint = NodeTaint {key = "k", value = "v", effect = "NO_SCHEDULE"}
  assert "every node pool is tainted" in runtime.catch(lambda {
    GkeClusterArgs {
      project = "p"
      name = "c"
      location = "me-west1-a"
      network = "n"
      subnetwork = "s"
      podsRange = "pods"
      servicesRange = "services"
      nodeServiceAccount = "sa"
      databaseEncryptionKey = "k"
      securityGroup = "g"
      nodePools = {
        only = NodePoolSpec {machineType = "e2-standard-4", minNodesPerZone = 0, maxNodesPerZone = 1, taints = [_taint]}
      }
    }
  })
}
