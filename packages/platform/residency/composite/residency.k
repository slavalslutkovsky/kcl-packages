# residency — Crossplane Composition logic (function-kcl module).
#
# A composite of composites: for every (location, key) pair it emits one CHILD
# COMPOSITE RESOURCE, a cloud.example.org EncryptionKey placed in the region
# the location resolves to on the chosen backend (./regions.k). Nothing here
# knows what a KeyRing, a Key Vault or a transit mount is; the kms capability
# owns that mapping and this module only decides WHICH keys exist WHERE.
#
# Children are TYPED against kms-xrd (generated from the EncryptionKey XRD by
# `just xrd-schema kms`), so a field EncryptionKey does not declare, or a value
# outside its range, is a render error here rather than a rejected apply.
import kms_xrd.models.unknown as kms
import .regions

# Explicit "was this field set?" test; see inbox.k — false and 0 are values.
_set = lambda value -> bool {
    not (value == Undefined or value == None)
}

# Azure Key Vault names are 3-24 characters, and the kms azure backend names
# the vault after the child XR. Checked here, where the name is assembled, so
# the error names the Residency fields that produced it.
_azure_name_max = 24

# A child XR's observed status (no atProvider layer: it is the XRD's status).
_observed = lambda ocds, name: str -> any {
    (ocds[name]?.Resource?.status) if (name in ocds) else Undefined
}

# The composition-resource-name of one pair: unique per Residency, stable
# across reconciles, and what status() looks the child up by.
resource_name = lambda location: str, key: str -> str {
    "${location}-${key}"
}

# pairs(spec) — every (location entry, key entry) the spec asks for, in spec
# order (keys outer, locations inner). A key's `locations` narrows it; unset
# means every location.
pairs = lambda spec: {str:any} -> [[any]] {
    _all = [l.name for l in spec.locations]
    _by_name = {l.name: l for l in spec.locations}
    [[_by_name[n], k] for k in spec.keys for n in (k?.locations or _all)]
}

# Signatures stay on one line (untyped where needed): `kcl fmt` 0.13 wraps a
# long parameter list into a `lambda {` block that the KCL inside function-kcl
# v0.12.2 cannot parse.
_key = lambda name, spec, loc, k -> kms.EncryptionKey {
    _provider = spec.provider
    _child = "${name}-${resource_name(loc.name, k.name)}"
    kms.EncryptionKey {
        metadata = {
            name = _child
            annotations = {"krm.kcl.dev/composition-resource-name" = resource_name(loc.name, k.name)}
        }
        spec = {
            region = regions.resolve(loc, _provider)
            crossplane.compositionSelector.matchLabels.provider = _provider
            purpose = k?.purpose or "encrypt-decrypt"
            algorithm = k?.algorithm or "symmetric"
            protectionLevel = k?.protectionLevel or "software"
            # Residency defaults differ from EncryptionKey's (no rotation,
            # Delete): always sent, so the child never falls back to ITS default.
            rotationDays = k.rotationDays if _set(k?.rotationDays) else 90
            deletionWindowDays = k.deletionWindowDays if _set(k?.deletionWindowDays) else 30
            deletionPolicy = spec?.deletionPolicy or "Orphan"
            tags = (spec?.tags or {}) | {"residency-location" = loc.name}
            if _provider == "azure":
                resourceGroup = spec.resourceGroup
                tenantId = spec.tenantId
            if _provider == "oci":
                compartmentId = spec.compartmentId
        }
    }
}

# render(oxr) — one EncryptionKey per (location, key) pair. No ocds: the keys
# are independent and complete on the first reconcile.
render = lambda oxr -> [any] {
    _spec = oxr.spec
    _name = oxr.metadata.name
    _provider = _spec.provider
    _loc_names = [l.name for l in _spec.locations]
    _key_names = [k.name for k in _spec.keys]

    # The XRD's list-map keys enforce these on the cluster; render() also runs
    # against hand-written specs (tests, main.k), so they are rechecked here.
    assert len(_loc_names) == len({n: 1 for n in _loc_names}), "residency: spec.locations names must be unique"
    assert len(_key_names) == len({n: 1 for n in _key_names}), "residency: spec.keys names must be unique"
    _narrowed = [n for k in _spec.keys for n in (k?.locations or [])]
    assert all n in _narrowed {n in _loc_names}, "residency: keys[].locations may only name entries of spec.locations"
    assert _provider != "azure" or (_spec?.resourceGroup and _spec?.tenantId), "residency: provider azure requires spec.resourceGroup and spec.tenantId"
    assert _provider != "oci" or _spec?.compartmentId, "residency: provider oci requires spec.compartmentId"

    _items = [_key(_name, _spec, p[0], p[1]) for p in pairs(_spec)]
    assert _provider != "azure" or all i in _items {len(i.metadata.name) <= _azure_name_max}, "residency: on azure <residency>-<location>-<key> must be at most ${_azure_name_max} characters (Key Vault name limit); shorten the Residency, location or key names"
    # Composed resources inherit the XR's namespace; never set it here.
    _items
}

# One location's status. `obs` is keyed by resource_name(); `key_ids` are the
# keys placed in this location. The region is the one the keys REPORT once
# they exist (what the backend actually did), the catalog answer before that.
_location_status = lambda loc, provider, key_ids, obs -> {str:any} {
    _seen = [obs[resource_name(loc.name, k)] for k in key_ids if obs[resource_name(loc.name, k)]?.region]
    _country = regions.jurisdiction(loc.name)
    {
        region = _seen[0].region if _seen else regions.resolve(loc, provider)
        if _country:
            jurisdiction = _country
        ready = all k in key_ids {obs[resource_name(loc.name, k)]?.ready or False}
        keys = {k: obs[resource_name(loc.name, k)].keyUri for k in key_ids if obs[resource_name(loc.name, k)]?.keyUri}
    }
}

# Build the desired composite carrying the keys' observed status back to the
# Residency. Coordinates are copied from each EncryptionKey, never recomputed:
# the kms backend decided what a key URI looks like.
status = lambda oxr, ocds -> any {
    _spec = oxr.spec
    _pairs = pairs(_spec)
    _obs = {resource_name(p[0].name, p[1].name): _observed(ocds, resource_name(p[0].name, p[1].name)) for p in _pairs}
    _ready = {n: (o?.ready or False) for n, o in _obs}
    _ready_count = len([n for n, r in _ready if r])

    _locations = {l.name: _location_status(l, _spec.provider, [p[1].name for p in _pairs if p[0].name == l.name], _obs) for l in _spec.locations}

    {
        apiVersion = oxr?.apiVersion or "platform.example.org/v1alpha1"
        kind = oxr?.kind or "Residency"
        metadata.name = oxr.metadata.name
        status = {
            provider = _spec.provider
            ready = len(_pairs) > 0 and _ready_count == len(_pairs)
            keysReady = "${_ready_count}/${len(_pairs)}"
            locations = _locations
        }
    }
}
