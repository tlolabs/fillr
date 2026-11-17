"""Exercise direct-source rawvideo transport without owner media or Adobe.

Each renderer call runs in its own process group with a deadline so a FIFO
startup/cancellation regression fails the test instead of hanging the suite.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest

from background_video import RATE, validate_output


_SCRIPT_DIR = Path(__file__).resolve().parent
_HARNESS = """
import json, sys
from pathlib import Path
from background_direct import render_direct
payload=json.loads(Path(sys.argv[1]).read_text())
commands=[]
try:
    result=render_direct(payload['panels'], [], payload['frames'], Path(payload['dest']),
                         'libx264', payload['ffmpeg'], commands)
    response={'ok':True,'result':result,'commands':commands}
except Exception as exc:
    response={'ok':False,'error':str(exc),'type':type(exc).__name__,'commands':commands}
Path(sys.argv[2]).write_text(json.dumps(response,indent=2))
"""


@unittest.skipUnless(os.name == "posix" and shutil.which("ffmpeg") and shutil.which("ffprobe"),
                     "POSIX FIFOs and FFmpeg tools are required")
class DirectSourceTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="fillr-direct-test-")
        self.addCleanup(self.work.cleanup)
        self.folder = Path(self.work.name)
        self.ffmpeg = shutil.which("ffmpeg")

    def make_source(self, name, color, frames):
        path = self.folder / name
        subprocess.run([self.ffmpeg, "-hide_banner", "-v", "error", "-nostdin", "-n",
                        "-f", "lavfi", "-i", f"color={color}:s=64x64:r={RATE}",
                        "-frames:v", str(frames), "-c:v", "ffv1", "-threads", "1",
                        "-pix_fmt", "yuv444p", str(path)], check=True, timeout=10)
        return path

    def panels(self, segments):
        return [{
            "comp": index + 1,
            "geometry": {"width": 64, "height": 64, "x": 10 + (index % 5) * 100,
                         "y": 10 + (index // 5) * 100,
                         "visible_width": 44, "visible_height": 44},
            "segments": [dict(segment) for segment in segments],
        } for index in range(15)]

    def invoke(self, panels, frames, ffmpeg=None):
        payload = self.folder / "payload.json"
        response = self.folder / "response.json"
        payload.write_text(json.dumps({"panels": panels, "frames": frames,
            "dest": str(self.folder / "direct.mp4"), "ffmpeg": ffmpeg or self.ffmpeg}))
        env = os.environ.copy()
        env["PYTHONPATH"] = str(_SCRIPT_DIR) + os.pathsep + env.get("PYTHONPATH", "")
        child = subprocess.Popen([sys.executable, "-c", _HARNESS, str(payload), str(response)],
                                 cwd=_SCRIPT_DIR.parent, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, start_new_session=True)
        try:
            stdout, stderr = child.communicate(timeout=40)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            stdout, stderr = child.communicate()
            self.fail(f"Direct renderer hung during FIFO startup/cancellation.\n{stdout}\n{stderr}")
        self.assertEqual(child.returncode, 0, f"Harness failed:\n{stdout}\n{stderr}")
        self.assertTrue(response.is_file(), f"No renderer result:\n{stdout}\n{stderr}")
        # Named pipes belong to the live job, not to its permanent artifacts.
        self.assertFalse([path for path in self.folder.rglob("*")
                          if stat.S_ISFIFO(path.stat().st_mode)], "FIFO was left behind")
        return json.loads(response.read_text())

    def test_fifteen_panels_preserve_cut_frame_and_output_contract(self):
        # Names intentionally oppose timeline order.
        red = self.make_source("z-red.mkv", "red", 4)
        blue = self.make_source("a-blue.mkv", "blue", 4)
        panels = self.panels([{"path": str(red), "source_in_seconds": 0, "frames": 4},
                              {"path": str(blue), "source_in_seconds": 0, "frames": 4}])
        response = self.invoke(panels, 8)
        self.assertTrue(response["ok"], response.get("error"))
        result = response["result"]
        self.assertIn(result["intermediate_video_files"], (0, []))
        self.assertEqual(result["rawvideo_bytes"], 15 * 8 * 64 * 64 * 3)
        self.assertEqual(len(result["panels"]), 15)
        self.assertEqual([panel["frames"] for panel in result["panels"]], [8] * 15)
        output = self.folder / "direct.mp4"
        validate_output(output, 8, "ffprobe")
        # Inspect a 2x2 center patch from every tile at every frame. The first
        # four frames must be red and the next four blue, without a gap or drift.
        filters = ["[0:v]split=15" + "".join(f"[s{i}]" for i in range(15))]
        for index, panel in enumerate(panels):
            geometry = panel["geometry"]
            filters.append(f"[s{index}]crop=2:2:{geometry['x']+22}:{geometry['y']+22}[c{index}]")
        filters.append("".join(f"[c{i}]" for i in range(15)) + "hstack=inputs=15,format=rgb24[out]")
        pixels = subprocess.check_output([self.ffmpeg, "-hide_banner", "-v", "error", "-nostdin",
            "-i", str(output), "-filter_complex", ";".join(filters), "-map", "[out]",
            "-frames:v", "8", "-c:v", "rawvideo", "-threads", "1", "-f", "rawvideo", "pipe:1"], timeout=10)
        bytes_per_frame = 30 * 2 * 3
        self.assertEqual(len(pixels), bytes_per_frame * 8)
        for frame in range(8):
            for offset in range(frame * bytes_per_frame, (frame + 1) * bytes_per_frame, 3):
                red_value, green_value, blue_value = pixels[offset:offset + 3]
                self.assertLess(green_value, 40)
                self.assertGreater(red_value if frame < 4 else blue_value, 200)
                self.assertLess(blue_value if frame < 4 else red_value, 40)

    def test_short_source_aborts_all_feeders_without_hanging(self):
        good = self.make_source("long.mkv", "blue", 30)
        short = self.make_source("short.mkv", "red", 3)
        panels = self.panels([{"path": str(good), "source_in_seconds": 0, "frames": 30}])
        panels[-1]["segments"][0]["path"] = str(short)
        response = self.invoke(panels, 30)
        self.assertFalse(response["ok"])
        self.assertEqual(response["type"], "RuntimeError")
        self.assertIn("Incomplete direct source", response["error"])

    def test_consumer_startup_failure_cancels_blocked_fifo_writers(self):
        source = self.make_source("source.mkv", "red", 4)
        wrapper = self.folder / "ffmpeg consumer failure"
        # Producers use rawvideo; only the H264 consumer is rejected. It exits
        # before opening any FIFOs, exercising cancellation of blocked writers.
        wrapper.write_text(f"#!{sys.executable}\nimport os,sys\n"
            "if 'libx264' in sys.argv:\n"
            " sys.stderr.write('intentional consumer startup failure\\n')\n"
            " sys.exit(19)\n"
            f"os.execv({self.ffmpeg!r},[{self.ffmpeg!r}]+sys.argv[1:])\n")
        wrapper.chmod(0o700)
        panels = self.panels([{"path": str(source), "source_in_seconds": 0, "frames": 4}])
        response = self.invoke(panels, 4, str(wrapper))
        self.assertFalse(response["ok"])
        self.assertEqual(response["type"], "RuntimeError")
        self.assertIn("consumer", response["error"].lower())
        self.assertIn("intentional consumer startup failure",
                      (self.folder / "direct.log").read_text())


if __name__ == "__main__":
    unittest.main()
