"""
entitlement — the paid-feature gate every commercial capability shares.

A capability that is not free asks Crossplane, at render time, for the
cluster-scoped `Entitlement` named after the XR's namespace, and refuses to
compose anything unless that record grants the feature. The record is written by
whatever owns billing; nothing in this repo creates one.

USAGE from a Composition module (see packages/cloud/forge/forgejo/main.k):

    import entitlement as ent

    _params = option("params") or {oxr = _example, ocds = {}}
    _oxr = _params.oxr
    _gate = ent.resolve(_params, _oxr, "forgejo")

    # Iteration 0 has no answer yet: emit ONLY the request, so Crossplane
    # fetches the record and calls the function again.
    items = [ent.request(_oxr)] + (forge.render(_oxr, _gate) + [forge.status(_oxr, _ocds)] if _gate.ready else [])

WHY IT LOOKS LIKE THIS

`request()` returns a `meta.krm.kcl.dev/v1alpha1 RequiredResources` item. That
is not a composed resource: function-kcl intercepts the kind and turns
`requirements` into `RunFunctionResponse.requirements.resources`, which makes
Crossplane fetch the object and re-invoke the step with it in
`RunFunctionRequest.required_resources` (up to 5 iterations, stopping early on a
fatal result). The fetched object arrives as
`option("params").requiredResources.<key>[0].Resource`.

The consequence is that the FIRST call sees no record at all. `resolve()`
therefore distinguishes three states, and only the third is an error:

    pending  — Crossplane has not answered yet (key absent). Emit the request,
               compose nothing, do not assert.
    denied   — the record is missing, or does not grant the feature. Fatal.
    ready    — entitled; compose.

Failing closed is the point: `assert` surfaces as a SEVERITY_FATAL function
result, so an unentitled tenant gets a named error on its XR and zero resources,
not a half-provisioned instance.

REQUIREMENTS

`request()` needs function-kcl >= v0.12 (this repo pins v0.12.2 in every
module's `xrd/functions.yaml`) or this repo's `kclx`. v0.11.x rejects the item
outright — `invalid kind "RequiredResources" for apiVersion
"meta.krm.kcl.dev/v1alpha1" - must be CompositeConnectionDetails or
ExtraResources` — so a cluster running an older pin fails every gated
Composition rather than degrading. The Composition must also set
`spec.pipeline[].input.spec.target: Default`: the meta-kind dispatch runs only
under that target, and the input CRD's own default is `Resources`.

Crossplane core, not the function, performs the fetch, so its ClusterRole needs
to cover the record — see `rbac.yaml` next to this file.

The tenant key is the XR's NAMESPACE, not its name: a tenant is a namespace here
(Crossplane v2 XRs are namespaced), and one namespace may hold many XRs of many
kinds covered by one purchase.
"""

# The API of the record. Cluster-scoped, and a plain CRD rather than an XRD:
# it is an input to composition, never a thing Crossplane composes.
record_api_version = "platform.example.org/v1alpha1"
record_kind = "Entitlement"

# The key the requirement is filed under. Arbitrary but must match on both
# sides, so it lives here rather than in each caller.
requirement_key = "entitlement"

# Plans are informational — `spec.features` is the authority, so adding a
# feature to a plan can never silently entitle a tenant that did not buy it.
# The rank is the upgrade path, which is what `at_least` compares against; an
# unranked (typo'd) plan scores below every floor, so a bad record can never
# unlock more than it names.
plan_rank = {free = 0, team = 1, enterprise = 2}

schema Gate:
    """
    The outcome of one gate evaluation.

    ready
        Compose. The tenant holds a record granting the feature.
    pending
        Crossplane has not fetched the record yet (first iteration). Emit the
        request and nothing else; this is not a failure.
    feature
        Which feature was asked for, so a caller can put it in its own status.
    plan / features / quota
        Copied off the record once it is known, for callers that size what they
        compose by plan (`quota.repositories`, `plan == "enterprise"`, ...).
    """
    ready: bool
    pending: bool
    feature: str
    plan: str = ""
    features: [str] = []
    quota: {str:int} = {}

