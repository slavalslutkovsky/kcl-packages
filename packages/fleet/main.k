"""
Entry point for the `fleet` package — Helm-style, values-driven, with env overlays.

Same contract as `app`, `manager` and `cncf`:

  kcl run packages/fleet -D values=manifests/fleet/values.yaml -q | kubectl apply -f -
  kcl run packages/fleet -D values=manifests/fleet/values.yaml -D env=prod -q
  # one layer at a time: every Component is labelled platform.example.org/layer
  kcl run packages/fleet -D values=<file> -q | kubectl apply -l platform.example.org/layer=platform -f -
  # after publish: kcl run oci://docker.io/yurikrupnik/fleet -D values=... -q

`-D values=<path>` (like helm -f) or a values.yaml in the current directory;
`-D env=<name>` deep-merges <stem>.<name>.yaml over it (right wins; lists
replace, so an overlay can swap the whole `teams` list or pin different chart
versions). The merged result is validated against the typed `Fleet` schema.

The stream is `Component` XRs (plus the team Namespaces), so the cluster needs
Crossplane with the Component XRD and its Composition (`just install-module
component`) and Flux. Applying in one pass is fine: ordering lives in
`dependsOn` on the composed Flux objects, not in apply order.

With no values file present (e.g. `nx build fleet` from the repo root) this
renders a built-in demo so the build still smoke-tests the package.
"""

import .lib
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

# Deep, right-wins merge of the overlay over the base (Helm/kustomize overlay
# semantics): nested maps merge, scalars and LISTS replace. Written here rather
# than imported from packages/app, whose `mergeValues` has the same body but
# drags k8s, external-secrets, keda and chaos-mesh in with it — this package
# renders XRs and needs none of them.
_merge = lambda base: {str:}, overlay: {str:} -> {str:} {
    {k: (_merge(base[k], overlay[k]) if (k in base and k in overlay and typeof(base[k]) == "dict" and typeof(overlay[k]) == "dict") else (overlay[k] if k in overlay else base[k])) for k in ([_kb for _kb in base] + [_ko for _ko in overlay if _ko not in base])}
}

_demoValues = {
    name = "demo"
    platform = [{name = "crossplane", engine = "helm", source = {url = "https://charts.crossplane.io/stable"}, chart = "crossplane", version = "2.3.4", targetNamespace = "crossplane-system"}]
    teams = [{name = "web", namespace = "web", apps = [{
        name = "nginx"
        engine = "helm"
        source = {url = "oci://registry-1.docker.io/bitnamicharts"}
        chart = "nginx"
        version = "21.1.24"
    }]}]
}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_values = _merge(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_fleet: lib.Fleet = lib.Fleet {**_values}

manifests.yaml_stream(lib.render(_fleet))
