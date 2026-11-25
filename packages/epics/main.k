"""
Entry point for the `epics` package — values-driven like `app` and `fleet`.

  # the export (atlassian-ingest export-epics) + the catalog/rules values file
  kcl run packages/epics -D values=<values.yaml> -D data=<epics.json> -q | kubectl apply -f -
  # env overlay: <stem>.<env>.yaml deep-merged over the values file
  kcl run packages/epics -D values=<values.yaml> -D env=prod -D data=<epics.json> -q
  # the second reduce instead of the manifests: placement, dedicated nodes, waiting epics
  kcl run packages/epics -D values=<values.yaml> -D data=<epics.json> -D report=true -q

`-D data` is the export's JSON (YAML works too); its `epics` replace any
inline `epics:` in the values. With no values file a built-in demo renders,
so `nx build epics` still smoke-tests the package.
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

_dataPath = option("data", default="")
assert (not _dataPath) or file.exists(_dataPath), "epic export not found: '${_dataPath}' (relative to ${file.workdir()})."

# Deep, right-wins merge (maps merge, lists and scalars replace) — the same
# overlay semantics as fleet's main.k.
_merge = lambda base: {str:}, overlay: {str:} -> {str:} {
  {k: (_merge(base[k], overlay[k]) if (k in base and k in overlay and typeof(base[k]) == "dict" and typeof(overlay[k]) == "dict") else (overlay[k] if k in overlay else base[k])) for k in ([_kb for _kb in base] + [_ko for _ko in overlay if _ko not in base])}
}

_demoValues = {
  environment = "demo"
  cloud = {provider = "aws", region = "eu-west-1"}
  catalog = {
    "shop-api" = {app = {kind = "api", image = "ghcr.io/example/shop-api:1.0.0", uses = ["db"]}, resources = {databases = [{name = "db"}]}}
    "shop-web" = {
      app = {kind = "ui", image = "ghcr.io/example/shop-web:1.0.0"}
    }
  }
  epics = [
    {key = "PLAT-1", project_key = "PLAT", status = "In Progress", status_category = "In Progress", labels = ["customer-acme", "plan-team", "app-shop-api", "app-shop-web"]}
    {key = "PLAT-2", project_key = "PLAT", status = "Done", status_category = "Done", labels = ["customer-globex", "app-shop-web"]}
    {key = "PLAT-3", project_key = "PLAT", status = "To Do", status_category = "To Do", labels = ["customer-initech", "app-shop-web"]}
  ]
}
_base = yaml.decode(file.read(_valuesPath)) if _hasValues else _demoValues
_withEnv = _merge(_base, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _base
_values = _withEnv | {epics = yaml.decode(file.read(_dataPath)).epics} if _dataPath else _withEnv

_config: lib.Config = lib.Config {**_values}

_report = str(option("report", default="")).lower() in ["true", "1", "yes"]

manifests.yaml_stream([lib.report(_config)] if _report else lib.render(_config))
