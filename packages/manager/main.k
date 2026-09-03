"""
Entry point for the `manager` package — Helm-style, values-driven, with env overlays.

Same contract as `app`:

  kcl run packages/manager -D values=manifests/manager/values.yaml -q | kubectl apply -f -
  kcl run packages/manager -D values=manifests/manager/values.yaml -D env=staging -q
  # one phase at a time: every dependency is labelled platform.example.org/type=<manager|application>
  kcl run packages/manager -D values=manifests/manager/values.yaml -q | kubectl apply -l platform.example.org/type=manager -f -
  # after publish: kcl run oci://docker.io/yurikrupnik/manager -D values=... -q

`-D values=<path>` (like helm -f) or a values.yaml in the current directory;
`-D env=<name>` deep-merges <stem>.<name>.yaml over it (right wins; lists
replace, so an overlay can set `chaos: {experiments: []}` or `paused: true`).
The merged result is validated against the typed `Manager` schema.

With no values file present (e.g. `nx build manager` from the repo root) this
renders a built-in demo so the build still smoke-tests the package.
"""

import .lib
import app.lib as app
import manifests
import yaml
import file

_explicit = option("values", default="")
_valuesPath = _explicit or "values.yaml"
_hasValues = file.exists(_valuesPath)
assert (not _explicit) or _hasValues, "values file not found: '${_valuesPath}' (relative to current dir ${file.workdir()}). Pass an absolute path or run from the directory that contains it."

_env = option("env", default="")
_overlayPath = _valuesPath[0:len(_valuesPath) - 5:] + ".${_env}.yaml" if _env else ""
_hasOverlay = _env and file.exists(_overlayPath)
assert (not _env) or _hasOverlay, "env overlay not found: '${_overlayPath}' for -D env=${_env} (relative to ${file.workdir()})."

_demoValues = {
    role = "manager"
    dependencies = [{name = "chaos-mesh", $type = "application", repo = "https://charts.chaos-mesh.org", version = "2.8.4"}]
    chaos.experiments = [{name = "demo-kill", $type = "pod-kill", target.namespaces = ["demo"]}]
}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_values = app.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_manager: lib.Manager = lib.Manager {**_values}

manifests.yaml_stream(lib.render(_manager))
