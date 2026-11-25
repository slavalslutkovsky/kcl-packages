"""
Entry point for `mgmt-envs`: one env file in, its manifests (or its
prerequisites) out. lib.k explains the conventions.

  kcl run packages/cloud/mgmt/envs -D defaults=<defaults.yaml> -D env=<envs/dev.yaml>
  kcl run packages/cloud/mgmt/envs -D defaults=<defaults.yaml> -D env=<envs/dev.yaml> -D report=true

The env's name is its file stem. The workspace Taskfile drives this over a
whole catalog (`task controlplane:render`). With neither option a built-in
demo renders, so `nx build mgmt-envs` still smoke-tests the package.
"""

import .lib
import file
import manifests
import yaml

_defaultsPath = option("defaults", default="")
_envPath = option("env", default="")
assert bool(_defaultsPath) == bool(_envPath), "pass -D defaults and -D env together"
assert (not _defaultsPath) or file.exists(_defaultsPath), "defaults file not found: '${_defaultsPath}' (relative to ${file.workdir()})"
assert (not _envPath) or file.exists(_envPath), "env file not found: '${_envPath}' (relative to ${file.workdir()})"

# Placeholder organization: the demo must not carry the real one's ids.
_demoDefaults = {
  spec = {
    region = "me-west1"
    prefix = "demo"
    billingAccount = "000000-000000-000000"
    domain = "example.com"
    keys.gkeSecrets = "projects/demo-security/locations/me-west1/keyRings/platform/cryptoKeys/gke-secrets"
  }
}

_fileName = _envPath.split("/")[-1]
_envName = _fileName.removesuffix(".yaml").removesuffix(".yml") if _envPath else "dev"
_envFile = (yaml.decode(file.read(_envPath)) or {}) if _envPath else {}
assert "name" not in _envFile, "an env is named by its file name, not by `name:`"

_defaults = lib.Defaults {**(yaml.decode(file.read(_defaultsPath)) if _defaultsPath else _demoDefaults)}
_env = lib.Env {name = _envName, **_envFile}

_report = str(option("report", default="")).lower() in ["true", "1", "yes"]

manifests.yaml_stream([lib.prerequisites(_defaults, _env)] if _report else lib.render(_defaults, _env))