# The item that makes Crossplane fetch this tenant's record. Emit it on EVERY
# call, not just the first: Crossplane compares the whole requirements message
# between iterations and re-fetches until it stops changing, so dropping the
# request once the answer arrives would flip requirements back and forth.
request = lambda oxr -> any {
    _ns = oxr.metadata?.namespace
    assert _ns, "entitlement: the XR has no metadata.namespace, so there is no tenant to look up (the XRD must be Namespaced)"
    {
        apiVersion = "meta.krm.kcl.dev/v1alpha1"
        kind = "RequiredResources"
        requirements = {
            # No `namespace` key: the record is cluster-scoped.
            "${requirement_key}" = {apiVersion = record_api_version, kind = record_kind, name = _ns}
        }
    }
}

# Evaluate the gate. Fatal (via assert) when the answer is in and says no.
#
# The asserts are guarded on `_pending` rather than living in an else-branch:
# a KCL lambda body must end in an expression, so the three states are folded
# into one straight-line evaluation with `Gate` as the final expression.
resolve = lambda params, oxr, feature: str -> Gate {
    _ns = oxr.metadata?.namespace or ""
    _rr = params?.requiredResources or {}

    # Absent key = Crossplane has not been asked yet. An empty LIST is a real
    # answer: the lookup ran and found nothing.
    _hits = _rr[requirement_key] if requirement_key in _rr else Undefined
    _pending = _hits == Undefined or _hits == None
    _found = (not _pending) and len(_hits) == 1

    _spec = (_hits[0]?.Resource?.spec or {}) if _found else {}
    _features = _spec?.features or []
    _plan = _spec?.plan or "none"

    assert _pending or _found, "namespace '${_ns}' has no ${record_kind} '${_ns}': '${feature}' is a paid feature. Create the ${record_kind} record for this tenant, or delete this ${oxr.kind}."
    assert _pending or feature in _features, "namespace '${_ns}' is on plan '${_plan}', which does not include '${feature}' (granted: ${_features}). Add '${feature}' to ${record_kind}/${_ns} spec.features."

    Gate {
        ready = not _pending
        pending = _pending
        feature = feature
        plan = _spec?.plan or ""
        features = _features
        quota = _spec?.quota or {}
    }
}

# Is the tenant's plan at least `floor`? For capabilities whose SHAPE differs by
# plan (replica counts, HA) rather than being on/off.
at_least = lambda gate: Gate, floor: str -> bool {
    assert floor in plan_rank, "entitlement.at_least: unknown plan '${floor}' (known: ${plan_rank})"
    (plan_rank[gate.plan] if gate.plan in plan_rank else -1) >= plan_rank[floor]
}

# Enforce a numeric quota from the record, with `default` when the plan sets
# none. `used` is what the XR is asking for, so the message can say both numbers.
within_quota = lambda gate: Gate, key: str, used: int, default: int -> int {
    _cap = gate.quota[key] if key in gate.quota else default
    assert used <= _cap, "namespace quota exceeded: ${used} ${key} requested, plan '${gate.plan}' allows ${_cap}. Raise ${record_kind} spec.quota.${key} or reduce the request."
    _cap
}

# ── Authoring the records ────────────────────────────────────────────────────
# The gate above READS records; this half WRITES them, so the tenant list can
# live in version control (or be generated by the billing system) and be applied
# with `just entitlements <values.yaml> | kubectl apply -f -`. Typed here rather
# than hand-written YAML so a feature key typo is a build failure.
schema Record:
    """
    One tenant's entitlement. `namespace` is the record's name, because that is
    the join key the gate looks it up by.
    """
    namespace: str
    plan: "free" | "team" | "enterprise" = "free"
    features: [str] = []
    quota: {str:int} = {}
    reference?: str

    check:
        namespace, "an Entitlement must name the tenant namespace it grants"
        all f in features {f in known_features}, "unknown feature in ${namespace}: granted ${features}, known ${known_features}. A capability only reads the key it asks for, so a typo silently grants nothing."
        all _k, _v in quota {_v >= 0}, "quota values must not be negative: ${quota}"

# Every key a Composition in this repo asks for. Extending a capability means
# extending this list, which is what makes a typo in a record a build failure
# rather than a tenant who paid and got a fatal render.
known_features = ["forgejo", "repository"]

render = lambda records: [Record] -> [any] {
    [{
        apiVersion = record_api_version
        kind = record_kind
        metadata.name = r.namespace
        spec = {
            plan = r.plan
            features = r.features
            if r.quota:
                quota = r.quota
            if r.reference:
                reference = r.reference
        }
    } for r in records]
}
