import .cluster

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "cloud.example.org/v1alpha1", kind = "KubernetesCluster", metadata.name = "example", spec = {region = "dc1", kubeconfigSecret = "example-kubeconfig", bootstrap.sync = {url = "https://github.com/example/fleet", path = "./clusters/example"}}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Managed resources + the desired composite carrying observed status back to
# the XR. render() reads ocds too: the sync entrypoint only appears once Flux
# is observed deployed.
items = cluster.render(_oxr, _ocds) + [cluster.status(_oxr, _ocds)]
