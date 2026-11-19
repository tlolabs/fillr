#!/usr/bin/env python3
"""Run the actual Swift progress model's XCTest cases without building FILLR."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


class DownloadFootageProgressSourceTests(unittest.TestCase):
    def test_swift_progress_model(self):
        root = Path(__file__).resolve().parents[1]
        paths = [
            root / "native/macos/Sources/FILLR/Models/EngineModels.swift",
            root / "native/macos/Sources/FILLR/Models/DownloadFootageProgress.swift",
            root / "native/macos/Sources/FILLR/Models/MediaPolicy.swift",
            root / "native/macos/Sources/FILLR/Models/SortSettings.swift",
            root / "native/macos/Tests/FILLRTests/DownloadFootageProgressTests.swift",
            root / "native/macos/Tests/FILLRTests/DownloadCollectionPolicyTests.swift",
            root / "native/macos/Tests/FILLRTests/SortSettingsTests.swift",
        ]
        source = 'enum BridgeError: Error { case message(String) }\n' + "\n".join(path.read_text() for path in paths)
        source = source.replace("@testable import FILLR\n", "")
        suites = []
        expected_count = 0
        for path in paths[-3:]:
            suite = re.search(r"final class (\w+): XCTestCase", path.read_text()).group(1)
            names = re.findall(r"^    func (test\w+)\(\)", path.read_text(), re.MULTILINE)
            self.assertTrue(names, "No XCTest cases discovered")
            expected_count += len(names)
            suites.append(f"standaloneSuite.addTest({suite}.defaultTestSuite)")
        source += '\nlet standaloneSuite = XCTestSuite(name: "Download progress source tests")\n'
        source += "\n".join(suites)
        source += f"\nstandaloneSuite.run()\nlet standaloneRun = standaloneSuite.testRun!\n"
        source += f"precondition(standaloneRun.executionCount == {expected_count}, \"Missing XCTest execution\")\n"
        source += "exit(standaloneRun.hasSucceeded ? 0 : 1)\n"
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        platform = developer / "Platforms/MacOSX.platform/Developer"
        frameworks = platform / "Library/Frameworks"
        libraries = platform / "usr/lib"
        with tempfile.TemporaryDirectory(prefix="fillr-progress-tests-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(source)
            result = subprocess.run(
                ["xcrun", "swift", "-I", str(libraries), "-F", str(frameworks),
                 "-L", str(libraries), "-module-cache-path", str(directory / "module-cache"), str(main)],
                env={**os.environ, "DYLD_FRAMEWORK_PATH": str(frameworks), "DYLD_LIBRARY_PATH": str(libraries)},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
            )
            print(result.stdout)
            self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
