"""
Entry point for the `cncf` package — Helm-style, values-driven, with env overlays.

Same contract as `app` and `manager`:

  kcl run packages/cncf -D values=manifests/cncf/values.yaml -q | kubectl apply -f -
  kcl run packages/cncf -D values=manifests/cncf/values.yaml -D env=k3d -q
  # after publish: kcl run oci://docker.io/yurikrupnik/cncf -D values=... -q

`-D values=<path>` (like helm -f) or a values.yaml in the current directory;
`-D env=<name>` deep-merges <stem>.<name>.yaml over it (right wins; lists
replace, so an overlay can flip `runner` — `-D env=openshift` for the
OpenShift Local overlay — or replace `dependencies`). The
merged result is validated against the typed `Cncf` schema.

On a bare cluster apply the stream twice (`just cncf-apply`): the ClusterIssuers
and the Certificates are instances of the CRDs the cert-manager chart installs.

With no values file present (e.g. `nx build cncf` from the repo root) this
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

_demoValues = {runner = "kind"}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_values = app.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_cncf: lib.Cncf = lib.Cncf {**_values}

manifests.yaml_stream(lib.render(_cncf))
