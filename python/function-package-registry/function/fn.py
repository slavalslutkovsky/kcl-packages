"""A Crossplane composition function composing PackageRegistry XRs."""

from types import ModuleType

import grpc
from crossplane.function import logging, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from crossplane.function.proto.v1 import run_function_pb2_grpc as grpcv1

from function.backends import BACKENDS
from function.spec import FORMATS, Spec, SpecError

BACKEND_NAMES = ", ".join(BACKENDS)


def served_by(fmt: str) -> str:
    """The backends that serve one format, for the unsupported-format error."""
    names = [name for name, mod in BACKENDS.items() if fmt in mod.SUPPORTED]
    return f"{fmt} -> {', '.join(names) if names else 'no backend'}"


def unsupported_message(mod: ModuleType, unsupported: list[str]) -> str:
    """The fatal result for formats a backend cannot serve.

    Names what the backend does compose, why it cannot serve the rest, and
    which backend would — so the XR author can fix the XR from the message.
    """
    composes = ", ".join(f for f in FORMATS if f in mod.SUPPORTED)
    return (
        f"{mod.NAME} backend composes {composes}; "
        f"spec.formats asks for {', '.join(unsupported)}. "
        f"{mod.UNSUPPORTED_HINT} "
        f"Served by: {'; '.join(served_by(f) for f in unsupported)}."
    )


class FunctionRunner(grpcv1.FunctionRunnerService):
    """A FunctionRunner handles gRPC RunFunctionRequests."""

    def __init__(self):
        """Create a new FunctionRunner."""
        self.log = logging.get_logger()

    async def RunFunction(
        self, req: fnv1.RunFunctionRequest, _: grpc.aio.ServicerContext
    ) -> fnv1.RunFunctionResponse:
        """Compose one PackageRegistry onto the backend the input names."""
        log = self.log.bind(tag=req.meta.tag)
        rsp = response.to(req)

        backend = resource.struct_to_dict(req.input).get("backend")
        mod = BACKENDS.get(backend) if isinstance(backend, str) else None
        if mod is None:
            response.fatal(rsp, f"input.backend must be one of {BACKEND_NAMES}")
            return rsp

        try:
            xr = resource.struct_to_dict(req.observed.composite.resource)
            spec = Spec.from_xr(xr)
            # A format the backend cannot serve is an error, never a silently
            # dropped repository: the XR asked for a package manager it would
            # then never be able to publish to.
            unsupported = [f for f in spec.formats if f not in mod.SUPPORTED]
            if unsupported:
                msg = unsupported_message(mod, unsupported)
                response.fatal(rsp, msg)
                return rsp
            desired = mod.render(spec)
        except SpecError as e:
            response.fatal(rsp, str(e))
            return rsp

        for name, obj in desired.items():
            resource.update(rsp.desired.resources[name], obj)

        # `.items()`, never bracket access: reading a missing key on the proto
        # map would add an empty entry to the observed state.
        observed = {
            name: resource.struct_to_dict(r.resource)
            for name, r in req.observed.resources.items()
        }
        resource.update(rsp.desired.composite, {"status": mod.status(spec, observed)})

        log.info("Composed package registry", backend=mod.NAME, resources=len(desired))
        response.normal(
            rsp,
            f"{mod.NAME}: composed {len(desired)} resource(s) "
            f"for formats {', '.join(spec.formats)}",
        )
        return rsp
