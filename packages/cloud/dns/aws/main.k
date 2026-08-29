import .dns

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "DnsZone", metadata.name = "example", spec = {region = "us-east-1", domain = "example.com", records = [{name = "@", "type" = "A", values = ["203.0.113.10"]}]}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = dns.render(_oxr) + [dns.status(_oxr, _ocds)]
