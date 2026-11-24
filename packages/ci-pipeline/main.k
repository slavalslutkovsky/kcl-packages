"""
Entry point for `ci-pipeline`.

  # Cloud Build config, for `gcloud builds submit --config`
  kcl run packages/ci-pipeline/main.k -D values=<pipeline.yaml> -q > cloudbuild.yaml
  # Crossplane Trigger MRs (one per event), the same build inline
  kcl run packages/ci-pipeline/main.k -D values=<pipeline.yaml> -D target=cloudbuild-trigger -q
  # GitHub Actions workflow
  kcl run packages/ci-pipeline/main.k -D values=<pipeline.yaml> -D target=gha -q > .github/workflows/<name>.yml

Without `-D values`, examples/pipeline.yaml renders. That is how `nx build ci-pipeline`
smoke-tests the package.
"""
import .lib
import .cloudbuild
import .gha
import manifests
import yaml
import file

_TARGETS = ["cloudbuild", "cloudbuild-trigger", "gha"]

_valuesPath = option("values", default="") or file.modpath() + "/examples/pipeline.yaml"
_target = option("target", default="") or "cloudbuild"
assert file.exists(_valuesPath), "values file not found: '${_valuesPath}' (relative to ${file.workdir()})."
assert _target in _TARGETS, "target is one of ${_TARGETS}, got '${_target}'"

_pipeline: lib.Pipeline = lib.Pipeline {**yaml.decode(file.read(_valuesPath))}

manifests.yaml_stream([cloudbuild.config(_pipeline)] if _target == "cloudbuild" else cloudbuild.triggers(_pipeline) if _target == "cloudbuild-trigger" else [gha.workflow(_pipeline)])
