"""The base class every generated provider model inherits.

`extra="forbid"` is the whole point of generating these models: a misspelled
field on a composed resource is then a ValidationError at render time (and in
the unit tests) instead of a key the API server silently prunes on apply. The
KCL renderers in packages/cloud/** get the same guarantee from their generated
schema packages under packages/providers/**.

`resource.update()` serialises a model with `exclude_unset=True`, so a field
this function never sets is never part of the desired state — Crossplane's
server-side-apply intent stays exactly what the XR asked for.
"""

import pydantic


class Resource(pydantic.BaseModel):
    """A managed resource (or one of its nested blocks), strictly typed."""

    # validate_assignment so the conditional `obj.field = …` blocks the
    # renderers use (the shape KCL writes as an `if` inside a schema literal)
    # are checked exactly like constructor arguments.
    model_config = pydantic.ConfigDict(extra="forbid", validate_assignment=True)
