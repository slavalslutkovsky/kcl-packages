# repository (forgejo) — Crossplane Composition logic (function-kcl module).
#
# Objects INSIDE a forge that already runs, driven straight over Forgejo's REST
# API by provider-http. There is no typed Forgejo provider worth installing:
# `arch-err/provider-forgejo` ships 22 CRDs whose `controller.Setup` returns nil
# (it reconciles nothing), `rossigee/provider-gitea` is single-maintainer,
# amd64-only and vendors a forked crossplane-runtime, and `provider-jet-gitea`
# is dead. provider-http is crossplane-contrib, multi-arch, v2-native, and
# genuinely CRUD — so the cost of typelessness is paid here, once, in mappings.
#
# A provider-http `Request` is one API object. Its four `mappings` are the
# lifecycle: CREATE (POST), OBSERVE (GET; 404 means "does not exist yet"),
# UPDATE (PATCH) and REMOVE (DELETE). `url` and `body` are jq programs over
# `.payload`, so everything a mapping needs must live inside `payload` — that is
# why `payload.body` carries the whole desired object as JSON even though only
# the CREATE mapping sends it verbatim.
import json
import http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_request as backend
import http.models.v1alpha2.h_t_t_pm_crossplane_io_v1alpha2_provider_config as pc
import entitlement.lib as ent

# Crossplane management policy set for the Orphan deletion policy (everything
# but Delete) — identical to every other backend in this repo.
_orphan_policies = ["Observe", "Create", "Update", "LateInitialize"]

# The Secret key provider-http reads the Authorization header value from. The
# value must include the scheme (`token <PAT>`): the provider copies the bytes
# verbatim into the header and Forgejo 401s a bare token.
auth_key = "authorization"

# Forgejo's webhook type discriminator. `forgejo` and `gitea` are both accepted
# by a Forgejo server; the native one is used so the payload shape is stable.
webhook_type = "forgejo"

# provider-http's DEFAULT sync check is "the UPDATE body is JSON-contained in
# the OBSERVE response". Any key that Forgejo accepts on create but does not
# echo back — or echoes under a different name — would therefore make the
# resource permanently out of sync, so the UPDATE bodies below carry only
# fields the GET response actually contains.
_mutable_repo_keys = ["description", "private", "default_branch"]

# One Request, with the scaffolding every object here shares: the per-XR
# ProviderConfig, the JSON content type, and the orphan policy when asked for.
_request = lambda name: str, oxr, payload: {str:}, mappings: [any] -> any {
    _mp = _orphan_policies if (oxr.spec?.deletionPolicy or "Delete") == "Orphan" else Undefined
    backend.Request {
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = name}
        if _mp:
            spec.managementPolicies = _mp
        spec.providerConfigRef = {kind = "ProviderConfig", name = oxr.metadata.name}
        spec.forProvider = {
            headers = {"Content-Type" = ["application/json"]}
            payload = {
                baseUrl = oxr.spec.forge.baseUrl
                # A JSON string, not a nested object: `payload.body` is typed
                # `str` by the CRD, and the mappings parse it with jq.
                body = json.encode(payload)
            }
            mappings = mappings
        }
    }
}

# jq expression selecting `keys` out of the payload body, e.g.
# `{description: .payload.body.description, private: .payload.body.private}`.
_pick = lambda keys: [str] -> str {
    "{" + ", ".join(["${k}: .payload.body.${k}" for k in keys]) + "}"
}

