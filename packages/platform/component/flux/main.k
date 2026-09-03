import .component

# function-kcl injects option("params"); fall back to an example for local runs.
_example = {apiVersion = "platform.example.org/v1alpha1", kind = "Component", metadata.name = "app1", spec = {source = {kind = "OCIRepository", url = "oci://172.18.0.100:80/components/app1", ref.tag = "v1", insecure = True, interval = "1m"}, deliver = {kind = "Kustomization", targetNamespace = "default"}}}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# The two Flux objects + the desired composite carrying observed status back to
# the XR. render() needs no ocds: what it emits is derived entirely from the
# spec, and the observed Flux state only ever feeds status().
items = component.render(_oxr) + [component.status(_oxr, _ocds)]
