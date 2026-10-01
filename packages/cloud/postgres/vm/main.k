import .postgres

# function-kcl injects option("params"); the fallback carries the fetched
# password Secret so `kcl run main.k` renders the machine rather than the
# pending request-only pass.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "PostgresInstance", metadata = {name = "example", namespace = "default"}, spec = {region = "us-central1", passwordSecret.name = "example-pg", vm.provider = "gcp"}}
_fallback = {oxr = _example, ocds = {}, requiredResources = {"password-secret" = [{
    Resource = {apiVersion = "v1", kind = "Secret", metadata.name = "example-pg", data.password = "Y2hhbmdlLW1l"}
}]}}
_params = option("params") or _fallback
_oxr = _params.oxr
_ocds = _params?.ocds or {}
_hash = postgres.password_hash(_params, _oxr)

# Iteration 0 has no Secret yet: emit only the request, so Crossplane fetches
# it and calls the step again. Rendering without it would boot a server whose
# owner cannot log in.
items = [postgres.request(_oxr)] + (postgres.render(_oxr, _hash) + [postgres.status(_oxr, _ocds)] if _hash else [])
