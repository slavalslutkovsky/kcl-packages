import tempfile
import unittest
from pathlib import Path

from xup.validate import validate_package

MINIMAL_META = (
    "apiVersion: meta.pkg.crossplane.io/v1\nkind: Configuration\nmetadata:\n  name: x\n"
)


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


class TestValidatePackage(unittest.TestCase):
    def test_missing_crossplane_yaml_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            issues = validate_package(Path(tmp))
        self.assertEqual(1, len(issues))
        self.assertEqual("error", issues[0].severity)
        self.assertIn("crossplane.yaml", issues[0].message)

    def test_composition_referencing_unknown_xrd_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / "crossplane.yaml", MINIMAL_META)
            write(
                root / "composition.yaml",
                "apiVersion: apiextensions.crossplane.io/v1\n"
                "kind: Composition\n"
                "metadata:\n  name: c\n"
                "spec:\n"
                "  compositeTypeRef:\n"
                "    apiVersion: storage.example.org/v1alpha1\n"
                "    kind: XBucket\n"
                "  mode: Pipeline\n"
                "  pipeline:\n"
                "    - step: render\n"
                "      functionRef:\n"
                "        name: function-patch-and-transform\n",
            )
            issues = validate_package(root)

        messages = [i.message for i in issues]
        self.assertTrue(any("matches no XRD" in m for m in messages))

    def test_xrd_without_schema_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root / "crossplane.yaml", MINIMAL_META)
            write(
                root / "xrd.yaml",
                "apiVersion: apiextensions.crossplane.io/v1\n"
                "kind: CompositeResourceDefinition\n"
                "metadata:\n  name: xbuckets.storage.example.org\n"
                "spec:\n"
                "  group: storage.example.org\n"
                "  names:\n    kind: XBucket\n    plural: xbuckets\n"
                "  claimNames:\n    kind: Bucket\n    plural: buckets\n"
                "  versions:\n"
                "    - name: v1alpha1\n"
                "      served: true\n"
                "      referenceable: true\n",
            )
            issues = validate_package(root)

        messages = [i.message for i in issues]
        self.assertTrue(any("openAPIV3Schema" in m for m in messages))
