"""
Entry point for the `platform-addons` package: the plan the ClientPlatform
controller (kcl-operator) renders for one client.

  kcl run packages/platform-addons -D params=packages/platform-addons/examples/params-flux.yaml
  kcl run packages/platform-addons -D params=packages/platform-addons/examples/params-argo.yaml
  # after publish: kcl run oci://docker.io/yurikrupnik/platform-addons -D params=...

`option("params")` is the operator's params object (contract §2), passed as
JSON by kcl-render; from the CLI it may also be a path to a YAML file with the
same content. With neither, an empty client renders (no detection, nothing
installed), so `nx build` compiles the package and a KclModule that lost its
params applies nothing instead of a demo.

Output is four top-level variables, not a YAML stream: `items` is what the
KclModule applies, `addons`, `unmapped` and `warnings` are what the operator
writes to state.json and the ClientPlatform status.
"""
import .lib
import yaml
import file

_raw = option("params")
_empty = {
    client = "none/none"
    config = {cloud = "gcp"}
}
_params = yaml.decode(file.read(_raw)) if typeof(_raw) == "str" else (_raw or _empty)
_plan = lib.plan(lib.Params {**_params})

items = _plan.items
addons = _plan.addons
unmapped = _plan.unmapped
warnings = _plan.warnings
