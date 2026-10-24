import json
import re
import tempfile
from pathlib import Path
import unittest

from android_release import prepare, validate_version, verify_signature


class AndroidReleaseTests(unittest.TestCase):
    def test_release_signature_accepts_build_tools_36_and_37(self):
        fingerprint = "a" * 64
        for signer in ["Signer #1", "V3.0 Signer:"]:
            with self.subTest(signer=signer):
                verify_signature(f"{signer} certificate SHA-256 digest: {fingerprint}\n", fingerprint)

    def test_release_signature_rejects_wrong_missing_multiple_and_debug_signers(self):
        fingerprint = "a" * 64
        valid = f"V3.0 Signer: certificate SHA-256 digest: {fingerprint}\n"
        invalid = [
            valid.replace(fingerprint, "b" * 64),
            f"Source Stamp Signer certificate SHA-256 digest: {fingerprint}\n",
            valid + f"Signer #2 certificate SHA-256 digest: {'b' * 64}\n",
            valid + "V3.0 Signer: certificate DN: CN=Android Debug\n",
        ]
        for result in invalid:
            with self.subTest(result=result), self.assertRaises(ValueError):
                verify_signature(result, fingerprint)

    def test_release_matrices_select_only_the_requested_jobs(self):
        workflows = Path(__file__).resolve().parents[1] / "workflows"
        cases = [
            ("bridge.yml", "generate_bridge", "artifact-name",
             ["bridge-artifact", "bridge-artifact-flutter-3.44"], ["bridge-artifact"]),
            ("flutter-build.yml", "build-for-macOS", "target",
             ["x86_64-apple-darwin", "aarch64-apple-darwin"], ["aarch64-apple-darwin"]),
            ("flutter-build.yml", "build-rustdesk-android", "target",
             ["aarch64-linux-android", "armv7-linux-androideabi", "x86_64-linux-android"],
             ["aarch64-linux-android"]),
        ]
        for filename, job, field, all_targets, default_targets in cases:
            with self.subTest(job=job):
                source = (workflows / filename).read_text()
                block = re.search(rf"\n  {job}:\n(.*?)    steps:\n", source, re.S)[1]
                choices = re.findall(r"'(\[.*?\])'", block)
                self.assertEqual(len(choices), 2)
                for choice, expected in zip(choices, [all_targets, default_targets]):
                    jobs = json.loads(choice)
                    self.assertEqual([item[field] for item in jobs], expected)
                    for item in jobs:
                        self.assertIn("os", item)

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
