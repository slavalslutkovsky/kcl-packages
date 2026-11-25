import .landingzone as lz
import landingzone_contract.example

# function-kcl injects option("params"); fall back to the gcp example with its
# tier-0 foundation for local runs.
_example = {
  apiVersion = "cloud.example.org/v1alpha1"
  kind = "LandingZone"
  metadata = {name = "shl", namespace = "landing-zone"}
  spec = example.gcp | {
    foundation = example.foundation.gcp
    crossplane = {compositionSelector.matchLabels.provider = "gcp"}
  }
}
_params = option("params") or {oxr = _example, ocds = {}}
_oxr = _params.oxr
_ocds = _params?.ocds or {}

# Child XRs + the desired composite carrying observed status back to the XR.
items = lz.render(_oxr, _ocds) + [lz.status(_oxr, _ocds)]
