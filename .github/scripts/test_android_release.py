import tempfile
from pathlib import Path
import unittest

from android_release import prepare, validate_version


class AndroidReleaseTests(unittest.TestCase):
    def test_invalid_inputs(self):
        for version, code in [("v1.5.2", "69"), ("1.5.2; id", "69"), ("01.5.2", "69"),
                              ("1.5.2", "0"), ("1.5.2", "2100000001"), ("1.5.2", "69\n")]:
            with self.subTest(version=version, code=code), self.assertRaises(ValueError):
                validate_version(version, code)

    def test_prepare_keeps_native_flutter_and_lock_versions_consistent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "flutter").mkdir()
            (root / "Cargo.toml").write_text('[package]\nname = "rustdesk"\nversion = "1.5.1"\n')
            dependency = '[[package]]\nname = "other"\nversion = "1.5.1"\n'
            (root / "Cargo.lock").write_text(dependency + '[[package]]\nname = "rustdesk"\nversion = "1.5.1"\n')
            (root / "flutter/pubspec.yaml").write_text('name: flutter_hbb\nversion: 1.5.1+68\n')
            prepare(root, "1.5.2-1", "69", check_only=True)
            self.assertIn('version: 1.5.1+68', (root / "flutter/pubspec.yaml").read_text())
            prepare(root, "1.5.2-1", "69")
            self.assertIn('version = "1.5.2-1"', (root / "Cargo.toml").read_text())
            self.assertEqual((root / "Cargo.lock").read_text(), dependency + '[[package]]\nname = "rustdesk"\nversion = "1.5.2-1"\n')
            self.assertIn('version: 1.5.2-1+69', (root / "flutter/pubspec.yaml").read_text())
            with self.assertRaises(ValueError):
                prepare(root, "1.5.2", "69")


if __name__ == "__main__":
    unittest.main()
