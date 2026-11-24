# landingzone-contract — the one set of rules a LandingZone spec must satisfy.
#
# The shape comes from ../xrd/xrd.yaml (generated into landingzone-xrd by
# `just xrd-schema landingzone`, which also carries the XRD's patterns and
# bounds as check: lines). This package adds the rules a schema cannot say:
# the address plan, cross-field requirements and the per-cloud limits.
#
# One rule set, three callers:
#   landingzone-gcp / landingzone-azure   Composition functions: `Composed`
#                                         (spec + the tier-0 foundation)
#   @org/landing-zone (Pulumi, infra)     `kcl run` on this package's main.k
#                                         before tier 0 creates anything, and
#                                         takes the defaulted spec back
#
# function-kcl v0.12.2 runs an older KCL than the local CLI: keep lambda
# parameter lists on one line.
import regex
import landingzone_xrd.models.unknown as xrd

# Names tier 0 already uses for its own scopes and containers; an environment
# by one of these names would collide with them.
reserved_names = ["root", "platform", "mgmt", "hub", "network", "security", "audit"]

key_purposes_required = ["cluster-secrets", "audit"]

# ---- IPv4 CIDRs -------------------------------------------------------------
_octet_ok = lambda o: str -> bool {
  o.isdigit() and len(o) <= 3 and int(o) <= 255
}

# True for a well-formed IPv4 CIDR. Alignment is a separate rule (aligned), so
# that an error names the actual problem.
is_cidr = lambda c: str -> bool {
  _p = (c or "").split("/")
  _o = _p[0].split(".") if len(_p) == 2 else []
  len(_p) == 2 and len(_o) == 4 and all x in _o {
    _octet_ok(x)
  } and _p[1].isdigit() and len(_p[1]) <= 2 and int(_p[1]) <= 32
}

# First and last address as integers, None for a malformed CIDR, so that rules
# built on it never crash before the is_cidr rule reports the real problem.
cidr_range = lambda c: str -> {str:int} {
  _p = (c or "").split("/")
  _o = [int(x) for x in _p[0].split(".")] if is_cidr(c) else []
  _bits = int(_p[1]) if is_cidr(c) else 0
  _start = ((_o[0] * 256 + _o[1]) * 256 + _o[2]) * 256 + _o[3] if is_cidr(c) else 0
  {start = _start, end = _start + (1 << (32 - _bits)) - 1, bits = _bits} if is_cidr(c) else None
}

# Host bits clear: both clouds reject 10.0.0.1/16 at apply time.
aligned = lambda c: str -> bool {
  _r = cidr_range(c)
  _r != None and _r.start % (1 << (32 - _r.bits)) == 0
}

overlaps = lambda a: str, b: str -> bool {
  _x = cidr_range(a)
  _y = cidr_range(b)
  _x != None and _y != None and _x.start <= _y.end and _y.start <= _x.end
}

within = lambda outer: str, inner: str -> bool {
  _x = cidr_range(outer)
  _y = cidr_range(inner)
  _x != None and _y != None and _x.start <= _y.start and _y.end <= _x.end
}

# Every overlapping pair in a list of {label, cidr}, as messages.
conflicts = lambda rs: [{str:str}] -> [str] {
  ["${a.label} (${a.cidr}) overlaps ${b.label} (${b.cidr})" for i, a in rs for j, b in rs if i < j and overlaps(a.cidr, b.cidr)]
}

# Every range in rs outside outer, as messages.
outside = lambda outer: {str:str}, rs: [{str:str}] -> [str] {
  ["${r.label} (${r.cidr}) is outside ${outer.label} (${outer.cidr})" for r in rs if not within(outer.cidr, r.cidr)]
}

# ---- derived values both backends share --------------------------------------
# The ranges inside one block: nodes always, pods and services when given.
inner_ranges = lambda owner: str, b: any -> [{str:str}] {
  [{label = "${owner} ${_k}", cidr = b[_k]} for _k in ["nodes", "pods", "services"] if b[_k]]
}

blocks = lambda network: any, environments: [any] -> [{str:str}] {
  _hub = network?.hub?.cidr
  [{label = "mgmt block", cidr = network.mgmt.cidr}] + ([{label = "hub", cidr = _hub}] if _hub else []) + [{label = "environment ${e.name} block", cidr = e.cidr} for e in environments]
}

