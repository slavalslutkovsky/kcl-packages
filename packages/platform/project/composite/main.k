import .project

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {
  apiVersion = "platform.example.org/v1alpha1"
  kind = "Project"
  metadata = {name = "shop", namespace = "acme-shop"}
  spec = {
    client = "acme"
    cloud = {provider = "aws", region = "eu-west-1"}
    databases = [{name = "orders-db"}]
    apps = [
      {name = "web", kind = "ui", image = "ghcr.io/acme/web:1.0.0"}
      {name = "api", kind = "api", image = "ghcr.io/acme/api:1.0.0", uses = ["orders-db"]}
      {name = "migrate", kind = "cli", image = "ghcr.io/acme/api:1.0.0", command = ["/app/migrate"], uses = ["orders-db"]}
    ]
  }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# The project's children and apps + the desired composite carrying observed
# status back to the XR. render() takes ocds because apps are wired from, and
# gated on, the children's observed status.
items = project.render(_oxr, _ocds) + [project.status(_oxr, _ocds)]
