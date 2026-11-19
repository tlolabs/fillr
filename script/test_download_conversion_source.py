#!/usr/bin/env python3
"""Run the Swift download observer/worker tests without building a FILLR app.

The native encoder entry points are test doubles; filesystem races, receipts,
state pruning, publication and Trash authorization use the real Swift source.
"""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


NATIVE_DOUBLES = r'''
func fillr_background_create() -> OpaquePointer? { nil }
func fillr_background_cancel(_ context: OpaquePointer) {}
func fillr_background_destroy(_ context: OpaquePointer) {}
func fillr_background_free_string(_ value: UnsafeMutablePointer<CChar>) {}
func fillr_download_transcode(_ context: OpaquePointer, _ input: UnsafePointer<CChar>,
                             _ output: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? { nil }
'''


class DownloadConversionSourceTests(unittest.TestCase):
    def test_download_worker_and_observer(self):
        root = Path(__file__).resolve().parents[1]
        tests = root / "native/macos/Tests/FILLRTests/DownloadTranscodeControllerTests.swift"
        paths = [
            root / "native/macos/Sources/FILLR/Models/EngineModels.swift",
            root / "native/macos/Sources/FILLR/Services/DownloadTranscodeController.swift",
            tests,
        ]
        source = NATIVE_DOUBLES + "\n" + "\n".join(path.read_text() for path in paths)
        for line in ("import CBackgroundEngine\n", "@testable import FILLR\n"):
            source = source.replace(line, "")
        count = len(re.findall(r"^    func test\w+\(", tests.read_text(), re.MULTILINE))
        self.assertGreater(count, 0, "No download XCTest cases discovered")
        source += f'''
let standaloneSuite = DownloadTranscodeControllerTests.defaultTestSuite
standaloneSuite.run()
let standaloneRun = standaloneSuite.testRun!
precondition(standaloneRun.executionCount == {count}, "Missing download test execution")
exit(standaloneRun.hasSucceeded ? 0 : 1)
'''
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        platform = developer / "Platforms/MacOSX.platform/Developer"
        frameworks = platform / "Library/Frameworks"
        libraries = platform / "usr/lib"
        with tempfile.TemporaryDirectory(prefix="fillr-conversion-tests-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(source)
            result = subprocess.run(
                ["xcrun", "swift", "-I", str(libraries), "-F", str(frameworks), "-L", str(libraries),
                 "-module-cache-path", str(directory / "module-cache"), str(main)],
                env={**os.environ, "DYLD_FRAMEWORK_PATH": str(frameworks), "DYLD_LIBRARY_PATH": str(libraries)},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
            )
            print(result.stdout)
            self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
