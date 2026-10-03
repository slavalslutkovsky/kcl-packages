"""
Entry point for the `gitops` package — Helm-style, values-driven, with env overlays.

Same contract as `app`, `manager` and `cncf`:

  kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -q | kubectl apply -f -
  kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -D env=forge -q
  kcl run packages/gitops -D values=packages/gitops/examples/values.yaml -D env=argocd -q
  # after publish: kcl run oci://docker.io/yurikrupnik/gitops -D values=... -q

`-D values=<path>` (like helm -f) or a values.yaml in the current directory;
`-D env=<name>` deep-merges <stem>.<name>.yaml over it (right wins; lists
replace, so the `forge` overlay only has to flip `source.origin` and the
`argocd` overlay only `engine`, `namespace` and `source.secretRef`). The
merged result is validated against the typed `Gitops` schema.

Apply order matters and the stream is already in it, but a bare cluster needs
two passes: `Entitlement`, `Forge` and `Repository` are instances of CRDs that
Crossplane and this repo's XRDs install (`just install-module forge`,
`just install-module repository`), and the engine — Flux or Argo CD, per
`engine` — must already be running for its two objects to mean anything.

With no values file present (e.g. `nx build gitops` from the repo root) this
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
    tenant.namespace = "demo"
    source = {url = "https://github.com/example/gitops", path = "./clusters/demo"}
    forge.hostname = "git.demo.example.org"
    repositories = [{name = "gitops", owner = "example"}]
}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_values = app.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_gitops: lib.Gitops = lib.Gitops {**_values}

manifests.yaml_stream(lib.render(_gitops))
