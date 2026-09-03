"""
Entry point for the `entitlement` package — renders the tenant records.

  # from a tenant list in version control:
  kcl run packages/platform/entitlement -D values=values.yaml -q | kubectl apply -f -

The values file is a list of records:

  tenants:
    - namespace: tenant-a
      plan: team
      features: [forgejo, repository]
      quota: {repositories: 50}

Every field is validated against `lib.Record`, so an unknown feature key or a
missing namespace is a build failure rather than a tenant who paid and then got
a fatal render. `-D values=` behaves like `packages/app`: an explicit path that
does not exist is a hard error, never a silent fall back to the demo.

The other half of this package is the GATE the Compositions import
(`lib.request` / `lib.resolve`); see the module docstring in lib.k.

With no values file present (`nx build entitlement` from the repo root) this
renders the examples, so the build still smoke-tests the schema.
"""

import .lib
import manifests
import yaml
import file

_explicit = option("values", default="")
_valuesPath = _explicit or "values.yaml"
_hasValues = file.exists(_valuesPath)

assert (not _explicit) or _hasValues, "values file not found: '${_valuesPath}' (relative to current dir ${file.workdir()}). Pass an absolute path or run from the directory that contains it."

_demo = {
    tenants = [
        {namespace = "tenant-a", plan = "team", features = ["forgejo", "repository"], quota = {repositories = 50}, reference = "sub_1P9xyzExample"}
        {namespace = "tenant-free", plan = "free", features = []}
    ]
}
_values = yaml.decode(file.read(_valuesPath)) if _hasValues else _demo
_records: [lib.Record] = [lib.Record {**t} for t in (_values?.tenants or [])]

manifests.yaml_stream(lib.render(_records))
