import unittest

from function.backends import azure
from function.spec import Spec, SpecError


def spec(**extra):
    return Spec.from_xr(
        {
            "apiVersion": "cloud.example.org/v1alpha1",
            "kind": "PackageRegistry",
            "metadata": {"name": "demoregistry", "namespace": "apps"},
            "spec": {"region": "westeurope", "resourceGroup": "platform-rg", **extra},
        }
    )


def wire(res, name):
    # What Crossplane actually receives: exclude_unset is resource.update()'s
    # own serialisation, so a field the renderer never set is absent here too.
    return res[name].model_dump(exclude_unset=True, by_alias=True)


def external_name(res):
    annotations = wire(res, "managed")["metadata"]["annotations"]
    return annotations["crossplane.io/external-name"]


def for_provider(res):
    return wire(res, "managed")["spec"]["forProvider"]


class TestAzure(unittest.TestCase):
    def test_resource_group_is_required(self):
        bare = Spec.from_xr(
            {"metadata": {"name": "demoregistry"}, "spec": {"region": "westeurope"}}
        )
        with self.assertRaises(SpecError) as caught:
            azure.render(bare)
        self.assertIn("spec.resourceGroup is required", str(caught.exception))

    def test_single_registry(self):
        res = azure.render(spec())
        self.assertEqual(["managed"], sorted(res))
        self.assertEqual(
            "containerregistry.azure.m.upbound.io/v1beta1",
            wire(res, "managed")["apiVersion"],
        )
        self.assertEqual("demoregistry", external_name(res))
        fp = for_provider(res)
        self.assertEqual("Standard", fp["sku"])
        self.assertEqual("platform-rg", fp["resourceGroupName"])
        # Entra ID tokens are the supported path; the shared admin pair is not.
        self.assertFalse(fp["adminEnabled"])
        self.assertFalse(fp["anonymousPullEnabled"])
        self.assertFalse(fp["zoneRedundancyEnabled"])

    def test_premium_is_forced_by_the_features_that_need_it(self):
        self.assertEqual(
            "Premium", for_provider(azure.render(spec(tier="premium")))["sku"]
        )
        self.assertEqual(
            "Premium", for_provider(azure.render(spec(untaggedRetentionDays=7)))["sku"]
        )
        self.assertEqual(
            "Premium",
            for_provider(azure.render(spec(replicationRegions=["northeurope"])))["sku"],
        )
        self.assertTrue(
            for_provider(azure.render(spec(tier="premium")))["zoneRedundancyEnabled"]
        )

    def test_georeplications_exclude_the_primary_region(self):
        fp = for_provider(
            azure.render(spec(replicationRegions=["westeurope", "northeurope"]))
        )
        self.assertEqual(
            ["northeurope"], [g["location"] for g in fp["georeplications"]]
        )

    def test_customer_managed_keys_need_both_halves(self):
        key_only = for_provider(azure.render(spec(encryptionKeyId="https://kv/keys/a")))
        self.assertNotIn("encryption", key_only)
        self.assertNotIn("identity", key_only)
        paired = for_provider(
            azure.render(
                spec(
                    encryptionKeyId="https://kv/keys/a",
                    encryptionIdentityClientId="1111-2222",
                )
            )
        )
        self.assertEqual({"type": "UserAssigned"}, paired["identity"])
        self.assertEqual(
            {"keyVaultKeyId": "https://kv/keys/a", "identityClientId": "1111-2222"},
            paired["encryption"],
        )

    def test_status_before_and_after(self):
        pending = azure.status(spec(), {})
        self.assertFalse(pending["ready"])
        self.assertNotIn("endpoints", pending)
        observed = {
            "managed": {
                "status": {
                    "atProvider": {
                        "loginServer": "demoregistry.azurecr.io",
                        "location": "westeurope",
                        "id": "/subscriptions/s/resourceGroups/platform-rg/x",
                    },
                },
            },
        }
        got = azure.status(spec(), observed)
        self.assertTrue(got["ready"])
        self.assertEqual(
            {"oci": "demoregistry.azurecr.io/demoregistry"}, got["endpoints"]
        )
        self.assertEqual(
            "https://portal.azure.com/#@/resource/subscriptions/s/resourceGroups/platform-rg/x",
            got["cloud-url"],
        )


if __name__ == "__main__":
    unittest.main()
