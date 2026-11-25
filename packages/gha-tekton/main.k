"""
Entry point for `gha-tekton`.

  # one workflow -> one PaC PipelineRun (fails while anything does not translate)
  kcl run packages/gha-tekton -D data=.github/workflows/ci.yml -q > .tekton/ci.yaml
  # what translated, what was mapped or ignored, what does not translate
  kcl run packages/gha-tekton -D data=.github/workflows/ci.yml -D report=true -q
  # runner images and action mappings (Config), optional
  kcl run packages/gha-tekton -D values=<values.yaml> -D data=<workflow.yml> -q

`-D data` is a workflow file (YAML) or an INGEST `workflow_file` record (JSON,
contract_ingest::Record: the workflow is `payload.content`, its path
`payload.path`). The PipelineRun is named after `name` in the values, else the
file's stem. Without `-D data` the bundled examples/workflow.yml renders with
examples/values.yaml, so `nx build gha-tekton` smoke-tests the package.
"""

import .lib
import manifests
import yaml
import file

_example = file.modpath() + "/examples"
_dataPath = option("data", default="") or _example + "/workflow.yml"
_valuesPath = option("values", default="") or (_example + "/values.yaml" if not option("data") else "")
assert (not _valuesPath) or file.exists(_valuesPath), "values file not found: '${_valuesPath}' (relative to ${file.workdir()})."
assert file.exists(_dataPath), "workflow not found: '${_dataPath}' (relative to ${file.workdir()})."

_raw = yaml.decode(file.read(_dataPath))
_isRecord = typeof(_raw) == "dict" and _raw.entity == "workflow_file" and _raw.payload
_workflow = yaml.decode(_raw.payload.content) if _isRecord else _raw
_source = _raw.payload.path if _isRecord else _dataPath
_stem = _source.split("/")[-1].removesuffix(".yml").removesuffix(".yaml")

_values = yaml.decode(file.read(_valuesPath)) if _valuesPath else {}
_config: lib.Config = lib.Config {**({name = _stem} | _values)}
_wf: lib.Workflow = lib.Workflow {**_workflow}

_report = str(option("report", default="")).lower() in ["true", "1", "yes"]

manifests.yaml_stream([lib.translate(_config, _wf, _source).report] if _report else lib.render(_config, _wf, _source))
