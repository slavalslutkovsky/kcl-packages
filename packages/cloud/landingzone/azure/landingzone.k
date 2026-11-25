# landingzone-azure — tier 1 of a LandingZone on Azure (function-kcl module).
#
# Tier 0 (Pulumi, @org/landing-zone) builds the tenant: management groups,
# resource groups, Azure Policy, the platform Key Vault, the mgmt VNet and
# cluster. It writes what it built into spec.foundation. This module reads only
# that and the spec, and composes the per-environment cloud as child XRs in
# cloud.example.org/v1alpha1, each through its own azure Composition:
#
#   network-<env>  Network            the environment's VNet over env.nodes
#                                     only (one subnet `nodes`); pods and
#                                     services are AKS overlay CIDRs outside it
#   hub            NetworkHub         Virtual WAN hub over network.hub.cidr;
#                                     mgmt (shared) + every env spoke
#   key-<env>      EncryptionKey      the environment's Key Vault key
#   cluster-<env>  KubernetesCluster  opt-in AKS cluster in the env subnet
#
# Placement comes from the foundation: every environment child goes into
# foundation.containers[<env>], the hub into containers.network (else
# containers.platform).
#
# Every rule lives in landingzone-contract: contract.checked(oxr) is the first
# thing render and status do, so a broken spec fails every reconcile with the
# contract's message. Without spec.foundation nothing is composed (tier 0 has
# not run yet) and only status is published.
#
# Children are gated on observed status (a spoke needs its VNet's id, a cluster
# its subnet) and, once composed, stay composed: dropping them because a
# status flapped would make Crossplane delete them.
#
# function-kcl v0.12.2 runs an older KCL than the local CLI: keep lambda
# parameter lists on one line.
import landingzone_contract.contract
import network_xrd.models.unknown as net
import hubspoke_xrd.models.v1alpha1.cloud_example_org_v1alpha1_network_hub as hub
import kms_xrd.models.unknown as kms

cloud = "azure"
_api = "cloud.example.org/v1alpha1"

# ── composition-resource-names ───────────────────────────────────────────────
network_key = lambda env: str -> str {
  "network-${env}"
}

key_key = lambda env: str -> str {
  "key-${env}"
}

cluster_key = lambda env: str -> str {
  "cluster-${env}"
}

hub_key = "hub"

# ── observed state ───────────────────────────────────────────────────────────
_observed = lambda ocds, key: str -> any {
  (ocds[key]?.Resource?.status) if key in ocds else Undefined
}

# The spec a child was last composed with (to keep it stable once composed).
_composedSpec = lambda ocds, key: str -> any {
  (ocds[key]?.Resource?.spec) if key in ocds else Undefined
}

_ready = lambda ocds, key: str -> bool {
  (_observed(ocds, key)?.ready or False) == True
}

# The network reference a spoke takes: the VNet resource id.
network_id = lambda ocds, env: str -> str {
  _observed(ocds, network_key(env))?.id or ""
}

subnet_ids = lambda ocds, env: str -> [str] {
  [_s.id for _s in _observed(ocds, network_key(env))?.subnets or [] if _s?.id]
}

# ── children ─────────────────────────────────────────────────────────────────
_child = lambda oxr, key: str, kind: str, name: str, spec: any -> {str:} {
  {
    apiVersion = _api
    kind = kind
    metadata = {
      name = name
      namespace = oxr.metadata?.namespace or "default"
      annotations = {"krm.kcl.dev/composition-resource-name" = key}
    }
    spec = spec
  }
}

_common = lambda s -> {str:} {
  {
    region = s.region
    deletionPolicy = s.deletionPolicy
    tags = s.labels or {}
    crossplane = {compositionSelector.matchLabels.provider = cloud}
  }
}

# The VNet takes the node range only: AKS (Azure CNI Overlay) takes pods and
# services as overlay CIDRs outside the VNet's address space.
_network = lambda oxr, s, e -> {str:} {
  _spec = net.NetworkSpec {
    **_common(s)
    resourceGroup = s.foundation.containers[e.name]
    cidr = e.nodes
    subnets = [{name = "nodes", cidr = e.nodes}]
    natGateway = True
    allowInternalIngress = True
  }
  _child(oxr, network_key(e.name), "Network", "${s.prefix}-${e.name}", _spec)
}

# mgmt always; an environment once its VNet reports an id, and from then on
# whatever it was composed with.
spokes = lambda s, ocds -> [{str:}] {
  _prev = {_p.name: _p.network for _p in _composedSpec(ocds, hub_key)?.spokes or []}
  _mgmt = [{name = "mgmt", network = s.foundation.network.mgmt.id, shared = True}]
  _mgmt + [{name = e.name, network = network_id(ocds, e.name) or _prev[e.name], shared = e.shared or False} for e in s.environments if network_id(ocds, e.name) or _prev[e.name]]
}

