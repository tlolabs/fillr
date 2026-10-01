#!/usr/bin/env python3
# Digests from the official AppImage/appimagetool 1.9.1 GitHub Release API.
import hashlib, pathlib, sys
PINNED = {"x86_64": "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0", "aarch64": "f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158"}
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != PINNED[sys.argv[2]]:
    raise SystemExit("AppImage packaging tool checksum mismatch")
