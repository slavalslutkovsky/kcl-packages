import .workflow

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "Workflow"
    metadata.name = "example"
    spec = {
        region = "westeurope"
        resourceGroup = "example-rg"
        definition = '{"triggers":{"manual":{"type":"Request","kind":"Http"}},"actions":{"Respond":{"type":"Response","kind":"Http","inputs":{"statusCode":200},"runAfter":{}}}}'
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = workflow.render(_oxr) + [workflow.status(_oxr, _ocds)]
