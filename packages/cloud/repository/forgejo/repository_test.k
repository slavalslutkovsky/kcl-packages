# Unit tests for the repository (forgejo) function-kcl module.
# Contract under test:
#   render(oxr, gate)         -> [ProviderConfig, Request...]  (no composite)
#   status(oxr, ocds, gate)   -> dxr    (single desired-composite carrying .status)
#
# The traps this file exists to pin down:
#   * provider-http's DEFAULT sync check is "UPDATE body JSON-contained in the
#     OBSERVE response", so a create-only key in the UPDATE body would make the
#     resource permanently out of sync. test_update_body_has_no_create_only_keys.
#   * `payload.body` is a JSON string, not an object — the mappings are jq
#     programs over it. test_payload_is_json.
# Helper names avoid KCL's underscore normalisation shadowing a
# lambda parameter over in repository.k (`_spec`, `_wh`, `_name`, ...).
import json
import .repository

_xr = lambda _sp {
    {
        apiVersion = "cloud.example.org/v1alpha1"
        kind = "Repository"
        metadata = {name = "platform", namespace = "tenant-a"}
        spec = {forge = {baseUrl = "http://git.tenant-a.svc:3000/api/v1", secretRef = "forge-token"}, owner = "acme"} | _sp
    }
}

# A gate as `entitlement.resolve` would hand it over, without importing the
# library: these tests are about this module's reaction to a gate, not about the
# gate itself (that has its own suite in packages/platform/entitlement).
_plan_gate = lambda _plan: str {
    {ready = True, pending = False, feature = "repository", plan = _plan, features = ["repository"], quota = {repositories = 50}}
}

_pick_res = lambda _items, _wanted: str {
    _hits = [i for i in _items if i.metadata.annotations["krm.kcl.dev/composition-resource-name"] == _wanted]
    _hits[0] if _hits else Undefined
}

_names = lambda _items {
    [i.metadata.annotations["krm.kcl.dev/composition-resource-name"] for i in _items]
}

_mapping = lambda _req, _action: str {
    _hits = [m for m in _req.spec.forProvider.mappings if m.action == _action]
    _hits[0] if _hits else Undefined
}

# ---- render: the default resource set ---------------------------------------
test_defaults = lambda {
    items = repository.render(_xr({}), _plan_gate("team"))
    assert _names(items) == ["providerconfig", "repository"], "a plain XR must compose the ProviderConfig and one Request: ${_names(items)}"

    cfg = _pick_res(items, "providerconfig")
    assert cfg.spec.credentials.source == "Secret", "the credential must come from the tenant's Secret"

    # Field-by-field: a typed schema instance never compares equal to a plain
    # dict, however identical the rendered YAML looks.
    assert cfg.spec.credentials.secretRef.name == "forge-token", "the ProviderConfig must read the XR's Secret"
    assert cfg.spec.credentials.secretRef.namespace == "tenant-a", "the Secret is looked up in the XR's namespace"
    assert cfg.spec.credentials.secretRef.key == "authorization", "provider-http reads the header value from the authorization key"

    # The one resource here that must carry an explicit name: Crossplane would
    # otherwise generate `<xr>-<hash>`, and a Request's providerConfigRef
    # cannot know the hash.
    assert cfg.metadata.name == "platform", "the ProviderConfig must be named after the XR"

    repo = _pick_res(items, "repository")
    assert repo.spec.providerConfigRef.kind == "ProviderConfig", "the namespaced ProviderConfig, not the ClusterProviderConfig: provider-http switches on ref.kind"
    assert repo.spec.providerConfigRef.name == "platform", "a Request must name the ProviderConfig this Composition composed"
    assert repo.spec.forProvider.payload.baseUrl == "http://git.tenant-a.svc:3000/api/v1", "the API root must be forwarded verbatim"
    assert repo.spec.forProvider.headers == {"Content-Type" = ["application/json"]}, "Forgejo needs a JSON content type"
    assert len(repo.spec.forProvider.mappings) == 4, "a CRUD Request needs all four actions"
}

test_repository_mappings = lambda {
    repo = _pick_res(repository.render(_xr({}), _plan_gate("team")), "repository")
    create = _mapping(repo, "CREATE")
    observe = _mapping(repo, "OBSERVE")
    update = _mapping(repo, "UPDATE")
    remove = _mapping(repo, "REMOVE")

    # The owner is part of the create URL: Forgejo has no "infer the owner" call.
    assert create.url == ".payload.baseUrl + \"/orgs/\" + .payload.body.owner + \"/repos\"", "CREATE must POST to the org's repos collection: ${create.url}"
    assert create?.method == Undefined, "CREATE defaults to POST in provider-http; spelling it out would be noise"
    _one = ".payload.baseUrl + \"/repos/\" + .payload.body.owner + \"/\" + .payload.body.name"
    assert observe.url == _one, "OBSERVE must address the single repository: ${observe.url}"
    assert observe?.body == Undefined, "a GET must not carry a body"
    assert update.method == "PATCH", "Forgejo edits a repository with PATCH, and provider-http defaults UPDATE to PUT"
    assert update.url == _one, "UPDATE must address the single repository"
    assert remove.url == _one, "REMOVE must address the single repository"
    assert remove?.body == Undefined, "a DELETE must not carry a body"
}

