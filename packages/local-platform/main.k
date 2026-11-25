"""
Entry point for the `local-platform` package — Helm-style, values-driven, with env overlays.

Same contract as `manager` and `gitops`, plus one switch for what to render:

  kcl run packages/local-platform -D values=<file> -D output=kind -q | kind create cluster --config -
  kcl run packages/local-platform -D values=<file> -q | kubectl apply -f -
  kcl run packages/local-platform -D values=<file> -D env=argocd -q | kubectl apply -f -

`-D values=<path>` (like helm -f) or a values.yaml in the current directory;
`-D env=<name>` deep-merges <stem>.<name>.yaml over it (right wins; lists
replace). The merged result is validated against the typed `Platform` schema.

`-D output=kind` renders the Kind cluster config instead of the manifests.

With no values file present (e.g. `nx build local-platform` from the repo
root) this renders the schema defaults so the build still smoke-tests the package.
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
# An overlay is resolved next to the values file, so it needs one. Typical
# cause: `-D values=$V` with V unset, which passes an empty path.
assert (not _env) or _hasValues, "-D env=${_env} needs a values file to overlay, but -D values is empty and there is no values.yaml in ${file.workdir()}. Pass -D values=<path>, e.g. -D values=packages/local-platform/examples/values.yaml"
_overlayPath = _valuesPath[0:len(_valuesPath) - 5:] + ".${_env}.yaml" if _env else ""
_hasOverlay = _env and file.exists(_overlayPath)
assert (not _env) or _hasOverlay, "env overlay not found: '${_overlayPath}' for -D env=${_env} (relative to ${file.workdir()})."

_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else {}
_values = app.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_platform: lib.Platform = lib.Platform {**_values}

_output = option("output", default="manifests")
assert _output in ["manifests", "kind"], "-D output must be manifests or kind, got '${_output}'"

# kind.Cluster computes its node list from private attributes; only the public
# ones are Kind config.
manifests.yaml_stream([lib.kindConfig(_platform)], opts={ignore_private = True}) if _output == "kind" else manifests.yaml_stream(lib.render(_platform))
