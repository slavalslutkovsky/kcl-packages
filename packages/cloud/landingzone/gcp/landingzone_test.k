# Tests for landingzone-gcp. Run: kcl test
import runtime
import .landingzone as lz
import landingzone_contract.example

_fxXr = lambda _fxSpec {
  {apiVersion = "cloud.example.org/v1alpha1", kind = "LandingZone", metadata = {name = "shl", namespace = "landing-zone"}, spec = _fxSpec | {
    crossplane = {compositionSelector.matchLabels.provider = _fxSpec.provider}
  }}
}

_fxOxr = _fxXr(example.gcp | {foundation = example.foundation.gcp})

_fxByKey = lambda _fxItems {
  {_i.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _i for _i in _fxItems}
}

_fxNet = lambda _fxEnv, _fxReady {
  {Resource.status = {ready = _fxReady, selfLink = "projects/shl-lz-workloads/global/networks/shl-${_fxEnv}", subnets = [{name = "shl-${_fxEnv}-me-west1", selfLink = "projects/shl-lz-workloads/regions/me-west1/subnetworks/shl-${_fxEnv}-me-west1"}]}}
}

test_children_kinds_names_and_selectors = lambda {
  _c = _fxByKey(lz.render(_fxOxr, {}))
  assert sorted([_k for _k in _c]) == ["hub", "key-dev", "key-prod", "network-dev", "network-prod"]
  assert _c["network-dev"].kind == "Network" and _c["network-dev"].metadata.name == "shl-dev"
  assert _c["hub"].kind == "NetworkHub" and _c["hub"].metadata.name == "shl-hub"
  assert _c["key-dev"].kind == "EncryptionKey" and _c["key-dev"].metadata.name == "shl-dev-cmek"
  assert all _k, _i in _c {
    _i.metadata.namespace == "landing-zone" and _i.spec.crossplane.compositionSelector.matchLabels.provider == "gcp" and _i.spec.deletionPolicy == "Orphan" and _i.spec.tags == {"managed-by" = "landing-zone"}
  }
}

test_gcp_network_is_block_with_secondary_ranges = lambda {
  _n = _fxByKey(lz.render(_fxOxr, {}))["network-dev"].spec
  assert _n.cidr == "10.20.0.0/16" and _n.region == "me-west1"
  assert _n.subnets[0].name == "shl-dev-me-west1" and _n.subnets[0].cidr == "10.20.0.0/22"
  assert _n.subnets[0].secondaryRanges == {pods = "10.20.64.0/18", services = "10.20.16.0/20"}
  assert _n.natGateway and _n.allowInternalIngress
  assert not _n.resourceGroup
}

test_key_spec = lambda {
  _k = _fxByKey(lz.render(_fxOxr, {}))["key-prod"].spec
  assert _k.purpose == "encrypt-decrypt" and _k.algorithm == "symmetric" and _k.rotationDays == 90
  assert not _k.tenantId and not _k.resourceGroup
}

test_no_foundation_renders_nothing = lambda {
  _x = _fxXr(example.gcp)
  assert lz.render(_x, {}) == []
  _st = lz.status(_x, {}).status
  assert _st.ready == False and _st.provider == "gcp" and not _st.foundation
}

test_hub_spokes_grow_from_observed_networks = lambda {
  _h0 = _fxByKey(lz.render(_fxOxr, {}))["hub"].spec
  assert _h0.topology == "isolated" and not _h0.hubCidr
  assert [_s.name for _s in _h0.spokes] == ["mgmt"] and _h0.spokes[0].shared and _h0.spokes[0].network == "projects/shl-lz-net/global/networks/mgmt"
  _h1 = _fxByKey(lz.render(_fxOxr, {"network-dev" = _fxNet("dev", False)}))["hub"].spec
  assert [_s.name for _s in _h1.spokes] == ["mgmt", "dev"]
  assert _h1.spokes[1].network == "projects/shl-lz-workloads/global/networks/shl-dev" and _h1.spokes[1].shared == False
  # The dev network's status flaps: the spoke stays.
  _h2 = _fxByKey(lz.render(_fxOxr, {"hub" = {Resource.spec = _h1}}))["hub"].spec
  assert [_s.name for _s in _h2.spokes] == ["mgmt", "dev"] and _h2.spokes[1].network == _h1.spokes[1].network
}

