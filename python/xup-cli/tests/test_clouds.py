import unittest

from xup.clouds import resolve


class TestResolve(unittest.TestCase):
    def test_resolves_known_clouds_in_order(self):
        profiles = resolve("gcp,aws")
        self.assertEqual(["gcp", "aws"], [p.key for p in profiles])

    def test_rejects_unknown_cloud(self):
        with self.assertRaises(ValueError):
            resolve("aws,mars")

    def test_ignores_blank_entries(self):
        profiles = resolve("aws,,gcp")
        self.assertEqual(["aws", "gcp"], [p.key for p in profiles])
