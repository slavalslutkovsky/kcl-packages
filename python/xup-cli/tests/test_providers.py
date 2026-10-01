import tempfile
import unittest
from pathlib import Path

from xup.providers import BUILTIN, list_providers

REGISTRY_YAML = """
version: 1
providers:
  - name: aws-s3
    cloud: aws
    image: ghcr.io/crossplane-contrib/provider-aws-s3
    tag: v2.6.0
    modules: [bucket]
  - name: some-operator
    cloud: kubernetes
    repo: some/operator
    ref: v1.0.0
    install: none
"""


class TestListProviders(unittest.TestCase):
    def test_builtin_catalog_filters_by_cloud(self):
        aws_only = list_providers(cloud="aws")
        self.assertTrue(aws_only)
        self.assertTrue(all(e.cloud == "aws" for e in aws_only))
        self.assertEqual(len(aws_only), len([e for e in BUILTIN if e.cloud == "aws"]))

    def test_registry_yaml_skips_rows_with_no_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry = Path(tmp) / "registry.yaml"
            registry.write_text(REGISTRY_YAML)
            entries = list_providers(registry=registry)

        self.assertEqual(1, len(entries))
        self.assertEqual("aws-s3", entries[0].name)
        self.assertEqual(("bucket",), entries[0].modules)
