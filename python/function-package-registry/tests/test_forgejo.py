import unittest

from function.backends import forgejo
from function.spec import Spec, SpecError


def spec(**extra):
    base = {"region": "in-cluster", "owner": "packages", "adminSecret": "demo-admin"}
    return Spec.from_xr(
        {
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "PackageRegistry",
            "metadata": {"name": "demo", "namespace": "apps"},
            "spec": {**base, **extra},
        }
    )


def wire(res, name):
    # What Crossplane actually receives: exclude_unset is resource.update()'s
    # own serialisation, so a field the renderer never set is absent here too.
    return res[name].model_dump(exclude_unset=True, by_alias=True)


def external_name(res):
    annotations = wire(res, "managed")["metadata"]["annotations"]
    return annotations["crossplane.io/external-name"]


def values(**extra):
    managed = wire(forgejo.render(spec(**extra)), "managed")
    return managed["spec"]["forProvider"]["values"]


class TestForgejo(unittest.TestCase):
    def test_owner_and_admin_secret_are_required(self):
        for missing in ("owner", "adminSecret"):
            with self.assertRaises(SpecError) as caught:
                forgejo.render(spec(**{missing: None}))
            self.assertIn("spec.owner and spec.adminSecret", str(caught.exception))

    def test_render(self):
        res = forgejo.render(spec())
        self.assertEqual(["managed"], sorted(res))
        fp = wire(res, "managed")["spec"]["forProvider"]
        self.assertEqual("apps", fp["namespace"])
        self.assertEqual(
            {
                "name": "forgejo",
                "repository": "oci://code.forgejo.org/forgejo-helm",
                "version": "17.1.5",
            },
            fp["chart"],
        )
        self.assertEqual("demo", external_name(res))

    def test_chart_values(self):
        got = values(storageGb=20)
        self.assertEqual("demo", got["fullnameOverride"])
        self.assertEqual("20Gi", got["persistence"]["size"])
        # In-cluster only, like the zot backend.
        self.assertFalse(got["ingress"]["enabled"])
        self.assertEqual("demo-admin", got["gitea"]["admin"]["existingSecret"])
        config = got["gitea"]["config"]
        # Forgejo writes ROOT_URL into every package registry URL it returns.
        self.assertEqual(
            "http://demo-http.apps.svc.cluster.local:3000/",
            config["server"]["ROOT_URL"],
        )
        self.assertEqual("demo-http.apps.svc.cluster.local", config["server"]["DOMAIN"])
        self.assertTrue(config["packages"]["ENABLED"])
        self.assertTrue(config["service"]["DISABLE_REGISTRATION"])
        self.assertTrue(config["service"]["REQUIRE_SIGNIN_VIEW"])

    def test_public_access_drops_the_signin_requirement(self):
        config = values(publicAccess=True)["gitea"]["config"]
        self.assertFalse(config["service"]["REQUIRE_SIGNIN_VIEW"])

    def test_every_format_has_an_endpoint(self):
        got = forgejo.status(
            spec(
                formats=[
                    "oci",
                    "npm",
                    "pypi",
                    "maven",
                    "go",
                    "cargo",
                    "nuget",
                    "generic",
                ]
            ),
            {},
        )
        host = "demo-http.apps.svc.cluster.local:3000"
        api = f"http://{host}/api/packages/packages"
        self.assertEqual(
            {
                "oci": f"{host}/packages",
                "npm": f"{api}/npm/",
                "pypi": f"{api}/pypi",
                "maven": f"{api}/maven",
                "go": f"{api}/go",
                "cargo": f"sparse+http://{host}/api/packages/packages/cargo/",
                "nuget": f"{api}/nuget/index.json",
                "generic": f"{api}/generic",
            },
            got["endpoints"],
        )

    def test_endpoints_follow_the_requested_formats(self):
        got = forgejo.status(spec(formats=["oci", "cargo"]), {})
        self.assertEqual(["oci", "cargo"], list(got["endpoints"]))
        self.assertEqual("demo-admin", got["authSecret"])
        self.assertEqual("kubernetes://apps/deployment/demo", got["cloud-url"])

    def test_ready_comes_from_the_release_condition(self):
        self.assertFalse(forgejo.status(spec(), {})["ready"])
        # atProvider.state is Helm's verdict; Ready also carries the provider's
        # own `wait` result, which is what spec.forProvider.wait was set for.
        deploying = {
            "managed": {
                "status": {
                    "atProvider": {"state": "deployed", "revision": 2},
                    "conditions": [{"type": "Synced", "status": "True"}],
                }
            }
        }
        self.assertFalse(forgejo.status(spec(), deploying)["ready"])
        deploying["managed"]["status"]["conditions"].append(
            {"type": "Ready", "status": "True"}
        )
        got = forgejo.status(spec(), deploying)
        self.assertTrue(got["ready"])
        self.assertEqual("apps/demo@2", got["id"])


if __name__ == "__main__":
    unittest.main()
