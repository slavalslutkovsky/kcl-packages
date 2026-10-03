import unittest

from function.backends import gcp
from function.spec import Spec


def spec(**extra):
    return Spec.from_xr(
        {
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "PackageRegistry",
            "metadata": {"name": "demo", "namespace": "apps"},
            "spec": {"region": "us-central1", **extra},
        }
    )


def observed_repo(fmt, location="us-central1", project="my-project"):
    resource_id = f"projects/{project}/locations/{location}/repositories/demo-{fmt}"
    return {"status": {"atProvider": {"id": resource_id, "location": location}}}


def wire(res, name):
    # What Crossplane actually receives: exclude_unset is resource.update()'s
    # own serialisation, so a field the renderer never set is absent here too.
    return res[name].model_dump(exclude_unset=True, by_alias=True)


def for_provider(res, name):
    return wire(res, name)["spec"]["forProvider"]


def external_name(res, name):
    return wire(res, name)["metadata"]["annotations"]["crossplane.io/external-name"]


class TestGcp(unittest.TestCase):
    def test_one_repository_per_format(self):
        res = gcp.render(spec(formats=["oci", "npm"]))
        self.assertEqual(["repo-npm", "repo-oci"], sorted(res))
        # The repository id is part of every artifact reference, and two
        # formats of one XR share a project and a location.
        self.assertEqual("demo-oci", external_name(res, "repo-oci"))
        self.assertEqual("demo-npm", external_name(res, "repo-npm"))
        self.assertEqual("DOCKER", for_provider(res, "repo-oci")["format"])
        self.assertEqual("NPM", for_provider(res, "repo-npm")["format"])
        self.assertEqual(
            "artifact.gcp.m.upbound.io/v1beta1", wire(res, "repo-npm")["apiVersion"]
        )
        self.assertEqual("RegistryRepository", wire(res, "repo-npm")["kind"])

    def test_docker_config_is_oci_only(self):
        res = gcp.render(spec(formats=["oci", "npm"], immutableTags=True))
        self.assertEqual(
            {"immutableTags": True}, for_provider(res, "repo-oci")["dockerConfig"]
        )
        self.assertNotIn("dockerConfig", for_provider(res, "repo-npm"))

    def test_untagged_retention_is_oci_only(self):
        res = gcp.render(
            spec(formats=["oci", "npm"], untaggedRetentionDays=14, keepLastImages=30)
        )
        oci = for_provider(res, "repo-oci")
        npm = for_provider(res, "repo-npm")
        self.assertEqual(
            ["delete-untagged", "keep-recent"],
            [p["id"] for p in oci["cleanupPolicies"]],
        )
        self.assertEqual(
            "1209600s", oci["cleanupPolicies"][0]["condition"]["olderThan"]
        )
        # Only a container image can be untagged; an npm version cannot.
        self.assertEqual(["keep-recent"], [p["id"] for p in npm["cleanupPolicies"]])
        self.assertEqual(
            {"keepCount": 30}, npm["cleanupPolicies"][0]["mostRecentVersions"]
        )
        self.assertFalse(npm["cleanupPolicyDryRun"])

    def test_no_retention_leaves_policies_out(self):
        self.assertNotIn(
            "cleanupPolicies", for_provider(gcp.render(spec()), "repo-oci")
        )

    def test_scan_on_push(self):
        enabled = for_provider(gcp.render(spec()), "repo-oci")
        disabled = for_provider(gcp.render(spec(scanOnPush=False)), "repo-oci")
        self.assertEqual(
            {"enablementConfig": "INHERITED"}, enabled["vulnerabilityScanningConfig"]
        )
        self.assertEqual(
            {"enablementConfig": "DISABLED"}, disabled["vulnerabilityScanningConfig"]
        )

    def test_public_access_binds_every_format(self):
        res = gcp.render(spec(formats=["oci", "npm"], publicAccess=True))
        self.assertEqual(
            ["public-reader-npm", "public-reader-oci", "repo-npm", "repo-oci"],
            sorted(res),
        )
        member = for_provider(res, "public-reader-npm")
        self.assertEqual(
            "RegistryRepositoryIAMMember", wire(res, "public-reader-npm")["kind"]
        )
        self.assertEqual("demo-npm", member["repository"])
        self.assertEqual("allUsers", member["member"])
        self.assertEqual("roles/artifactregistry.reader", member["role"])

    def test_private_composes_no_binding(self):
        self.assertEqual(["repo-oci"], sorted(gcp.render(spec())))

    def test_orphan_sets_management_policies(self):
        res = gcp.render(spec(deletionPolicy="Orphan", publicAccess=True))
        want = ["Observe", "Create", "Update", "LateInitialize"]
        self.assertEqual(want, wire(res, "repo-oci")["spec"]["managementPolicies"])
        self.assertEqual(
            want, wire(res, "public-reader-oci")["spec"]["managementPolicies"]
        )
        self.assertNotIn(
            "managementPolicies", wire(gcp.render(spec()), "repo-oci")["spec"]
        )

    def test_status_before_the_repositories_exist(self):
        got = gcp.status(spec(formats=["oci", "npm"]), {})
        self.assertFalse(got["ready"])
        self.assertEqual("gcp", got["provider"])
        self.assertEqual("us-central1", got["region"])
        self.assertNotIn("endpoints", got)
        self.assertNotIn("id", got)
        self.assertEqual("https://console.cloud.google.com/artifacts", got["cloud-url"])

    def test_status_once_observed(self):
        observed = {f"repo-{fmt}": observed_repo(fmt) for fmt in ("oci", "npm")}
        got = gcp.status(spec(formats=["oci", "npm"]), observed)
        self.assertTrue(got["ready"])
        self.assertEqual(
            {
                "oci": "us-central1-docker.pkg.dev/my-project/demo-oci",
                "npm": "https://us-central1-npm.pkg.dev/my-project/demo-npm/",
            },
            got["endpoints"],
        )
        self.assertEqual(
            "https://console.cloud.google.com/artifacts?project=my-project",
            got["cloud-url"],
        )

    def test_status_is_not_ready_until_every_format_exists(self):
        observed = {"repo-oci": observed_repo("oci", project="p")}
        got = gcp.status(spec(formats=["oci", "npm"]), observed)
        self.assertFalse(got["ready"])
        # The one repository that does exist is still worth publishing.
        self.assertEqual(["oci"], list(got["endpoints"]))


if __name__ == "__main__":
    unittest.main()