test_update_body_has_no_create_only_keys = lambda {
    update = _mapping(_pick_res(repository.render(_xr({gitignores = "Go", license = "Apache-2.0", readme = "Default"}), _plan_gate("team")), "repository"), "UPDATE")

    # The sync check is "UPDATE body contained in the OBSERVE response". Forgejo
    # never echoes these, so including one would report drift forever.
    assert all k in ["auto_init", "template", "gitignores", "license", "readme", "name", "owner"] {k not in update.body}, "a create-only or immutable key leaked into the UPDATE body, which would report drift forever: ${update.body}"
    assert all k in ["description", "private", "default_branch"] {k in update.body}, "every mutable field must be in the UPDATE body: ${update.body}"
}

test_create_body_carries_the_init_options = lambda {
    create = _mapping(_pick_res(repository.render(_xr({gitignores = "Go", license = "Apache-2.0"}), _plan_gate("team")), "repository"), "CREATE")
    assert "gitignores" in create.body, "an asked-for .gitignore template must reach CREATE"
    assert "license" in create.body, "an asked-for license must reach CREATE"
    assert "readme" not in create.body, "an unset template must not be sent at all — Forgejo would reject an empty name"
}

test_payload_is_json = lambda {
    repo = _pick_res(repository.render(_xr({description = "d"}), _plan_gate("team")), "repository")
    body = json.decode(repo.spec.forProvider.payload.body)
    assert body.owner == "acme", "the mappings build their URLs from payload.body.owner"
    assert body.name == "platform", "the repository name defaults to the XR name"
    assert body.private == True, "private defaults to true"
    assert body.default_branch == "main", "the default branch defaults to main"
    assert body.auto_init == True, "autoInit defaults to true so the repo is cloneable"
}

test_name_override = lambda {
    body = json.decode(_pick_res(repository.render(_xr({name = "platform.git"}), _plan_gate("team")), "repository").spec.forProvider.payload.body)
    assert body.name == "platform.git", "spec.name must override the XR name"
}

# ---- render: the organization ----------------------------------------------
test_organization_is_composed_first = lambda {
    items = repository.render(_xr({createOrganization = True, organization = {fullName = "ACME", visibility = "limited", description = "d", website = "https://acme.test"}}), _plan_gate("team"))
    assert _names(items) == ["providerconfig", "organization", "repository"], "the org must precede the repository whose create URL names it: ${_names(items)}"

    org = _pick_res(items, "organization")
    body = json.decode(org.spec.forProvider.payload.body)
    assert body.username == "acme", "the org is named by spec.owner"
    assert body.full_name == "ACME", "fullName must be forwarded"
    assert body.visibility == "limited", "visibility must be forwarded"
    assert _mapping(org, "CREATE").url == ".payload.baseUrl + \"/orgs\"", "an org is created on the orgs collection"
    assert _mapping(org, "OBSERVE").url == ".payload.baseUrl + \"/orgs/\" + .payload.body.username", "an org is addressed by username"
    assert _mapping(org, "UPDATE").method == "PATCH", "Forgejo edits an org with PATCH"
}

test_organization_full_name_defaults_to_owner = lambda {
    org = _pick_res(repository.render(_xr({createOrganization = True}), _plan_gate("team")), "organization")
    body = json.decode(org.spec.forProvider.payload.body)
    assert body.full_name == "acme", "an unset fullName must fall back to the owner rather than send an empty string"
    assert body.visibility == "private", "visibility defaults to private"
}

test_no_organization_by_default = lambda {
    assert "organization" not in _names(repository.render(_xr({}), _plan_gate("team"))), "the org must not be managed unless asked for: deleting the XR would delete it"
}

# ---- render: the webhook ----------------------------------------------------
test_webhook_when_a_url_is_given = lambda {
    items = repository.render(_xr({
        webhook = {url = "https://ci.acme.test/hook", events = ["push", "pull_request"], active = False}
    }), _plan_gate("team"))
    assert _names(items) == ["providerconfig", "repository", "webhook"], "a webhook url must add exactly one resource: ${_names(items)}"
    wh = _pick_res(items, "webhook")
    body = json.decode(wh.spec.forProvider.payload.body)
    assert body.type == "forgejo", "the hook type discriminator must be the native one"
    assert body.events == ["push", "pull_request"], "events must be forwarded verbatim"
    assert body.active == False, "active: false must survive (it is not absence)"
    assert body.config.url == "https://ci.acme.test/hook", "the endpoint goes in config.url, not at the top level"
    assert body.config.content_type == "json", "Forgejo defaults to form encoding; JSON is what every consumer expects"
    create = _mapping(wh, "CREATE")
    assert create.url == ".payload.baseUrl + \"/repos/\" + .payload.body.owner + \"/\" + .payload.body.name + \"/hooks\"", "hooks hang off the repository: ${create.url}"
}