# guardrails.allowedLocations, or [region, backupRegion] when it is empty.
locations = lambda guardrails: any, region: str, backupRegion: str -> [str] {
  guardrails?.allowedLocations or [region] + ([backupRegion] if backupRegion else [])
}

allowed_locations = lambda s: any -> [str] {
  locations(s.guardrails, s.region, s.backupRegion)
}

# The KSA gitops' DeploymentRuntimeConfig runs the providers as.
crossplane_service_account = lambda s: any -> str {
  s.controlPlane?.crossplane?.serviceAccount or "crossplane-${s.provider}"
}

# Child XR names. Azure Key Vault names are global, 3-24 characters: prefix
# (<= 6) + environment (<= 10) + "-" + "-cmek" stays at 22.
environment_key_name = lambda prefix: str, env: str -> str {
  "${prefix}-${env}-cmek"
}

_guid = r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
_taint = r"^[^=:\s]+=[^:\s]*:(NoSchedule|PreferNoSchedule|NoExecute)$"

# ---- the rules ----------------------------------------------------------------
schema LandingZone(xrd.LandingZoneSpec):
  """A LandingZone spec that every backend can build. Instantiating it runs
    the generated shape checks and the rules below; the first failing rule
    fails the render (Crossplane) or the preview (Pulumi) with its message."""
  _envs = [e.name for e in environments]
  _keyNames = [k.name for k in keys]
  _purposes = [k.purpose or "generic" for k in keys]
  _pools = controlPlane.nodePools
  _poolNames = [p.name for p in _pools]
  _mgmt = network.mgmt
  _hubCidr = network?.hub?.cidr
  _subs = organization?.subscriptions or {}

  _space = {label = "addressSpace", cidr = addressSpace}
  _blocks = blocks(network, environments)
  _mgmtRanges = inner_ranges("mgmt", _mgmt)
  _allCidrs = [_space] + _blocks + _mgmtRanges + [_r for e in environments for _r in inner_ranges("environment ${e.name}", e)]
  _badCidrs = ["${r.label} (${r.cidr})" for r in _allCidrs if not aligned(r.cidr)]
  _planErrors = outside(_space, _blocks) + conflicts(_blocks) + outside({label = "mgmt block", cidr = _mgmt.cidr}, _mgmtRanges) + conflicts(_mgmtRanges) + [_m for e in environments for _m in outside({label = "environment ${e.name} block", cidr = e.cidr}, inner_ranges("environment ${e.name}", e)) + conflicts(inner_ranges("environment ${e.name}", e))]
  _locations = locations(guardrails, region, backupRegion)

  _reserved = [n for n in _envs if n in reserved_names]
  _envMissingRanges = [e.name for e in environments if e.cluster and not (e.pods and e.services)]
  _envBadSize = [e.name for e in environments if e.cluster and (e.cluster.minNodes or 1) > (e.cluster.maxNodes or 3)]
  _envSpot = [e.name for e in environments if e.cluster?.spot]
  _poolBadSize = [p.name for p in _pools if p.minNodes > p.maxNodes]
  _badTaints = ["${p.name}: ${t}" for p in _pools for t in p.taints or [] if not regex.match(t, _taint)]
  _badSubs = ["${k}" for k, v in _subs if not regex.match(v, _guid) or k not in ["platform"] + _envs]
  _acr = "${prefix}${registry?.name or 'platform'}"

  check:
    # Address plan. One message per class of mistake, naming every range in it.
    not _badCidrs, "landingzone: not aligned IPv4 CIDRs: ${_badCidrs}"
    # Only once every CIDR parses: a malformed one is reported above, not as an overlap.
    not _planErrors if not _badCidrs, "landingzone: address plan: ${_planErrors}"
    not _envMissingRanges, "landingzone: environments ${_envMissingRanges} have a cluster but no pods/services ranges"
    # Names.
    len(_envs) == len({n: 1 for n in _envs}), "landingzone: environment names must be unique, got ${_envs}"
    not _reserved, "landingzone: environment names ${_reserved} are reserved for tier-0 scopes"
    len(_keyNames) == len({n: 1 for n in _keyNames}), "landingzone: key names must be unique, got ${_keyNames}"
    all p in key_purposes_required {
      len([q for q in _purposes if q == p]) == 1
    }, "landingzone: keys need exactly one cluster-secrets and one audit key, got purposes ${_purposes}"
    # Clusters.
    not _envBadSize, "landingzone: environments ${_envBadSize} have cluster.minNodes > maxNodes"
    len(_poolNames) == len({n: 1 for n in _poolNames}), "landingzone: controlPlane.nodePools names must be unique, got ${_poolNames}"
    not _poolBadSize, "landingzone: node pools ${_poolBadSize} have minNodes > maxNodes"
    not _badTaints, "landingzone: taints must be key=value:NoSchedule|PreferNoSchedule|NoExecute: ${_badTaints}"
    any p in _pools {
      not p.taints
    }, "landingzone: every node pool is tainted; system pods need an untainted one"
    # Guardrails.
    region in _locations, "landingzone: guardrails.allowedLocations ${_locations} must contain region ${region}"
    # gcp.
    regex.match(organization.id, r"^\d{10,14}$") if provider == "gcp", "landingzone: gcp organization.id must be the numeric organization id, got ${organization.id}"
    regex.match(organization?.billingAccount or "", r"^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$") if provider == "gcp", "landingzone: gcp needs organization.billingAccount (XXXXXX-XXXXXX-XXXXXX)"
    not (organization?.tenantId or _subs) if provider == "gcp", "landingzone: organization.tenantId and organization.subscriptions are azure-only"
    # azure.
    regex.match(organization?.tenantId or "", _guid) if provider == "azure", "landingzone: azure needs organization.tenantId (a GUID)"
    regex.match(_subs?.platform or "", _guid) if provider == "azure", "landingzone: azure needs organization.subscriptions.platform (a GUID): tier 0 lives there and Crossplane composes into it"
    not _badSubs if provider == "azure", "landingzone: organization.subscriptions keys must be platform or an environment and values GUIDs: ${_badSubs}"
    not organization?.billingAccount if provider == "azure", "landingzone: organization.billingAccount is gcp-only (azure subscriptions carry their billing)"
    bool(_hubCidr) if provider == "azure", "landingzone: azure needs network.hub.cidr (the Virtual Hub's own /23 or larger)"
    (cidr_range(_hubCidr)?.bits or 32) <= 23 if provider == "azure" and _hubCidr, "landingzone: network.hub.cidr ${_hubCidr} must be /23 or larger"
    not _envSpot if provider == "azure", "landingzone: AKS cannot run its default pool on Spot: environments ${_envSpot}"
    len(_acr) >= 5 if provider == "azure", "landingzone: the ACR name ${_acr} needs at least 5 characters"

