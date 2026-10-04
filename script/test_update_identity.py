import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import configure_updates


class BundleIdentityTests(unittest.TestCase):
    def test_build_metadata_must_match_update_trust(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root / 'updates').mkdir()
            trust = {'app_id': 'com.tlolabs.fillr',
                     'identities': {'macos': 'com.tlolabs.fillr'}, 'keys': {}}
            (root / 'updates/trust.json').write_text(json.dumps(trust))
            info = root / 'Info.plist'
            with patch.object(configure_updates, 'ROOT', root), patch.object(configure_updates, 'version', return_value='1.2.3'):
                for identifier in ('edu.chabot.news.backgrounder', 'com.tlolabs.fillr'):
                    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
                    if identifier != trust['app_id']:
                        with self.assertRaisesRegex(ValueError, 'bundle identifier'):
                            configure_updates.configure_plist(info, production=False)
                    else:
                        configure_updates.configure_plist(info, production=False)
                        self.assertEqual(plistlib.loads(info.read_bytes())['CFBundleVersion'], '1.2.3')
                trust['identities']['macos'] = 'another.app'
                (root / 'updates/trust.json').write_text(json.dumps(trust))
                with self.assertRaisesRegex(ValueError, 'bundle identifier'):
                    configure_updates.configure_plist(info, production=False)


if __name__ == '__main__':
    unittest.main()