_hub = lambda oxr, s, ocds -> {str:} {
  _spec = hub.CloudExampleOrgV1alpha1NetworkHubSpec {
    **_common(s)
    resourceGroup = s.foundation.containers.network or s.foundation.containers.platform
    hubCidr = s.network.hub.cidr
    topology = s.network?.hub?.topology or "isolated"
    spokes = spokes(s, ocds)
  }
  _child(oxr, hub_key, "NetworkHub", "${s.prefix}-hub", _spec)
}

_key = lambda oxr, s, e -> {str:} {
  _spec = kms.EncryptionKeySpec {
    **_common(s)
    resourceGroup = s.foundation.containers[e.name]
    tenantId = s.organization.tenantId
    purpose = "encrypt-decrypt"
    algorithm = "symmetric"
    rotationDays = 90
  }
  _child(oxr, key_key(e.name), "EncryptionKey", contract.environment_key_name(s.prefix, e.name), _spec)
}

# Composed once the environment's network is ready and reports a subnet; kept
# from then on with the subnet it was composed against.
cluster_composed = lambda ocds, e -> bool {
  bool(e.cluster) and (cluster_key(e.name) in ocds or (_ready(ocds, network_key(e.name)) and len(subnet_ids(ocds, e.name)) > 0))
}

_cluster = lambda oxr, s, ocds, e -> {str:} {
  _c = e.cluster
  _subs = subnet_ids(ocds, e.name)
  _network = {subnets = [_subs[0]]} if _subs else _composedSpec(ocds, cluster_key(e.name))?.network
  # 0 is a value (scale to zero), not absence.
  _min = _c.minNodes if _c.minNodes not in [None, Undefined] else 1
  _spec = _common(s) | {
    resourceGroup = s.foundation.containers[e.name]
    if _c.version:
      version = _c.version
    nodeSize = _c.nodeSize or "small"
    if _c.machineType:
      machineType = _c.machineType
    nodeCount = max(1, _min)
    autoscaling = {min = _min, max = _c.maxNodes or 3}
    # No spot: AKS cannot run its default pool on Spot (the contract rejects it).
    network = _network
  }
  _child(oxr, cluster_key(e.name), "KubernetesCluster", "${s.prefix}-${e.name}", _spec)
}

# ── render ───────────────────────────────────────────────────────────────────
_assertCloud = lambda s -> bool {
  assert s.provider == cloud, "landingzone-${cloud}: spec.provider is ${s.provider}; this Composition builds ${cloud}"
  True
}

render = lambda oxr, ocds = {} -> [any] {
  _s = contract.checked(oxr)
  assert _assertCloud(_s)
  _envs = _s.environments if _s.foundation else []
  _networks = [_network(oxr, _s, e) for e in _envs]
  _keys = [_key(oxr, _s, e) for e in _envs]
  _clusters = [_cluster(oxr, _s, ocds, e) for e in _envs if cluster_composed(ocds, e)]
  (_networks + [_hub(oxr, _s, ocds)] + _keys + _clusters) if _s.foundation else []
}

# ── status ───────────────────────────────────────────────────────────────────
_envStatus = lambda ocds, e -> {str:} {
  _net = network_id(ocds, e.name)
  _subs = subnet_ids(ocds, e.name)
  _key = _observed(ocds, key_key(e.name))
  _cl = _observed(ocds, cluster_key(e.name))
  {
    name = e.name
    ready = _ready(ocds, network_key(e.name)) and (not e.cluster or _ready(ocds, cluster_key(e.name)))
    if _net:
      networkId = _net
    if _subs:
      subnetIds = _subs
    if _key?.keyUri:
      keyUri = _key.keyUri
    if _cl?.name:
      clusterName = _cl.name
    if _cl?.endpoint:
      clusterEndpoint = _cl.endpoint
  }
}

status = lambda oxr, ocds = {} -> any {
  _s = contract.checked(oxr)
  assert _assertCloud(_s)
  _hubSt = _observed(ocds, hub_key)
  _envs = [_envStatus(ocds, e) for e in _s.environments]
  {
    apiVersion = oxr?.apiVersion or _api
    kind = oxr?.kind or "LandingZone"
    metadata = {name = oxr.metadata.name, namespace = oxr.metadata?.namespace or "default"}
    status = {
      ready = bool(_s.foundation) and _ready(ocds, hub_key) and all _e in _envs {
        _e.ready
      }
      provider = cloud
      if _s.foundation:
        foundation = oxr.spec.foundation
      if _hubSt:
        hub = {
          if _hubSt?.hubId:
            id = _hubSt.hubId
          attachedCount = _hubSt?.attachedCount or 0
        }
      environments = _envs
    }
  }
}
