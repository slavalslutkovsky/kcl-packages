import .repository
import entitlement.lib as ent

# function-kcl injects option("params"); the fallback carries an ENTITLED record
# so `kcl run main.k` (and `nx build`) renders the real resources instead of the
# pending no-op the first cluster reconcile produces.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "Repository"
    metadata = {name = "platform", namespace = "tenant-a"}
    spec = {
        forge = {baseUrl = "http://git.tenant-a.svc:3000/api/v1", secretRef = "forge-token"}
        owner = "acme"
        description = "managed by crossplane"
        private = True
    }
}
_fallback = {
    oxr = _example
    ocds = {}
    requiredResources = {entitlement = [{
        Resource = {
            apiVersion = "platform.example.org/v1alpha1"
            kind = "Entitlement"
            metadata.name = "tenant-a"
            spec = {plan = "team", features = ["repository"], quota = {repositories = 50}}
        }
    }]}
}
_params = option("params") or _fallback
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# The paid-feature gate. Iteration 0 carries no answer: emit only the request,
# so Crossplane fetches the record and calls the step again. Composing on a
# pending gate would create a repository for a tenant that may not be entitled.
_gate = ent.resolve(_params, _oxr, "repository")

items = [ent.request(_oxr)] + (repository.render(_oxr, _gate) + [repository.status(_oxr, _ocds, _gate)] if _gate.ready else [])
