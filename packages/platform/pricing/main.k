"""
Entry point for the `pricing` package — prices an estate on every cloud.

  # the shipped example estate:
  just price

  # your own:
  kcl run packages/platform/pricing -D values=estate.yaml -q

The values file describes WHAT to price, in the XRDs' own field names:

  regionSet: us                 # one logical region, spelled per cloud
  clouds: [aws, gcp, azure]
  items:
    - name: platform
      capability: cluster       # vm | cluster | postgres | bucket
      nodeSize: medium
      nodeCount: 3

Every field is validated against `lib.Item`, so a capability this card cannot
price, or a bucket that forgot to say how big it is, is a build failure
rather than a comparison with a hole in it. `-D values=` behaves like
`packages/app` and `packages/platform/entitlement`: an explicit path that does
not exist is a hard error, never a silent fall back to the demo. `-D env=`
picks the `<stem>.<env>.yaml` overlay next to the values file, which is how a
prod estate is expressed as a diff against a staging one.

THE OUTPUT IS A REPORT, NOT A MANIFEST. The documents carry `kind` so `yq`
can select them, and deliberately no `apiVersion`: `PriceComparison` is not a
Kubernetes API and piping this into `kubectl apply` must fail outright rather
than half-work. Same rule as the Backstage catalog recipes (docs/backstage.md).

`-D skus=true` switches the output to the SKU inventory the size ladders
produce — the list `just price-refresh` fetches rates for. It is not a price
report; it is what keeps the refresher from drifting off the ladders.

With no values file present (`nx build pricing` from the repo root) this
prices the demo estate below, so the build still smoke-tests the card, the
ladders and the arithmetic together.
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

# The shape of a small production estate: one cluster, the database behind
# it, the bucket its artefacts live in, and the bastion someone still keeps.
_demo = {
    items = [
        {name = "platform", capability = "cluster", nodeSize = "medium", nodeCount = 3}
        {name = "platform-db", capability = "postgres", memoryGb = 8, storageGb = 100}
        {name = "platform-artifacts", capability = "bucket", storageGb = 500}
        {name = "bastion", capability = "vm", size = "small", diskGb = 30}
    ]
}
_baseValues = yaml.decode(file.read(_valuesPath)) if _hasValues else _demo
_values = app.mergeValues(_baseValues, yaml.decode(file.read(_overlayPath))) if _hasOverlay else _baseValues

_estate: lib.Estate = lib.Estate {**_values}

# `-D skus=true` prints the SKU inventory the ladders produce instead of a
# comparison: it is what `just price-refresh` asks the vendor APIs for, so the
# refresher can never drift from the ladders it is refreshing rates for.
# Stringified because -D always arrives as a string; same escape hatch as
# `packages/app -D catalog=true`.
_skus = str(option("skus", default="")).lower() in ["true", "1", "yes"]

manifests.yaml_stream(lib.render_skus(_estate.regionSet) if _skus else lib.render(_estate))
