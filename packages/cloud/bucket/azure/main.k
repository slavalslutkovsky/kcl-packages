import .bucket

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {metadata.name = "example", spec = {region = "us-central1"}}
_params = option("params") or {oxr = _example}
items = bucket.render(_params.oxr)
