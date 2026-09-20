"""The backends a PackageRegistry can be composed onto.

Every module here exposes the same four names — `NAME`, `SUPPORTED`,
`UNSUPPORTED_HINT`, `render(spec)` and `status(spec, observed)` — so
`function.fn` dispatches on the function input and knows nothing else about
any backend.
"""

from types import ModuleType

from function.backends import aws, azure, forgejo, gcp, zot

BACKENDS: dict[str, ModuleType] = {
    "aws": aws,
    "gcp": gcp,
    "azure": azure,
    "zot": zot,
    "forgejo": forgejo,
}
