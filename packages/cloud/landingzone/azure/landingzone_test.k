# Tests for landingzone-azure. Run: kcl test
import runtime
import .landingzone as lz
import landingzone_contract.example

_fxXr = lambda _fxSpec {
  {apiVersion = "cloud.example.org/v1alpha1", kind = "LandingZone", metadata = {name = "shl", namespace = "landing-zone"}, spec = _fxSpec | {
    crossplane = {compositionSelector.matchLabels.provider = _fxSpec.provider}
  }}
}

_fxOxr = _fxXr(example.azure | {foundation = example.foundation.azure})

_fxByKey = lambda _fxItems {
  {_i.metadata.annotations["krm.kcl.dev/composition-resource-name"]: _i for _i in _fxItems}
}

_fxVnet = lambda _fxEnv {
  "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/shl-${_fxEnv}/providers/Microsoft.Network/virtualNetworks/shl-${_fxEnv}"
}

_fxNet = lambda _fxEnv, _fxReady {
  {Resource.status = {ready = _fxReady, id = _fxVnet(_fxEnv), subnets = [{name = "nodes", id = _fxVnet(_fxEnv) + "/subnets/nodes"}]}}
}

test_children_kinds_names_and_selectors = lambda {
  _c = _fxByKey(lz.render(_fxOxr, {}))
  assert sorted([_k for _k in _c]) == ["hub", "key-dev", "key-prod", "network-dev", "network-prod"]
  assert _c["network-prod"].kind == "Network" and _c["network-prod"].metadata.name == "shl-prod"
  assert _c["hub"].kind == "NetworkHub" and _c["hub"].metadata.name == "shl-hub"
  assert _c["key-prod"].kind == "EncryptionKey" and _c["key-prod"].metadata.name == "shl-prod-cmek"
  assert all _k, _i in _c {
    _i.metadata.namespace == "landing-zone" and _i.spec.crossplane.compositionSelector.matchLabels.provider == "azure" and _i.spec.deletionPolicy == "Orphan" and _i.spec.tags == {"managed-by" = "landing-zone"} and _i.spec.region == "israelcentral"
  }
}

test_azure_network_is_nodes_only = lambda {
  _n = _fxByKey(lz.render(_fxOxr, {}))["network-dev"].spec
  assert _n.cidr == "10.20.0.0/22" and _n.resourceGroup == "shl-dev"
  assert len(_n.subnets) == 1 and _n.subnets[0].name == "nodes" and _n.subnets[0].cidr == "10.20.0.0/22" and not _n.subnets[0].secondaryRanges
  assert _n.natGateway and _n.allowInternalIngress
}

test_key_in_env_resource_group_with_tenant = lambda {
  _k = _fxByKey(lz.render(_fxOxr, {}))["key-prod"].spec
  assert _k.resourceGroup == "shl-prod" and _k.tenantId == "11111111-2222-3333-4444-555555555555"
  assert _k.purpose == "encrypt-decrypt" and _k.algorithm == "symmetric" and _k.rotationDays == 90
}

test_hub_resource_group_and_cidr = lambda {
  _h = _fxByKey(lz.render(_fxOxr, {}))["hub"].spec
  # The network resource group tier 0 reports; the platform one without it.
  assert _h.resourceGroup == "shl-network" and _h.hubCidr == "10.0.0.0/23" and _h.topology == "isolated"
  _containers = {_k: _v for _k, _v in example.foundation.azure.containers if _k != "network"}
  _x = _fxXr(example.azure | {foundation = example.foundation.azure | {containers = _containers}})
  assert _fxByKey(lz.render(_x, {}))["hub"].spec.resourceGroup == "shl-platform"
}

test_no_foundation_renders_nothing = lambda {
  _x = _fxXr(example.azure)
  assert lz.render(_x, {}) == []
  _st = lz.status(_x, {}).status
  assert _st.ready == False and _st.provider == "azure" and not _st.foundation
}

