import unittest

from crossplane.function import logging, resource
from crossplane.function.proto.v1 import run_function_pb2 as fnv1
from google.protobuf import json_format

from function import fn


def request(backend=None, observed=None, **spec):
    kwargs = {}
    if backend is not None:
        kwargs["input"] = resource.dict_to_struct({"backend": backend})
    return fnv1.RunFunctionRequest(
        observed=fnv1.State(
            composite=fnv1.Resource(
                resource=resource.dict_to_struct(
                    {
                        "apiVersion": "cloud.example.org/v1alpha1",
                        "kind": "PackageRegistry",
                        "metadata": {"name": "demo", "namespace": "default"},
                        "spec": {"region": "us-central1", **spec},
                    }
                )
            ),
            resources={
                name: fnv1.Resource(resource=resource.dict_to_struct(obj))
                for name, obj in (observed or {}).items()
            },
        ),
        **kwargs,
    )


def gcp_repo(fmt):
    resource_id = f"projects/proj/locations/us-central1/repositories/demo-{fmt}"
    return {
        "apiVersion": "artifact.gcp.m.upbound.io/v1beta1",
        "kind": "RegistryRepository",
        "status": {"atProvider": {"id": resource_id, "location": "us-central1"}},
    }


def fatals(rsp):
    return [r.message for r in rsp.results if r.severity == fnv1.SEVERITY_FATAL]


def composite_status(rsp):
    return json_format.MessageToDict(rsp.desired.composite.resource).get("status", {})


class TestRunFunction(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.maxDiff = 2000
        logging.configure(level=logging.Level.DISABLED)
        self.runner = fn.FunctionRunner()

    async def test_missing_backend_is_fatal(self):
        rsp = await self.runner.RunFunction(request(), None)
        self.assertEqual(
            ["input.backend must be one of aws, gcp, azure, zot, forgejo"], fatals(rsp)
        )
        self.assertEqual({}, dict(rsp.desired.resources))

    async def test_unknown_backend_is_fatal(self):
        rsp = await self.runner.RunFunction(request(backend="harbor"), None)
        self.assertEqual(1, len(fatals(rsp)))
        self.assertEqual({}, dict(rsp.desired.resources))

    async def test_missing_region_is_fatal(self):
        req = fnv1.RunFunctionRequest(
            input=resource.dict_to_struct({"backend": "zot"}),
            observed=fnv1.State(
                composite=fnv1.Resource(
                    resource=resource.dict_to_struct({"metadata": {"name": "demo"}})
                )
            ),
        )
        rsp = await self.runner.RunFunction(req, None)
        self.assertEqual(["spec.region is required"], fatals(rsp))

    async def test_unsupported_format_is_fatal(self):
        rsp = await self.runner.RunFunction(
            request(backend="azure", formats=["oci", "npm"], resourceGroup="rg"), None
        )
        self.assertEqual(1, len(fatals(rsp)))
        message = fatals(rsp)[0]
        self.assertIn("npm", message)
        self.assertIn("Azure Container Registry is OCI-only", message)
        # A format a backend cannot serve composes nothing at all.
        self.assertEqual({}, dict(rsp.desired.resources))

    async def test_unknown_format_is_fatal(self):
        rsp = await self.runner.RunFunction(
            request(backend="gcp", formats=["oci", "brew"]), None
        )
        self.assertEqual(1, len(fatals(rsp)))
        self.assertIn("unknown format 'brew'", fatals(rsp)[0])

    async def test_composes_one_resource_per_format(self):
        rsp = await self.runner.RunFunction(
            request(backend="gcp", formats=["oci", "npm"]), None
        )
        self.assertEqual([], fatals(rsp))
        self.assertEqual(["repo-npm", "repo-oci"], sorted(rsp.desired.resources))
        status = composite_status(rsp)
        self.assertEqual("gcp", status["provider"])
        self.assertIn("ready", status)
        self.assertFalse(status["ready"])
        self.assertNotIn("endpoints", status)
        self.assertEqual(
            ["gcp: composed 2 resource(s) for formats oci, npm"],
            [r.message for r in rsp.results],
        )

    async def test_observed_state_reaches_the_status(self):
        observed = {f"repo-{fmt}": gcp_repo(fmt) for fmt in ("oci", "npm")}
        rsp = await self.runner.RunFunction(
            request(backend="gcp", formats=["oci", "npm"], observed=observed), None
        )
        status = composite_status(rsp)
        self.assertTrue(status["ready"])
        self.assertEqual(
            {
                "oci": "us-central1-docker.pkg.dev/proj/demo-oci",
                "npm": "https://us-central1-npm.pkg.dev/proj/demo-npm/",
            },
            status["endpoints"],
        )
        # Reading observed resources must not invent desired ones.
        self.assertEqual(["repo-npm", "repo-oci"], sorted(rsp.desired.resources))


if __name__ == "__main__":
    unittest.main()
