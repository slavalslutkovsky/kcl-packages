import json
import unittest

from function.backends import aws
from function.spec import Spec


def spec(**extra):
    return Spec.from_xr(
        {
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "PackageRegistry",
            "metadata": {"name": "demo", "namespace": "apps"},
            "spec": {"region": "us-east-1", **extra},
        }
    )


def wire(res, name):
    # What Crossplane actually receives: exclude_unset is resource.update()'s
    # own serialisation, so a field the renderer never set is absent here too.
    return res[name].model_dump(exclude_unset=True, by_alias=True)


def external_name(res, name):
    return wire(res, name)["metadata"]["annotations"]["crossplane.io/external-name"]


def for_provider(res, name):
    return wire(res, name)["spec"]["forProvider"]


def at(**fields):
    return {"status": {"atProvider": fields}}


class TestAws(unittest.TestCase):
    def test_oci_only_composes_no_codeartifact(self):
        res = aws.render(spec(formats=["oci"]))
        self.assertEqual(["ecr"], sorted(res))
        self.assertEqual("ecr.aws.m.upbound.io/v1beta1", wire(res, "ecr")["apiVersion"])
        self.assertEqual("demo", external_name(res, "ecr"))
        self.assertEqual("MUTABLE", for_provider(res, "ecr")["imageTagMutability"])
        self.assertEqual(
            {"scanOnPush": True}, for_provider(res, "ecr")["imageScanningConfiguration"]
        )

    def test_language_only_composes_no_ecr(self):
        res = aws.render(spec(formats=["npm"]))
        self.assertEqual(["ca-domain", "ca-repository"], sorted(res))
        domain = for_provider(res, "ca-domain")
        repo = for_provider(res, "ca-repository")
        self.assertEqual("demo", domain["domain"])
        self.assertEqual("demo", repo["repository"])
        # Bound by controller reference, so the repository cannot drift onto
        # somebody else's domain.
        self.assertEqual({"matchControllerRef": True}, repo["domainSelector"])
        self.assertEqual(
            "codeartifact.aws.m.upbound.io/v1beta1",
            wire(res, "ca-domain")["apiVersion"],
        )

    def test_one_codeartifact_repository_serves_every_language(self):
        # CodeArtifact repositories are polyglot: one repository serves every
        # format under /<format>/<repository>/.
        res = aws.render(spec(formats=["oci", "npm", "pypi", "maven", "nuget"]))
        self.assertEqual(["ca-domain", "ca-repository", "ecr"], sorted(res))

    def test_lifecycle_policy_rule_priorities(self):
        res = aws.render(spec(untaggedRetentionDays=14, keepLastImages=30))
        self.assertIn("ecr-lifecycle", res)
        rules = json.loads(for_provider(res, "ecr-lifecycle")["policy"])["rules"]
        self.assertEqual([1, 2], [r["rulePriority"] for r in rules])
        self.assertEqual("untagged", rules[0]["selection"]["tagStatus"])
        self.assertEqual(14, rules[0]["selection"]["countNumber"])
        # An `any` rule must be the highest priority or ECR rejects the policy.
        self.assertEqual("any", rules[1]["selection"]["tagStatus"])
        self.assertEqual("imageCountMoreThan", rules[1]["selection"]["countType"])
        self.assertEqual({"type": "expire"}, rules[1]["action"])

    def test_retention_is_ecr_only(self):
        res = aws.render(spec(formats=["npm"], untaggedRetentionDays=14))
        self.assertEqual(["ca-domain", "ca-repository"], sorted(res))

    def test_public_access_adds_a_repository_policy(self):
        res = aws.render(spec(publicAccess=True))
        policy = json.loads(for_provider(res, "ecr-public-policy")["policy"])
        statement = policy["Statement"][0]
        self.assertEqual("*", statement["Principal"])
        self.assertIn("ecr:BatchGetImage", statement["Action"])
        self.assertEqual(
            {"matchControllerRef": True},
            for_provider(res, "ecr-public-policy")["repositorySelector"],
        )

    def test_kms_key_reaches_both_services(self):
        res = aws.render(spec(formats=["oci", "npm"], encryptionKeyId="arn:aws:kms:k"))
        self.assertEqual(
            [{"encryptionType": "KMS", "kmsKey": "arn:aws:kms:k"}],
            for_provider(res, "ecr")["encryptionConfiguration"],
        )
        self.assertEqual(
            "arn:aws:kms:k", for_provider(res, "ca-domain")["encryptionKey"]
        )

    def test_default_key_leaves_encryption_out(self):
        self.assertNotIn(
            "encryptionConfiguration", for_provider(aws.render(spec()), "ecr")
        )

    def test_orphan_sets_management_policies(self):
        res = aws.render(spec(formats=["oci", "npm"], deletionPolicy="Orphan"))
        want = ["Observe", "Create", "Update", "LateInitialize"]
        self.assertEqual(want, wire(res, "ecr")["spec"]["managementPolicies"])
        self.assertEqual(want, wire(res, "ca-domain")["spec"]["managementPolicies"])

    def test_status_endpoints(self):
        observed = {
            "ecr": at(
                arn="arn:aws:ecr:us-east-1:111122223333:repository/demo",
                id="demo",
                region="us-east-1",
                registryId="111122223333",
                repositoryUrl="111122223333.dkr.ecr.us-east-1.amazonaws.com/demo",
            ),
            "ca-domain": at(
                arn="arn:aws:codeartifact:us-east-1:111122223333:domain/demo",
                owner="111122223333",
            ),
            "ca-repository": at(arn="arn:aws:codeartifact:::repository/demo"),
        }
        got = aws.status(spec(formats=["oci", "npm", "pypi"]), observed)
        self.assertTrue(got["ready"])
        self.assertEqual(
            {
                "oci": "111122223333.dkr.ecr.us-east-1.amazonaws.com/demo",
                "npm": "https://demo-111122223333.d.codeartifact.us-east-1.amazonaws.com/npm/demo/",
                "pypi": "https://demo-111122223333.d.codeartifact.us-east-1.amazonaws.com/pypi/demo/",
            },
            got["endpoints"],
        )
        self.assertEqual(
            "https://us-east-1.console.aws.amazon.com/ecr/repositories/private/111122223333/demo?region=us-east-1",
            got["cloud-url"],
        )
        self.assertEqual(
            "arn:aws:ecr:us-east-1:111122223333:repository/demo", got["arn"]
        )

    def test_language_endpoints_wait_for_the_domain_owner(self):
        observed = {"ca-domain": at(arn="arn:x")}
        got = aws.status(spec(formats=["npm"]), observed)
        # The account id is not in the XR: no owner, no endpoint.
        self.assertNotIn("endpoints", got)
        self.assertEqual(
            "https://us-east-1.console.aws.amazon.com/codesuite/codeartifact/domains?region=us-east-1",
            got["cloud-url"],
        )

    def test_ready_ignores_services_the_xr_did_not_ask_for(self):
        ecr_only = {"ecr": at(arn="arn:x")}
        self.assertTrue(aws.status(spec(formats=["oci"]), ecr_only)["ready"])
        # …but an XR that asked for npm too is not ready on ECR alone.
        self.assertFalse(aws.status(spec(formats=["oci", "npm"]), ecr_only)["ready"])
        both = {"ca-domain": at(arn="arn:d"), "ca-repository": at(arn="arn:r")}
        self.assertTrue(aws.status(spec(formats=["npm"]), both)["ready"])
        self.assertFalse(
            aws.status(spec(formats=["npm"]), {"ca-domain": at(arn="arn:d")})["ready"]
        )


if __name__ == "__main__":
    unittest.main()
