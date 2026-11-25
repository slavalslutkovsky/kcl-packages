import .backup

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "BackupPlan", metadata = {name = "example", namespace = "default"}, spec = {schedule = "0 2 * * *", cluster = {id = "arn:aws:eks:us-east-1:123456789012:cluster/example"}}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = backup.render(_oxr, _ocds) + [backup.status(_oxr, _ocds)]
