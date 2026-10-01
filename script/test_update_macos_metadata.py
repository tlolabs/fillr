import copy
import unittest
from verify_macos_update import verify_bundle_metadata


class MacProductionMetadataTests(unittest.TestCase):
    def setUp(self):
        self.trust = dict(app_id='example.app', repository='example/app', keys={'test': 'public-test-key'})
        self.info = dict(CFBundleIdentifier='example.app', CFBundleVersion='1.2.3',
                         CFBundleShortVersionString='1.2.3', CFBundleExecutable='FILLR',
                         SUFeedURL='https://github.com/example/app/releases/latest/download/appcast.xml',
                         SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0,
                         SUVerifyUpdateBeforeExtraction=True, SUAutomaticallyUpdate=False,
                         SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
                         SUPublicEDKey='public-test-key')

    def test_valid_production_metadata(self):
        verify_bundle_metadata(self.info, '1.2.3', self.trust)

    def test_each_missing_or_modified_requirement_is_rejected(self):
        for key in self.info:
            with self.subTest(key=key):
                info = copy.deepcopy(self.info)
                del info[key]
                with self.assertRaises(ValueError):
                    verify_bundle_metadata(info, '1.2.3', self.trust)
                info[key] = 'unexpected'
                with self.assertRaises(ValueError):
                    verify_bundle_metadata(info, '1.2.3', self.trust)

    def test_unconfigured_or_ambiguous_key_is_rejected(self):
        for keys in [{}, {'one': 'key', 'two': 'key'}]:
            with self.assertRaises(ValueError):
                verify_bundle_metadata(self.info, '1.2.3', dict(self.trust, keys=keys))
