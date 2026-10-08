import pathlib
import tempfile
import unittest
from release_updates import reject_internal_artifacts, TARGETS


class QtIsolationTests(unittest.TestCase):
    def test_internal_artifact_rejected_before_release_assembly(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'FILLR-qt-INTERNAL-osx-arm64.zip').touch()
            with self.assertRaisesRegex(ValueError, 'cannot enter production'):
                reject_internal_artifacts(root)

    def test_no_reference_target_in_release_contract(self):
        mac = [target for target in TARGETS if target[0] == 'macos']
        self.assertEqual(mac, [('macos', 'universal', 'zip', '13.0.0')])

    def test_internal_workflow_is_not_in_production_pipeline(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        for workflow in ['release-updates.yml', 'publish-updates.yml']:
            text = (root / '.github/workflows' / workflow).read_text()
            self.assertNotIn('build_qt_macos', text)
            self.assertNotIn('INTERNAL-ONLY', text)
        text = (root / '.github/workflows/build.yml').read_text()
        self.assertIn('INTERNAL-ONLY-FILLR-Qt-osx-arm64', text)


if __name__ == '__main__':
    unittest.main()
