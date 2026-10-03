import .gitopsplatform

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "GitOpsPlatform", metadata = {name = "example", namespace = "default"}, spec = {engine = "flux", db = {connection = {host = "pg.example.internal", passwordSecret.name = "example-pg"}, provision.backend = "cnpg"}}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Composed resources + the desired composite carrying observed status back to
# the XR. render() reads ocds: which of the check Job, the fallback database
# and the engine Release exist is decided from what has been observed.
items = gitopsplatform.render(_oxr, _ocds) + [gitopsplatform.status(_oxr, _ocds)]
