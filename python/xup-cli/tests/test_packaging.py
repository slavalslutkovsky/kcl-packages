import tempfile
import unittest
from pathlib import Path
from unittest import mock

from xup.packaging import PackagingError, build_xpkg, push_xpkg


def _only_on_path(tool_name):
    def which(t):
        return t if t == tool_name else None

    return mock.patch("shutil.which", side_effect=which)


def _run_ok():
    return mock.patch("subprocess.run", return_value=mock.Mock(returncode=0, stderr=""))


class TestFindTool(unittest.TestCase):
    def test_build_raises_when_no_tool_on_path(self):
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(PackagingError):
                build_xpkg(Path("/tmp/pkg"))

    def test_build_prefers_crossplane_over_up(self):
        with _only_on_path("crossplane"), _run_ok() as mock_run:
            build_xpkg(Path("/tmp/pkg"), output=Path("/tmp/pkg/out.xpkg"))

        cmd = mock_run.call_args[0][0]
        self.assertEqual("crossplane", cmd[0])
        self.assertIn("/tmp/pkg/out.xpkg", cmd)

    def test_build_raises_on_nonzero_exit(self):
        which = _only_on_path("up")
        failed = mock.Mock(returncode=1, stderr="boom")
        run = mock.patch("subprocess.run", return_value=failed)
        with which, run:
            with self.assertRaises(PackagingError):
                build_xpkg(Path("/tmp/pkg"), output=Path("/tmp/pkg/out.xpkg"))

    def test_build_passes_examples_root_explicitly_when_present(self):
        # crossplane's own --examples-root default ("./examples") is relative
        # to the *current directory*, not --package-root, so xup must always
        # pass it explicitly or a build from anywhere else fails trying to
        # parse the scaffolded examples as package objects.
        with tempfile.TemporaryDirectory() as tmp:
            package_dir = Path(tmp) / "pkg"
            (package_dir / "examples").mkdir(parents=True)

            with _only_on_path("crossplane"), _run_ok() as mock_run:
                build_xpkg(package_dir, output=package_dir / "out.xpkg")

            cmd = mock_run.call_args[0][0]
        self.assertIn("--examples-root", cmd)
        expected = str(package_dir / "examples")
        self.assertEqual(expected, cmd[cmd.index("--examples-root") + 1])

    def test_push_invokes_xpkg_push_with_tag(self):
        with _only_on_path("crossplane"), _run_ok() as mock_run:
            push_xpkg(Path("/tmp/pkg/out.xpkg"), "xpkg.upbound.io/org/pkg:v0.1.0")

        cmd = mock_run.call_args[0][0]
        expected = [
            "crossplane",
            "xpkg",
            "push",
            "xpkg.upbound.io/org/pkg:v0.1.0",
            "-f",
            "/tmp/pkg/out.xpkg",
        ]
        self.assertEqual(expected, cmd)
