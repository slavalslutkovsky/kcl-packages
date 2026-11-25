"""
Entry point for the `tenant-account` package.

  # cluster side: ProviderConfigs + the admission policy
  kcl run packages/platform/tenant-account -D values=accounts.yaml -q | kubectl apply -f -

  # client side: the CloudFormation template tenant-a's client deploys
  kcl run packages/platform/tenant-account -D values=accounts.yaml -D output=client -D namespace=tenant-a -q

Options:
  -D values=     values file validated as `lib.Values`; an explicit path that
                 does not exist is a hard error, never a silent fall back to
                 the demo. Without it, values.yaml in the current directory is
                 read if it exists, else the built-in demo renders.
  -D output=     cluster (default) | client
  -D namespace=  client output only: render just this tenant's template(s)
"""

import .lib
import manifests
import yaml
import file

_explicit = option("values", default="")
_valuesPath = _explicit or "values.yaml"
_hasValues = file.exists(_valuesPath)
assert (not _explicit) or _hasValues, "values file not found: '${_valuesPath}' (relative to current dir ${file.workdir()}). Pass an absolute path or run from the directory that contains it."

_output = option("output", default="cluster")
assert _output in ["cluster", "client"], "-D output= must be cluster or client, got '${_output}'"
_namespace = option("namespace", default="")
assert not _namespace or _output == "client", "-D namespace= only selects client templates; the cluster output always carries every account (the admission policy lists them all)"

_demo = {
  platform = {roleArn = "arn:aws:iam::111122223333:role/crossplane-provider-aws"}
  accounts = [
    {namespace = "tenant-a", accountId = "444455556666", externalId = "tenant-a-7f3c9e21", accessRoles = True}
    {namespace = "tenant-b", accountId = "777788889999", externalId = "tenant-b-0d84b6aa"}
  ]
}
_raw = yaml.decode(file.read(_valuesPath)) if _hasValues else _demo
_values = lib.Values {**_raw}

manifests.yaml_stream(lib.render(_values) if _output == "cluster" else lib.render_client(_values, _namespace))