schema Composed(LandingZone):
  """What a Composition needs: the spec plus every tier-0 fact it reads.
    Pulumi writes spec.foundation when it creates the XR; until then the
    Compositions render only status."""
  _f = foundation or {}
  _missingContainers = [n for n in ["platform"] + [e.name for e in environments] if not (_f?.containers or {})[n]]

  check:
    not _missingContainers, "landingzone: spec.foundation.containers lacks ${_missingContainers}; Pulumi writes it from its outputs"
    bool(_f?.network?.mgmt?.id), "landingzone: spec.foundation.network.mgmt.id is required (the mgmt network is a shared spoke of the hub)"

# Spec of an XR without spec.crossplane (Crossplane writes fields there the
# generated schema does not declare, and no rule reads it).
spec_of = lambda oxr: any -> {str:} {
  normalize({_k: _v for _k, _v in oxr.spec if _k != "crossplane"})
}

# The XRD defaults these objects to {} and the API server then fills their
# fields' defaults; kcl import carries neither into the generated models.
# Filling the empty objects here gives every caller (a rendered XR, a local
# example, Pulumi) the same fully defaulted spec.
normalize = lambda s: {str:} -> {str:} {
  s | {
    guardrails = s?.guardrails or {}
    registry = s?.registry or {}
    audit = s?.audit or {}
    network = (s?.network or {}) | {hub = s?.network?.hub or {}}
    controlPlane = (s?.controlPlane or {}) | {crossplane = s?.controlPlane?.crossplane or {}}
  }
}

# The XR's spec, checked: as `Composed` once tier 0 has written the foundation,
# as `LandingZone` before that. Callers render children only when
# foundation is set; a broken spec fails either way.
checked = lambda oxr: any -> LandingZone {
  _s = spec_of(oxr)
  Composed {**_s} if _s?.foundation else LandingZone {**_s}
}

validate = lambda s: {str:} -> LandingZone {
  LandingZone {**normalize(s)}
}
