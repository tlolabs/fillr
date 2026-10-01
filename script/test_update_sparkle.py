import base64, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
TOOL=ROOT/'native/macos/.build/artifacts/sparkle/Sparkle/bin/sign_update'
@unittest.skipUnless(TOOL.exists(), 'Sparkle signing tools require the macOS dependency build')
class SparkleSigningInterop(unittest.TestCase):
    def test_fixture_seed_signs_and_verifies_appcast(self):
        # Publicly known test-only seed; never used by a production build or trust file.
        seed=base64.b64encode(bytes([7])*32)+b'\n'
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory)/'appcast.xml'
            p.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Test fixture</title></channel></rss>')
            def invoke(*args):
                return subprocess.run([str(TOOL),*args,'--ed-key-file','-',str(p)],input=seed,capture_output=True)
            signed=invoke();self.assertEqual(signed.returncode,0,signed.stderr.decode())
            self.assertEqual(invoke('--verify').returncode,0)
            p.write_text(p.read_text().replace('Test fixture','Tampered fixture'))
            self.assertNotEqual(invoke('--verify').returncode,0)

    def test_archive_signature_rejects_corruption_truncation_and_wrong_key(self):
        seed=base64.b64encode(bytes([7])*32)+b'\n'
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory)/'update.zip'
            original=b'authenticated fixture bytes'
            p.write_bytes(original)
            signed=subprocess.run([str(TOOL),'-p','--ed-key-file','-',str(p)],input=seed,capture_output=True)
            self.assertEqual(signed.returncode,0,signed.stderr.decode())
            signature=signed.stdout.decode().strip()
            def verify(key=seed):
                return subprocess.run([str(TOOL),'--verify','--ed-key-file','-',str(p),signature],input=key,capture_output=True).returncode
            self.assertEqual(verify(),0)
            for wrong in [b'corrupted fixture bytes',original[:-1]]:
                p.write_bytes(wrong);self.assertNotEqual(verify(),0)
            p.write_bytes(original)
            self.assertNotEqual(verify(base64.b64encode(bytes([8])*32)+b'\n'),0)
            self.assertEqual(verify(),0)
