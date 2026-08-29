import .redis

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "RedisInstance", metadata.name = "example", spec = {region = "us-east-1"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = redis.render(_oxr) + [redis.status(_oxr, _ocds)]
