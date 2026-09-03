import .inbox

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "Inbox", metadata.name = "example", spec = {provider = "aws", region = "us-east-1"}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Child composite resources + the desired composite carrying observed status
# back to the XR. render() ignores ocds (the two children are independent — no
# cross-child wiring); status() copies the children's published coordinates.
items = inbox.render(_oxr) + [inbox.status(_oxr, _ocds)]
