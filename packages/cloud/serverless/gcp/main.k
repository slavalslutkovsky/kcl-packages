import .serverless

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
    apiVersion = "cloud.example.org/v1alpha1"
    kind = "ServerlessApp"
    metadata.name = "example"
    spec = {
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        region = "us-central1"
        port = 8080
        cpu = 1
        memoryMb = 512
        minInstances = 0
        maxInstances = 3
        timeoutSeconds = 60
        env = {LOG_LEVEL = "info"}
        tags = {team = "platform"}
    }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to the XR.
items = serverless.render(_oxr) + [serverless.status(_oxr, _ocds)]
