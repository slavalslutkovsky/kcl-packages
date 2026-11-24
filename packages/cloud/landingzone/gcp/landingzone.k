# landingzone-gcp — tier 1 of a LandingZone on GCP (function-kcl module).
#
# Tier 0 (Pulumi, @org/landing-zone) builds the organization: folders,
# projects, guardrails, platform keys, the mgmt network and cluster. It writes
# what it built into spec.foundation. This module reads only that and the
# spec, and composes the per-environment cloud as child XRs in
# cloud.example.org/v1alpha1, each through its own gcp Composition:
#
#   network-<env>  Network            the environment's VPC: block = env.cidr,
#                                     one subnetwork over env.nodes with the
#                                     pods / services secondary ranges
#   hub            NetworkHub         NCC hub; mgmt (shared) + every env spoke
#   key-<env>      EncryptionKey      the environment's CMEK
#   cluster-<env>  KubernetesCluster  opt-in GKE cluster in the env network
#
# Every rule lives in landingzone-contract: contract.checked(oxr) is the first
# thing render and status do, so a broken spec fails every reconcile with the
# contract's message. Without spec.foundation nothing is composed (tier 0 has
# not run yet) and only status is published.
#
# Children are gated on observed status (a spoke needs its network's self
# link, a cluster its subnetwork) and, once composed, stay composed: dropping
# them because a status flapped would make Crossplane delete them.
#
# function-kcl v0.12.2 runs an older KCL than the local CLI: keep lambda
# parameter lists on one line.
import landingzone_contract.contract
import network_xrd.models.unknown as net
import hubspoke_xrd.models.v1alpha1.cloud_example_org_v1alpha1_network_hub as hub
import kms_xrd.models.unknown as kms

cloud = "gcp"
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

# The network reference a spoke / cluster takes: the VPC self link.
network_id = lambda ocds, env: str -> str {
  _observed(ocds, network_key(env))?.selfLink or ""
}

subnet_ids = lambda ocds, env: str -> [str] {
  [_s.selfLink for _s in _observed(ocds, network_key(env))?.subnets or [] if _s?.selfLink]
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

_network = lambda oxr, s, e -> {str:} {
  _ranges = {
    if e.pods:
      pods = e.pods
    if e.services:
      services = e.services
  }
  _spec = net.NetworkSpec {
    **_common(s)
    cidr = e.cidr
    subnets = [{
      name = "${s.prefix}-${e.name}-${s.region}"
      cidr = e.nodes
      if _ranges:
        secondaryRanges = _ranges
    }]
    natGateway = True
    allowInternalIngress = True
  }
  _child(oxr, network_key(e.name), "Network", "${s.prefix}-${e.name}", _spec)
}

# mgmt always; an environment once its network reports a self link, and from
# then on whatever it was composed with.
spokes = lambda s, ocds -> [{str:}] {
  _prev = {_p.name: _p.network for _p in _composedSpec(ocds, hub_key)?.spokes or []}
  _mgmt = [{name = "mgmt", network = s.foundation.network.mgmt.id, shared = True}]
  _mgmt + [{name = e.name, network = network_id(ocds, e.name) or _prev[e.name], shared = e.shared or False} for e in s.environments if network_id(ocds, e.name) or _prev[e.name]]
}

_hub = lambda oxr, s, ocds -> {str:} {
  _spec = hub.CloudExampleOrgV1alpha1NetworkHubSpec {
    **_common(s)
    topology = s.network?.hub?.topology or "isolated"
    spokes = spokes(s, ocds)
  }
  _child(oxr, hub_key, "NetworkHub", "${s.prefix}-hub", _spec)
}

_key = lambda oxr, s, e -> {str:} {
  _spec = kms.EncryptionKeySpec {
    **_common(s)
    purpose = "encrypt-decrypt"
    algorithm = "symmetric"
    rotationDays = 90
  }
  _child(oxr, key_key(e.name), "EncryptionKey", contract.environment_key_name(s.prefix, e.name), _spec)
}

# Composed once the environment's network is ready and reports a subnetwork;
# kept from then on with the network it was composed against.
cluster_composed = lambda ocds, e -> bool {
  bool(e.cluster) and (cluster_key(e.name) in ocds or (_ready(ocds, network_key(e.name)) and len(subnet_ids(ocds, e.name)) > 0))
}

_cluster = lambda oxr, s, ocds, e -> {str:} {
  _c = e.cluster
  _subs = subnet_ids(ocds, e.name)
  _prev = _composedSpec(ocds, cluster_key(e.name))?.network
  _network = {id = network_id(ocds, e.name), subnets = [_subs[0]]} if _subs and network_id(ocds, e.name) else _prev
  # 0 is a value (scale to zero), not absence.
  _min = _c.minNodes if _c.minNodes not in [None, Undefined] else 1
  _spec = _common(s) | {
    if _c.version:
      version = _c.version
    nodeSize = _c.nodeSize or "small"
    if _c.machineType:
      machineType = _c.machineType
    nodeCount = max(1, _min)
    autoscaling = {min = _min, max = _c.maxNodes or 3}
    spot = _c.spot or False
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
