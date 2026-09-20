import json
import unittest

from function.backends import zot
from function.spec import Spec


def spec(**extra):
    return Spec.from_xr(
        {
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "PackageRegistry",
            "metadata": {"name": "demo", "namespace": "apps"},
            "spec": {"region": "in-cluster", **extra},
        }
    )


def values(**extra):
    return zot.render(spec(**extra))["managed"]["spec"]["forProvider"]["values"]


def config(**extra):
    return json.loads(values(**extra)["configFiles"]["config.json"])


class TestZot(unittest.TestCase):
    def test_render_minimal(self):
        res = zot.render(spec())
        self.assertEqual(["managed"], sorted(res))
        managed = res["managed"]
        self.assertEqual("helm.m.crossplane.io/v1beta1", managed["apiVersion"])
        self.assertEqual("Release", managed["kind"])
        self.assertEqual(
            "demo", managed["metadata"]["annotations"]["crossplane.io/external-name"]
        )
        self.assertEqual(
            "ClusterProviderConfig", managed["spec"]["providerConfigRef"]["kind"]
        )
        fp = managed["spec"]["forProvider"]
        self.assertEqual("apps", fp["namespace"])
        self.assertEqual(
            {
                "name": "zot",
                "repository": "https://zotregistry.dev/helm-charts",
                "version": "0.1.122",
            },
            fp["chart"],
        )
        self.assertTrue(fp["wait"])
        self.assertEqual("demo", fp["values"]["fullnameOverride"])
        self.assertEqual("ClusterIP", fp["values"]["service"]["type"])
        self.assertEqual("8Gi", fp["values"]["pvc"]["storage"])
        self.assertNotIn("externalSecrets", fp["values"])

    def test_storage_and_tags(self):
        got = values(storageGb=50, tags={"team": "platform"})
        self.assertEqual("50Gi", got["pvc"]["storage"])
        self.assertEqual({"team": "platform"}, got["podLabels"])

    def test_config_defaults(self):
        cfg = config()
        self.assertEqual("/var/lib/registry", cfg["storage"]["rootDirectory"])
        # Without gc the retention policies are recorded and never act.
        self.assertTrue(cfg["storage"]["gc"])
        self.assertNotIn("retention", cfg["storage"])
        self.assertEqual("5000", cfg["http"]["port"])
        self.assertNotIn("auth", cfg["http"])
        self.assertEqual("2h", cfg["extensions"]["search"]["cve"]["updateInterval"])

    def test_scanning_disabled(self):
        self.assertNotIn("extensions", config(scanOnPush=False))

    def test_retention_untagged(self):
        retention = config(untaggedRetentionDays=3)["storage"]["retention"]
        self.assertFalse(retention["dryRun"])
        self.assertEqual("72h", retention["delay"])
        self.assertTrue(retention["policies"][0]["deleteUntagged"])
        self.assertNotIn("keepTags", retention["policies"][0])

    def test_retention_keep_last(self):
        retention = config(keepLastImages=10)["storage"]["retention"]
        self.assertNotIn("delay", retention)
        self.assertFalse(retention["policies"][0]["deleteUntagged"])
        # keepTags patterns are Go regexes; "**" does not compile.
        self.assertEqual(
            [{"patterns": [".*"], "mostRecentlyPushedCount": 10}],
            retention["policies"][0]["keepTags"],
        )

    def test_auth_private(self):
        self.assertEqual(
            [{"secretName": "creds", "mountPath": "/secret"}],
            values(htpasswdSecret="creds")["externalSecrets"],
        )
        http = config(htpasswdSecret="creds")["http"]
        self.assertEqual("/secret/htpasswd", http["auth"]["htpasswd"]["path"])
        repos = http["accessControl"]["repositories"]["**"]
        self.assertEqual([], repos["anonymousPolicy"])
        self.assertIn("create", repos["defaultPolicy"])

    def test_auth_public_pull(self):
        repos = config(htpasswdSecret="creds", publicAccess=True)["http"][
            "accessControl"
        ]["repositories"]["**"]
        self.assertEqual(["read"], repos["anonymousPolicy"])

    def test_public_access_without_auth(self):
        # Without htpasswd there is nothing to make public: zot is already open.
        self.assertNotIn("accessControl", config(publicAccess=True)["http"])

    def test_orphan_sets_management_policies(self):
        res = zot.render(spec(deletionPolicy="Orphan"))
        self.assertEqual(
            ["Observe", "Create", "Update", "LateInitialize"],
            res["managed"]["spec"]["managementPolicies"],
        )

    def test_status(self):
        pending = zot.status(spec(), {})
        self.assertFalse(pending["ready"])
        # In-cluster endpoints are deterministic, so they precede the deploy.
        self.assertEqual(
            {"oci": "demo.apps.svc.cluster.local:5000/demo"}, pending["endpoints"]
        )
        self.assertEqual("kubernetes://apps/statefulset/demo", pending["cloud-url"])
        self.assertNotIn("authSecret", pending)

        observed = {
            "managed": {"status": {"atProvider": {"state": "deployed", "revision": 1}}}
        }
        got = zot.status(spec(htpasswdSecret="creds"), observed)
        self.assertTrue(got["ready"])
        self.assertEqual("apps/demo@1", got["id"])
        self.assertEqual("creds", got["authSecret"])


if __name__ == "__main__":
    unittest.main()
