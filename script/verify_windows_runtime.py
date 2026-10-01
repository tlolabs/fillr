#!/usr/bin/env python3
"""Reject packages that depend on an unbundled compiler runtime from the build host."""
import pathlib
import re
import struct
import sys

RUNTIME = re.compile(r'^(?:vcruntime\d|msvcp\d|concrt\d|vcomp\d|libgcc|libstdc\+\+|libwinpthread)', re.I)

def imports(data):
    if data[:2] != b'MZ':
        raise ValueError('Not a PE file')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe+4] != b'PE\0\0':
        raise ValueError('Invalid PE signature')
    sections = struct.unpack_from('<H', data, pe+6)[0]
    optional_size = struct.unpack_from('<H', data, pe+20)[0]
    optional = pe+24
    magic = struct.unpack_from('<H', data, optional)[0]
    if magic not in (0x10b, 0x20b):
        raise ValueError('Unsupported PE optional header')
    directories = optional + (112 if magic == 0x20b else 96)
    table = optional + optional_size
    def offset(rva):
        for index in range(sections):
            section = table + index*40
            virtual_size, address, raw_size, raw_offset = struct.unpack_from('<IIII', data, section+8)
            if address <= rva < address + max(virtual_size, raw_size):
                result = raw_offset + rva - address
                if result >= len(data):
                    raise ValueError('PE RVA outside file')
                return result
        raise ValueError('Unmapped PE RVA')
    def name(rva):
        start = offset(rva)
        end = data.find(b'\0', start, min(start+512, len(data)))
        if end < 0:
            raise ValueError('Unterminated PE import name')
        return data[start:end].decode('ascii')
    result = []
    # Both normal and delay-loaded imports can hide a missing redistributable.
    for directory_index, record_size, name_index in [(1, 20, 3), (13, 32, 1)]:
        rva, size = struct.unpack_from('<II', data, directories+directory_index*8)
        if not rva:
            continue
        start = offset(rva)
        for cursor in range(start, min(start+size, len(data)), record_size):
            record = struct.unpack_from('<'+'I'*(record_size//4), data, cursor)
            if not any(record):
                break
            if directory_index == 13 and record[0] != 1:
                raise ValueError('Unsupported non-RVA delay import')
            result.append(name(record[name_index]))
    return result

def verify(directory):
    files = {p.name.lower(): p for p in directory.iterdir() if p.is_file()}
    for path in files.values():
        if path.suffix.lower() not in ('.exe', '.dll'):
            continue
        for dependency in imports(path.read_bytes()):
            if RUNTIME.match(dependency) and dependency.lower() not in files:
                raise ValueError(f'{path.name} requires unbundled runtime {dependency}')

if __name__ == '__main__':
    verify(pathlib.Path(sys.argv[1]))
