import pathlib
import struct
import tempfile
import unittest
from verify_windows_runtime import imports, verify


def image(dependency, delayed=False):
    data = bytearray(1024)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<H', data, 0x86, 1)
    struct.pack_into('<H', data, 0x94, 240)
    struct.pack_into('<H', data, 0x98, 0x20b)
    directory = 13 if delayed else 1
    struct.pack_into('<II', data, 0x98+112+8*directory, 0x1000, 64 if delayed else 40)
    struct.pack_into('<IIII', data, 0x98+240+8, 512, 0x1000, 512, 512)
    if delayed:
        struct.pack_into('<II', data, 512, 1, 0x1080)
    else:
        struct.pack_into('<I', data, 512+12, 0x1080)
    encoded = dependency.encode('ascii') + b'\0'
    data[640:640+len(encoded)] = encoded
    return data


class WindowsRuntimeTests(unittest.TestCase):
    def test_imports_include_delayed_dependencies(self):
        self.assertEqual(imports(image('VCRUNTIME140.dll', True)), ['VCRUNTIME140.dll'])

    def test_unbundled_cpp_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root/'fillr_core.dll').write_bytes(image('MSVCP140.dll'))
            with self.assertRaisesRegex(ValueError, 'unbundled runtime'):
                verify(root)

    def test_system_runtime_is_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root/'fillr_core.dll').write_bytes(image('KERNEL32.dll'))
            verify(root)

    def test_bundled_runtime_is_allowed_case_insensitively(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            (root/'fillr_core.dll').write_bytes(image('MSVCP140.dll'))
            (root/'msvcp140.dll').write_bytes(image('KERNEL32.dll'))
            verify(root)

    def test_invalid_binary_cannot_pass_packaging(self):
        with self.assertRaises(ValueError):
            imports(b'not a PE file')