test_webhook_events_default_to_push = lambda {
    wh = _pick_res(repository.render(_xr({
        webhook = {url = "https://ci.acme.test/hook"}
    }), _plan_gate("team")), "webhook")
    body = json.decode(wh.spec.forProvider.payload.body)
    assert body.events == ["push"], "an unset event list must default to push, never to none"
    assert body.active == True, "a webhook defaults to delivering"
}

test_no_webhook_without_a_url = lambda {
    assert "webhook" not in _names(repository.render(_xr({
        webhook = {events = ["push"]}
    }), _plan_gate("team"))), "events without a url must not create a webhook"
}

# ---- render: deletion policy ------------------------------------------------
test_orphan_policy_on_every_request = lambda {
    items = repository.render(_xr({deletionPolicy = "Orphan", createOrganization = True, webhook = {url = "https://ci.acme.test/h"}}), _plan_gate("team"))
    reqs = [i for i in items if i.kind == "Request"]
    assert len(reqs) == 3, "the org, the repository and the webhook are all Requests: ${len(reqs)}"
    assert all r in reqs {r.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"]}, "Orphan must leave every forge-side object (and its git history) behind"
}

test_delete_policy_keeps_the_schema_default = lambda {
    repo = _pick_res(repository.render(_xr({}), _plan_gate("team")), "repository")
    assert repo.spec.managementPolicies == ["*"], "the default policy is the provider schema's own, not an explicit list"
}

# ---- render: the paid gate --------------------------------------------------
# A KCL test cannot catch an assert, so only the permitted combinations are
# asserted here; the refusals are exercised by the render checks in the module
# README and by the `tenant-free` example.
test_public_repository_on_a_free_plan = lambda {
    items = repository.render(_xr({private = False}), {ready = True, pending = False, feature = "repository", plan = "free", features = ["repository"], quota = {}})
    assert "repository" in _names(items), "a public repository must be allowed on the free plan"
}

test_private_repository_on_team_and_above = lambda {
    assert all p in ["team", "enterprise"] {"repository" in _names(repository.render(_xr({private = True}), _plan_gate(p)))}, "a private repository must be allowed on team and enterprise"
}

# ---- status -----------------------------------------------------------------
_observed = lambda _body: str, _ready: bool {
    {
        repository = {
            Resource = {
                apiVersion = "http.m.crossplane.io/v1alpha2"
                kind = "Request"
                status = {
                    response = {body = _body, statusCode = 200}
                    conditions = [{type = "Ready", status = "True" if _ready else "False"}]
                }
            }
        }
    }
}

test_status_unobserved = lambda {
    s = repository.status(_xr({}), {}, _plan_gate("team")).status
    assert not s.ready, "nothing observed means not ready"
    assert s.fullName == "acme/platform", "the full name is computed locally, so it is populated before the forge answers"
    assert s.cloneUrl == "" and s.sshUrl == "" and s.htmlUrl == "", "no answer means empty urls, not a failed render"
    assert s.plan == "team", "the authorizing plan is echoed even before the forge answers"
}

test_status_from_the_forge_response = lambda {
    body = '{"clone_url":"http://git.tenant-a.svc:3000/acme/platform.git","ssh_url":"git@git:acme/platform.git","html_url":"http://git.tenant-a.svc:3000/acme/platform","private":true}'
    s = repository.status(_xr({}), _observed(body, True), _plan_gate("enterprise")).status
    assert s.ready, "a Ready Request means the forge confirmed the repository"
    assert s.cloneUrl == "http://git.tenant-a.svc:3000/acme/platform.git", "cloneUrl must come out of the recorded response body"
    assert s.sshUrl == "git@git:acme/platform.git", "sshUrl must come out of the recorded response body"
    assert s.htmlUrl == "http://git.tenant-a.svc:3000/acme/platform", "htmlUrl must come out of the recorded response body"
    assert s.plan == "enterprise", "the plan must be copied off the gate"
}

test_status_survives_a_useless_body = lambda {
    # provider-http records whatever came back, including an error page.
    s = repository.status(_xr({}), _observed("", False), _plan_gate("team")).status
    assert not s.ready, "a non-Ready Request is not ready"
    assert s.cloneUrl == "", "an empty body must not crash the render"
    assert s.fullName == "acme/platform", "the locally computed name survives any response"
}