test_cluster_gated_on_network_and_stays = lambda {
  assert "cluster-dev" not in _fxByKey(lz.render(_fxOxr, {"network-dev" = _fxNet("dev", False)}))
  _c = _fxByKey(lz.render(_fxOxr, {"network-dev" = _fxNet("dev", True), "network-prod" = _fxNet("prod", True)}))
  # prod has no cluster.
  assert "cluster-prod" not in _c
  _cl = _c["cluster-dev"]
  assert _cl.kind == "KubernetesCluster" and _cl.metadata.name == "shl-dev"
  assert _cl.spec.network == {id = "projects/shl-lz-workloads/global/networks/shl-dev", subnets = ["projects/shl-lz-workloads/regions/me-west1/subnetworks/shl-dev-me-west1"]}
  assert _cl.spec.nodeSize == "medium" and _cl.spec.nodeCount == 1 and _cl.spec.autoscaling == {min = 1, max = 3} and _cl.spec.spot == False
  assert _cl.spec.crossplane.compositionSelector.matchLabels.provider == "gcp"
  # Network flaps after the cluster was composed: it stays, on the same network.
  _again = _fxByKey(lz.render(_fxOxr, {"cluster-dev" = {Resource.spec = _cl.spec}}))["cluster-dev"]
  assert _again.spec.network == _cl.spec.network
}

test_cluster_spot_and_min_zero = lambda {
  _x = _fxXr(example.gcp | {foundation = example.foundation.gcp, environments = [example.gcp.environments[0] | {
    cluster = {minNodes = 0, maxNodes = 4, spot = True, machineType = "e2-standard-4", version = "1.32"}
  }, example.gcp.environments[1]]})
  _cl = _fxByKey(lz.render(_x, {"network-dev" = _fxNet("dev", True)}))["cluster-dev"].spec
  assert _cl.nodeCount == 1 and _cl.autoscaling == {min = 0, max = 4} and _cl.spot and _cl.machineType == "e2-standard-4" and _cl.version == "1.32"
}

test_status_aggregates_children = lambda {
  _ocds = {
    "network-dev" = _fxNet("dev", True)
    "network-prod" = _fxNet("prod", True)
    hub = {Resource.status = {ready = True, hubId = "projects/shl-lz-net/locations/global/hubs/shl-hub", attachedCount = 3}}
    "key-dev" = {Resource.status = {ready = True, keyUri = "projects/shl-lz-workloads/locations/me-west1/keyRings/shl/cryptoKeys/shl-dev-cmek"}}
    "cluster-dev" = {Resource.status = {ready = True, name = "shl-dev", endpoint = "10.20.0.2"}}
  }
  _st = lz.status(_fxOxr, _ocds)
  assert _st.kind == "LandingZone" and _st.metadata.name == "shl"
  _s = _st.status
  assert _s.ready and _s.provider == "gcp" and _s.foundation == example.foundation.gcp
  assert _s.hub == {id = "projects/shl-lz-net/locations/global/hubs/shl-hub", attachedCount = 3}
  _dev = _s.environments[0]
  assert _dev.name == "dev" and _dev.ready and _dev.networkId == "projects/shl-lz-workloads/global/networks/shl-dev"
  assert _dev.subnetIds == ["projects/shl-lz-workloads/regions/me-west1/subnetworks/shl-dev-me-west1"]
  assert _dev.keyUri.endswith("shl-dev-cmek") and _dev.clusterName == "shl-dev" and _dev.clusterEndpoint == "10.20.0.2"
  _prod = _s.environments[1]
  assert _prod.ready and not _prod.keyUri and not _prod.clusterName
  # dev's cluster not ready → not ready.
  assert not lz.status(_fxOxr, _ocds | {"cluster-dev" = {Resource.status = {ready = False}}}).status.ready
  # Nothing observed: environments listed, nothing invented.
  _empty = lz.status(_fxOxr, {}).status
  assert not _empty.ready and not _empty.hub and _empty.environments[0] == {name = "dev", ready = False}
}

test_provider_mismatch_fails = lambda {
  _e = runtime.catch(lambda {
    lz.render(_fxXr(example.azure | {foundation = example.foundation.azure}), {})
  })
  assert "landingzone-gcp: spec.provider is azure; this Composition builds gcp" in _e, _e
}

test_contract_violation_fails = lambda {
  _e = runtime.catch(lambda {
    lz.render(_fxXr(example.gcp | {foundation = example.foundation.gcp, environments = [example.gcp.environments[0], example.gcp.environments[1] | {cidr = "10.20.0.0/16", nodes = "10.20.0.0/22", pods = None, services = None}]}), {})
  })
  assert "landingzone: address plan" in _e and "overlaps" in _e, _e
}
