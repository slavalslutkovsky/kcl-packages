import tempfile
import unittest
from pathlib import Path

import yaml

from xup.clouds import resolve
from xup.scaffold import init_package
from xup.validate import validate_package


class TestInitPackage(unittest.TestCase):
    def test_scaffolds_a_package_per_cloud_that_passes_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bucket-demo"
            clouds = resolve("aws,gcp,azure")
            group = "storage.example.org"
            result = init_package(root, "bucket-demo", "Bucket", group, clouds)

            self.assertTrue((root / "crossplane.yaml").exists())
            self.assertTrue((root / "apis" / "bucket" / "definition.yaml").exists())
            for cloud in clouds:
                composition = root / "apis" / "bucket" / f"composition-{cloud.key}.yaml"
                example = root / "examples" / "bucket" / f"{cloud.key}.yaml"
                self.assertIn(composition, result.files)
                self.assertIn(example, result.files)

            self.assertEqual([], validate_package(root))

    def test_crossplane_yaml_depends_on_every_requested_cloud_provider(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "pkg"
            clouds = resolve("aws,gcp")
            init_package(root, "pkg", "Bucket", "storage.example.org", clouds)

            meta = yaml.safe_load((root / "crossplane.yaml").read_text())
            deps = {d["provider"] for d in meta["spec"]["dependsOn"]}
            self.assertEqual({c.provider_package for c in clouds}, deps)