test_hub_spokes_grow_from_observed_networks = lambda {
  _h0 = _fxByKey(lz.render(_fxOxr, {}))["hub"].spec
  assert [_s.name for _s in _h0.spokes] == ["mgmt"] and _h0.spokes[0].shared and _h0.spokes[0].network == example.foundation.azure.network.mgmt.id
  _h1 = _fxByKey(lz.render(_fxOxr, {"network-prod" = _fxNet("prod", False)}))["hub"].spec
  assert [_s.name for _s in _h1.spokes] == ["mgmt", "prod"] and _h1.spokes[1].network == _fxVnet("prod") and _h1.spokes[1].shared == False
  _h2 = _fxByKey(lz.render(_fxOxr, {"hub" = {Resource.spec = _h1}, "network-dev" = _fxNet("dev", False)}))["hub"].spec
  assert [_s.name for _s in _h2.spokes] == ["mgmt", "dev", "prod"] and _h2.spokes[2].network == _fxVnet("prod")
}

test_cluster_gated_on_network_and_stays = lambda {
  assert "cluster-dev" not in _fxByKey(lz.render(_fxOxr, {"network-dev" = _fxNet("dev", False)}))
  _cl = _fxByKey(lz.render(_fxOxr, {"network-dev" = _fxNet("dev", True)}))["cluster-dev"]
  assert _cl.kind == "KubernetesCluster" and _cl.metadata.name == "shl-dev"
  assert _cl.spec.resourceGroup == "shl-dev" and _cl.spec.network == {subnets = [_fxVnet("dev") + "/subnets/nodes"]}
  assert _cl.spec.nodeSize == "medium" and _cl.spec.nodeCount == 1 and _cl.spec.autoscaling == {min = 1, max = 3} and not _cl.spec.spot
  assert _cl.spec.crossplane.compositionSelector.matchLabels.provider == "azure"
  _again = _fxByKey(lz.render(_fxOxr, {"cluster-dev" = {Resource.spec = _cl.spec}}))["cluster-dev"]
  assert _again.spec.network == _cl.spec.network
}

test_status_aggregates_children = lambda {
  _ocds = {
    "network-dev" = _fxNet("dev", True)
    "network-prod" = _fxNet("prod", True)
    hub = {Resource.status = {ready = True, hubId = "/subscriptions/x/resourceGroups/shl-platform/providers/Microsoft.Network/virtualHubs/shl-hub", attachedCount = 3}}
    "key-prod" = {Resource.status = {ready = True, keyUri = "https://shl-prod-cmek.vault.azure.net/keys/shl-prod-cmek"}}
    "cluster-dev" = {Resource.status = {ready = True, name = "shl-dev", endpoint = "shl-dev.hcp.israelcentral.azmk8s.io"}}
  }
  _s = lz.status(_fxOxr, _ocds).status
  assert _s.ready and _s.provider == "azure" and _s.foundation == example.foundation.azure
  assert _s.hub.attachedCount == 3 and _s.hub.id.endswith("/virtualHubs/shl-hub")
  _dev = _s.environments[0]
  assert _dev.ready and _dev.networkId == _fxVnet("dev") and _dev.subnetIds == [_fxVnet("dev") + "/subnets/nodes"]
  assert _dev.clusterName == "shl-dev" and _dev.clusterEndpoint.endswith("azmk8s.io") and not _dev.keyUri
  assert _s.environments[1].keyUri.endswith("/keys/shl-prod-cmek")
  # Hub not ready → not ready.
  assert not lz.status(_fxOxr, _ocds | {hub = {Resource.status = {ready = False}}}).status.ready
}

test_provider_mismatch_fails = lambda {
  _e = runtime.catch(lambda {
    lz.status(_fxXr(example.gcp | {foundation = example.foundation.gcp}), {})
  })
  assert "landingzone-azure: spec.provider is gcp; this Composition builds azure" in _e, _e
}

test_contract_violation_fails = lambda {
  _e = runtime.catch(lambda {
    lz.render(_fxXr(example.azure | {foundation = example.foundation.azure, environments = [example.azure.environments[0], example.azure.environments[1] | {cidr = "10.20.0.0/16", nodes = "10.20.0.0/22", pods = None, services = None}]}), {})
  })
  assert "landingzone: address plan" in _e and "overlaps" in _e, _e
  # Composed rules too: a foundation without the environment's container.
  _e2 = runtime.catch(lambda {
    lz.render(_fxXr(example.azure | {foundation = example.foundation.azure | {
      containers = {platform = "shl-platform", dev = "shl-dev"}
    }}), {})
  })
  assert "foundation.containers lacks [prod]" in _e2, _e2
}
