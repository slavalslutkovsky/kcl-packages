"""
Entry point for the `app` package — Helm-style, values-driven, with env overlays.

USAGE (no local main.k / kcl.mod in your app dir — just values files):

  # base only, from the app's dir:
  cd apps/zerg/api/k8s
  kcl run /abs/path/to/packages/app -q | kubectl apply -f -

  # with an env overlay: deep-merges values.<env>.yaml over values.yaml
  kcl run /abs/path/to/packages/app -D env=prod -q | kubectl apply -f -

  # explicit base path (like `helm -f`); overlay becomes <stem>.<env>.yaml:
  kcl run /abs/path/to/packages/app -D values=apps/zerg/api/k8s/values.yaml -D env=dev -q
  # after publish: kcl run oci://docker.io/yurikrupnik/app -D env=prod -q

Values files are `Release`s: a `workload:` (backend/frontend) or `task:` (CLI),
plus optional `config:` (→ ConfigMap) and `externalSecret:`. The merged result is
validated against the typed schema — unknown/mistyped/missing fields fail the build.

Overlay model (like kustomize overlays / helm -f base -f env):
  values.yaml         base, shared across envs
  values.<env>.yaml   per-env diffs; deep-merged over base (right wins)

Library use (typed, in code): `import app`; call app.render / app.renderTask /
app.renderRelease / app.mergeValues. See examples/.

With no values file present (e.g. `nx build app` from the repo root) this renders
a built-in demo so the build still smoke-tests the package.
"""

import .lib
import manifests
import yaml
import file

# `-D values=<path>` (like helm -f), else a values.yaml in the current directory.
_explicit = option("values", default="")
_valuesPath = _explicit or "values.yaml"
_hasValues = file.exists(_valuesPath)

# An explicit -D values=<path> that isn't found is a hard error — never silently
# fall back to the demo (the path is CWD-relative; run from where it resolves).
assert (not _explicit) or _hasValues, "values file not found: '${_valuesPath}' (relative to current dir ${file.workdir()}). Pass an absolute path or run from the directory that contains it."

# `-D env=<name>` selects an overlay next to the base: <stem>.<env>.yaml.
_env = option("env", default="")
_overlayPath = _valuesPath[0:len(_valuesPath) - 5] + ".${_env}.yaml" if _env else ""
_hasOverlay = _env and file.exists(_overlayPath)
assert (not _env) or _hasOverlay, "env overlay not found: '${_overlayPath}' for -D env=${_env} (relative to ${file.workdir()})."

# Base values (or demo when nothing is provided), then deep-merge the env overlay.
_demoValues = {
    workload.name = "demo-api"
    workload.component = "api-server"
    workload.image = "demo/api:latest"
    workload.port = 8080
    workload.hpa = {minReplicas = 1, maxReplicas = 5}
    config.PORT = "8080"
}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_values = lib.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_release: lib.Release = lib.Release {**_values}

manifests.yaml_stream(lib.renderRelease(_release))
