# Unit tests for the paid-feature gate.
# Contract under test:
#   request(oxr)                  -> one meta.krm.kcl.dev RequiredResources item
#   resolve(params, oxr, feature) -> Gate {ready, pending, plan, features, quota}
#   at_least(gate, floor)         -> bool
#   within_quota(gate, key, used, default) -> cap
#
# The three states of `resolve` are what matter: PENDING must never assert (it
# is the normal first iteration), and DENIED must always assert (fail closed).
# A KCL test cannot catch an assert, so the denial cases are covered by
# `packages/platform/entitlement/examples` + the render checks in the module
# READMEs; here we pin the shapes that must NOT fail.
import .lib as ent

_xr = lambda _ns: str {
    {apiVersion = "cloud.example.org/v1alpha1", kind = "Forge", metadata = {name = "git", namespace = _ns}, spec = {}}
}

_record = lambda _plan: str, _features: [str], _quota: {str:int} {
    {
        apiVersion = "platform.example.org/v1alpha1"
        kind = "Entitlement"
        metadata.name = "tenant-a"
        spec = {plan = _plan, features = _features, quota = _quota}
    }
}

# What Crossplane hands back once it has fetched the record.
_answered = lambda _rec {
    {
        requiredResources = {entitlement = [{Resource = _rec}]}
    }
}

# ---- request ----------------------------------------------------------------
test_request_selects_the_namespace = lambda {
    r = ent.request(_xr("tenant-a"))
    assert r.apiVersion == "meta.krm.kcl.dev/v1alpha1", "the request must be a meta item, not a composed resource"
    assert r.kind == "RequiredResources", "wrong meta kind: ${r.kind}"
    sel = r.requirements[ent.requirement_key]
    assert sel.apiVersion == ent.record_api_version, "selector must name the Entitlement API"
    assert sel.kind == "Entitlement", "selector must name the Entitlement kind"
    assert sel.name == "tenant-a", "the tenant key is the XR namespace, not its name"
    assert sel?.namespace == Undefined, "the record is cluster-scoped: a namespace key would make the fetch fail"
    assert sel?.matchLabels == Undefined, "name and matchLabels are mutually exclusive in Crossplane's selector"
}

# ---- resolve: pending -------------------------------------------------------
test_pending_on_the_first_iteration = lambda {
    # No requiredResources key at all: Crossplane has not been asked yet.
    g = ent.resolve({}, _xr("tenant-a"), "forgejo")
    assert g.pending, "an absent requiredResources key must be pending, never denied"
    assert not g.ready, "pending must not compose"
    assert g.feature == "forgejo", "the gate carries the feature it was asked for"
    assert g.plan == "", "nothing is known about the plan yet"
}

test_pending_survives_an_unrelated_key = lambda {
    g = ent.resolve({
        requiredResources = {somethingElse = [{
            Resource = {}
        }]}
    }, _xr("tenant-a"), "forgejo")
    assert g.pending, "another function's requirement must not be read as this gate's answer"
}

# ---- resolve: ready ---------------------------------------------------------
test_ready_copies_the_record = lambda {
    g = ent.resolve(_answered(_record("team", ["forgejo", "repository"], {repositories = 50})), _xr("tenant-a"), "forgejo")
    assert g.ready, "a record granting the feature must compose"
    assert not g.pending, "an answered gate is not pending"
    assert g.plan == "team", "plan must be copied for at_least()"
    assert g.features == ["forgejo", "repository"], "features must be copied verbatim"
    assert g.quota == {repositories = 50}, "quota must be copied for within_quota()"
}

test_ready_tolerates_a_bare_record = lambda {
    # A record with no quota and no plan is still a valid grant.
    g = ent.resolve(_answered({apiVersion = ent.record_api_version, kind = "Entitlement", spec = {features = ["forgejo"]}}), _xr("tenant-a"), "forgejo")
    assert g.ready, "features alone is a complete grant"
    assert g.plan == "", "an absent plan is empty, not an error"
    assert g.quota == {}, "an absent quota is empty, not an error"
}

# ---- at_least ---------------------------------------------------------------
test_plan_ordering = lambda {
    free = ent.resolve(_answered(_record("free", ["forgejo"], {})), _xr("tenant-a"), "forgejo")
    team = ent.resolve(_answered(_record("team", ["forgejo"], {})), _xr("tenant-a"), "forgejo")
    ent_ = ent.resolve(_answered(_record("enterprise", ["forgejo"], {})), _xr("tenant-a"), "forgejo")
    assert ent.at_least(free, "free"), "a plan is at least itself"
    assert not ent.at_least(free, "team"), "free is below team"
    assert ent.at_least(team, "team"), "team is at least team"
    assert not ent.at_least(team, "enterprise"), "team is below enterprise"
    assert ent.at_least(ent_, "team"), "enterprise clears the team floor"
}

test_unknown_plan_clears_nothing = lambda {
    # A typo in a record must never unlock more than it names.
    typo = ent.resolve(_answered(_record("", ["forgejo"], {})), _xr("tenant-a"), "forgejo")
    assert not ent.at_least(typo, "free"), "an unranked plan sits below every floor"
}

# ---- within_quota -----------------------------------------------------------
test_quota_from_the_record_wins = lambda {
    g = ent.resolve(_answered(_record("team", ["repository"], {repositories = 3})), _xr("tenant-a"), "repository")
    assert ent.within_quota(g, "repositories", 3, 1) == 3, "the record's cap must override the default"
}

test_quota_falls_back_to_the_default = lambda {
    g = ent.resolve(_answered(_record("team", ["repository"], {})), _xr("tenant-a"), "repository")
    assert ent.within_quota(g, "repositories", 1, 5) == 5, "an unset key must fall back to the caller's default"
}
