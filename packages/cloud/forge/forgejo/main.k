import .forge
import entitlement.lib as ent

# function-kcl injects option("params"); the fallback carries an ENTITLED record
# so `kcl run main.k` / `nx build` renders the real resources rather than the
# pending no-op.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "Forge", metadata = {name = "git", namespace = "tenant-a"}, spec = {hostname = "git.tenant-a.example.org"}}
_fallback = {oxr = _example, ocds = {}, requiredResources = {entitlement = [{
    Resource = {
        apiVersion = "platform.example.org/v1alpha1"
        kind = "Entitlement"
        metadata.name = "tenant-a"
        spec = {plan = "team", features = ["forgejo"], quota = {}}
    }
}]}}
_params = option("params") or _fallback
_oxr = _params.oxr
_ocds = _params?.ocds or {}
_gate = ent.resolve(_params, _oxr, "forgejo")

# Iteration 0 has no answer: emit only the request, so Crossplane fetches the
# record and calls the step again. Composing on a pending gate would provision
# for a tenant that may not be entitled.
items = [ent.request(_oxr)] + (forge.render(_oxr, _gate) + [forge.status(_oxr, _ocds, _gate)] if _gate.ready else [])
