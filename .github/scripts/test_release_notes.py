import tempfile
import unittest
from pathlib import Path

from release_notes import render


class ReleaseNotesTests(unittest.TestCase):
    def test_uses_versioned_changes_and_source_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notes = root / 'docs/release-notes'
            notes.mkdir(parents=True)
            (notes / '1.5.1-2.md').write_text('## Changes\n\n- Native capture.\n')
            body = render(root, '1.5.1-2', '70', 'a' * 40)
            self.assertTrue(body.startswith('## Changes\n\n- Native capture.'))
            self.assertIn('Android versionCode: 70', body)
            self.assertIn('/commit/' + 'a' * 40, body)
            self.assertNotIn('APK is signed', body)

    def test_missing_or_empty_changes_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                render(root, '1.5.1-2', '70', 'a' * 40)
            notes = root / 'docs/release-notes'
            notes.mkdir(parents=True)
            (notes / '1.5.1-2.md').write_text(' \n')
            with self.assertRaises(ValueError):
                render(root, '1.5.1-2', '70', 'a' * 40)

    def test_rejects_invalid_version_and_commit(self):
        for version, sha in [('../secret', 'a' * 40), ('1.5.1-2', 'master')]:
            with self.assertRaises(ValueError):
                render(Path('.'), version, '70', sha)