render = lambda oxr, gate {
    _spec = oxr.spec
    _name = _spec?.name or oxr.metadata.name
    _owner = _spec.owner
    _private = _spec?.private
    if _private == Undefined:
        _private = True

    # Paid-plan shape. Both are hard failures rather than silent downgrades: a
    # tenant who asked for a private repository and got a public one would find
    # out from the internet.
    assert (not _private) or ent.at_least(gate, "team"), "spec.private requires plan 'team' or better; namespace is on '${gate.plan}'. Set private: false, or raise the plan on Entitlement/${oxr.metadata?.namespace}."

    # One XR is one repository, so `used` is 1: this enforces "a free record
    # with no quota may hold exactly one repository", counted by Crossplane
    # rejecting the second XR's render rather than by counting here — the
    # function sees one XR at a time and must never guess at the others.
    ent.within_quota(gate, "repositories", 1, 1)

    _repo_url = ".payload.baseUrl + \"/repos/\" + .payload.body.owner + \"/\" + .payload.body.name"

    # The credential lives in a Secret the tenant created; the ProviderConfig is
    # composed so that Secret is the only thing they have to make by hand.
    _items: [any] = [pc.ProviderConfig {
        # An EXPLICIT name, unlike every other resource here. Crossplane names a
        # composed resource `<xr>-<hash>` unless it carries one, and the hash is
        # not knowable at render time — so a Request's providerConfigRef could
        # never point at it. Naming it after the XR also keeps one tenant's
        # forge credential unreachable from another's Request.
        metadata.name = oxr.metadata.name
        metadata.annotations = {"krm.kcl.dev/composition-resource-name" = "providerconfig"}
        spec.credentials = {
            source = "Secret"
            secretRef = {name = _spec.forge.secretRef, namespace = oxr.metadata?.namespace or "default", key = auth_key}
        }
    }]

    # The organization comes first: a repository's CREATE url names its owner,
    # so the org has to exist before the repository call can succeed. Crossplane
    # applies composed resources in one pass, so ordering here only expresses
    # intent — provider-http retries the repository until the org answers.
    if _spec?.createOrganization:
        _org = _spec?.organization or {}
        _items += [_request("organization", oxr, {
            username = _owner
            full_name = _org?.fullName or _owner
            visibility = _org?.visibility or "private"
            if _org?.description:
                description = _org.description
            if _org?.website:
                website = _org.website
        }, [
            {action = "CREATE", url = ".payload.baseUrl + \"/orgs\"", body = _pick(["username", "full_name", "visibility"])}
            {action = "OBSERVE", url = ".payload.baseUrl + \"/orgs/\" + .payload.body.username"}
            {action = "UPDATE", method = "PATCH", url = ".payload.baseUrl + \"/orgs/\" + .payload.body.username", body = _pick(["full_name", "visibility"])}
            {action = "REMOVE", url = ".payload.baseUrl + \"/orgs/\" + .payload.body.username"}
        ])]

    # The repository itself. `owner` is in the payload only so the mappings can
    # build their URLs from it — Forgejo takes the owner from the path, never
    # the body.
    _items += [_request("repository", oxr, {
        owner = _owner
        name = _name
        description = _spec?.description or ""
        private = _private
        default_branch = _spec?.defaultBranch or "main"
        auto_init = _spec?.autoInit if _spec?.autoInit != Undefined else True
        template = _spec?.template or False
        if _spec?.gitignores:
            gitignores = _spec.gitignores
        if _spec?.license:
            license = _spec.license
        if _spec?.readme:
            readme = _spec.readme
    }, [
        {
            action = "CREATE"
            url = ".payload.baseUrl + \"/orgs/\" + .payload.body.owner + \"/repos\""
            # auto_init/template/gitignores/license/readme are create-only and
            # deliberately absent from the UPDATE body below.
            body = _pick(["name", "description", "private", "default_branch", "auto_init", "template"] + (["gitignores"] if _spec?.gitignores else []) + (["license"] if _spec?.license else []) + (["readme"] if _spec?.readme else []))
        }
        {action = "OBSERVE", url = _repo_url}
        {action = "UPDATE", method = "PATCH", url = _repo_url, body = _pick(_mutable_repo_keys)}
        {action = "REMOVE", url = _repo_url}
    ])]

    # A push webhook, only when a url is given. Forgejo assigns hooks a numeric
    # id at creation and offers no lookup by url, so an addressable OBSERVE is
    # impossible: this is the one object here that cannot be a CRUD `Request`
    # without lying about drift. It stays a `Request` whose OBSERVE lists the
    # repository's hooks — the DEFAULT sync check then holds as long as the
    # hook's config is JSON-contained in that list, which it is for a single
    # hook. A second webhook on the same repository would break that, which is
    # why the XRD models exactly one.
    if _spec?.webhook?.url:
        _wh = _spec.webhook
        _items += [_request("webhook", oxr, {
            owner = _owner
            name = _name
            type = webhook_type
            active = _wh?.active if _wh?.active != Undefined else True
            events = _wh?.events or ["push"]
            config = {
                url = _wh.url
                content_type = "json"
            }
        }, [
            {action = "CREATE", url = "${_repo_url} + \"/hooks\"", body = "{type: .payload.body.type, active: .payload.body.active, events: .payload.body.events, config: .payload.body.config}"}
            {action = "OBSERVE", url = "${_repo_url} + \"/hooks\""}
            {action = "UPDATE", method = "PATCH", url = "${_repo_url} + \"/hooks\"", body = "{active: .payload.body.active, events: .payload.body.events, config: .payload.body.config}"}
            {action = "REMOVE", url = "${_repo_url} + \"/hooks\""}
        ])]

    _items
}

# Build the desired composite carrying the forge's answer back to the XR.
#
# provider-http records the last response as a JSON STRING on
# `status.response.body`, so the clone URLs are decoded out of it rather than
# read as fields. A body that is absent, empty or not an object yields empty
# strings: a repository that exists is more useful with blank URLs than an XR
# that fails to render.
status = lambda oxr, ocds, gate {
    _spec = oxr.spec
    _name = _spec?.name or oxr.metadata.name
    _obs = ocds["repository"]?.Resource if ("repository" in (ocds or {})) else Undefined
    _body = _obs?.status?.response?.body or ""
    _repo = json.decode(_body) if _body else {}

    {
        apiVersion = oxr?.apiVersion or "cloud.example.org/v1alpha1"
        kind = oxr?.kind or "Repository"
        metadata.name = oxr.metadata.name
        status = {
            ready = len([c for c in (_obs?.status?.conditions or []) if c?.type == "Ready" and c?.status == "True"]) > 0
            # Computed locally: the platform knows the full name before the
            # forge has answered, and a support ticket needs it either way.
            fullName = "${_spec.owner}/${_name}"
            cloneUrl = _repo?.clone_url or ""
            sshUrl = _repo?.ssh_url or ""
            htmlUrl = _repo?.html_url or ""
            plan = gate.plan
        }
    }
}
