"""
Entry point for the `pulumi-mgmt` package: a Pulumi stack file in, the mgmt
stack spec out (lib.k explains its shape).

  # YAML, from the stack file the TypeScript program applies
  kcl run packages/pulumi-mgmt -D values=../infra/apps/mgmt/Pulumi.prod.yaml
  # JSON, to a file
  kcl run packages/pulumi-mgmt -D values=../infra/apps/mgmt/Pulumi.prod.yaml --format json -o mgmt.json

`-D values` is a `Pulumi.<stack>.yaml`; its `config:` is read like
pulumi.Config reads it (`org:*`, `gcp:region`, `<project>:*`), and `<stack>`
names the stack unless `-D stack=` does. `-D project=` is the Pulumi project,
the config namespace of the stack's own keys (default `mgmt`). With no values
file a built-in demo stack renders, so `nx build pulumi-mgmt` still
smoke-tests the package.
"""

import .lib
import yaml
import file

_valuesPath = option("values", default="")
assert (not _valuesPath) or file.exists(_valuesPath), "stack file not found: '${_valuesPath}' (relative to current dir ${file.workdir()})."

_project = option("project", default="mgmt")
_fileName = _valuesPath.split("/")[-1]
_stackFromFile = _fileName[len("Pulumi."):len(_fileName) - len(".yaml"):] if _fileName.startswith("Pulumi.") and _fileName.endswith(".yaml") else ""
_stack = option("stack", default="") or _stackFromFile or "prod"

# Placeholder organization: the demo must not carry the real one's ids.
_demo = {
  config = {
    "gcp:region" = "me-west1"
    "org:orgId" = "123456789012"
    "org:customerId" = "C0demo00"
    "org:billingAccount" = "000000-000000-000000"
    "org:orgDomain" = "example.com"
    "org:bootstrapUser" = "admin@example.com"
    "org:githubOrg" = "example"
    "org:prefix" = "demo"
    "mgmt:zone" = "me-west1-a"
    "mgmt:postgres" = "true"
    "mgmt:fluxBootstrap" = "true"
    "mgmt:fluxOperatorVersion" = "0.61.0"
  }
}

_stackFile = yaml.decode(file.read(_valuesPath)) if _valuesPath else _demo
_spec = lib.render(lib.fromStack(_stackFile, _project), _project, _stack)

project = _spec.project
stack = _spec.stack
description = _spec.description
config = _spec.config
variables = _spec.variables
resources = _spec.resources
if _spec.fluxBootstrap:
  fluxBootstrap = _spec.fluxBootstrap

outputs = _spec.outputs
