import copy, importlib.util, json, pathlib, tempfile, unittest
from unittest.mock import patch
from release_updates import assemble, qualification, preflight, digest, TARGETS
from version import ROOT, version
import xml.etree.ElementTree as ET

class ReleasePolicyTests(unittest.TestCase):
    def test_native_version_properties_are_valid_xml_and_match(self):
        project = ET.parse(ROOT / 'native/windows/Version.props').getroot()
        self.assertEqual(project.findtext('PropertyGroup/Version'), version())
        self.assertEqual(project.findtext('PropertyGroup/AssemblyVersion'), version() + '.0')

    def test_authoritative_version(self):
        self.assertRegex(version(),r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
    def test_wrong_tag_cannot_publish(self):
        with self.assertRaises(ValueError): preflight('v99.99.99')
    def test_unconfigured_production_trust_cannot_publish(self):
        with patch('release_updates.trust',return_value={'keys':{},'identities':{'windows':'UNCONFIGURED'}}):
            with self.assertRaises(ValueError): preflight('v'+version())
    def test_build_success_is_not_upgrade_qualification(self):
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory);ledger=p/'ledger.json';ledger.write_text(json.dumps({'targets':{}}))
            with self.assertRaisesRegex(ValueError,'not qualified'):qualification(p,ledger)
    def test_qualification_is_bound_to_final_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory);ledger=p/'ledger.json';platform,arch,ext,_=TARGETS[0]
            asset=p/f'FILLR-{version()}-{platform}-{arch}.{ext}';asset.write_bytes(b'actual final artifact')
            evidence={k:True for k in ['discovered','authenticated','downloaded','installed','relaunched','user_data_preserved']}
            evidence.update(to_version=version(),from_version='0.0.0',artifact_sha256='0'*64,evidence_url='https://github.com/tlolabs/fillr/actions/runs/1')
            ledger.write_text(json.dumps({'targets':{platform+'-x86_64':evidence}}))
            with self.assertRaisesRegex(ValueError,'final artifact'):qualification(p,ledger)
    def test_no_unsigned_artifact_assembly(self):
        with tempfile.TemporaryDirectory() as directory:
            t={'app_id':'test','repository':'tlolabs/fillr','identities':{'macos':'test'}}
            with patch('release_updates.preflight',return_value=(version(),t)):
                with self.assertRaises(FileNotFoundError):assemble(pathlib.Path(directory),'v'+version())
    def test_digest_reflects_actual_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory)/'artifact';p.write_bytes(b'first');before=digest(p);p.write_bytes(b'second');self.assertNotEqual(before,digest(p))

if __name__=='__main__':unittest.main()
