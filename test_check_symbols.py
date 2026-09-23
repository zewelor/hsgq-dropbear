#!/usr/bin/env python3
"""Regression checks for the firmware symbol gate."""

import os
import runpy
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


CHECKER_PATH = Path(__file__).with_name('check-symbols.py')
CHECKER = runpy.run_path(str(CHECKER_PATH))


class SymbolGateTests(unittest.TestCase):
    def test_non_elf_binaries_fail_the_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            firmware = root / 'firmware'
            output = root / 'out'
            firmware.mkdir()
            output.mkdir()
            for name in ('dropbear', 'dropbearkey', 'dropbear-inetd'):
                (output / name).write_text('not an ELF\n')

            result = subprocess.run(
                [sys.executable, str(CHECKER_PATH), str(firmware), str(output)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Not an ELF32 big-endian MIPS file', result.stderr)

    def test_readelf_error_fails_the_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            readelf = Path(directory) / 'readelf'
            readelf.write_text('#!/bin/sh\nexit 42\n')
            readelf.chmod(0o755)
            with mock.patch.dict(os.environ, {'PATH': directory}):
                with self.assertRaises(subprocess.CalledProcessError):
                    CHECKER['get_binary_symbols']('unused')

    def test_only_publicly_bindable_symbols_are_exports(self):
        names = b'\0public\0local\0hidden\0protected\0weak\0undefined\0'
        data = bytearray(0x210)
        data[:6] = b'\x7fELF\x01\x02'
        struct.pack_into('>H', data, 18, 8)  # EM_MIPS
        struct.pack_into('>I', data, 28, 52)  # e_phoff
        struct.pack_into('>HH', data, 42, 32, 2)  # e_phentsize, e_phnum
        struct.pack_into('>7I', data, 52, 1, 0x100, 0x1000, 0, 0x110, 0x110, 4)  # PT_LOAD
        struct.pack_into('>7I', data, 84, 2, 0x100, 0x1000, 0, 32, 32, 4)  # PT_DYNAMIC
        for index, entry in enumerate(((5, 0x1040), (6, 0x1080), (4, 0x10f0), (0, 0))):
            struct.pack_into('>iI', data, 0x100 + index * 8, *entry)
        data[0x140:0x140 + len(names)] = names
        symbols = (
            ('public', 1, 0, 1),
            ('local', 0, 0, 1),
            ('hidden', 1, 2, 1),
            ('protected', 1, 3, 1),
            ('weak', 2, 0, 1),
            ('undefined', 1, 0, 0),
        )
        for index, (name, binding, visibility, section) in enumerate(symbols, start=1):
            struct.pack_into('>IIIBBH', data, 0x180 + index * 16,
                             names.index(name.encode()), 0, 0,
                             binding << 4, visibility, section)
        struct.pack_into('>II', data, 0x1f0, 1, len(symbols) + 1)  # SysV hash nchain

        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / 'libc.so.0'
            library.write_bytes(data)
            self.assertEqual(
                CHECKER['parse_elf_exported_symbols'](str(library)),
                {'public', 'protected', 'weak'},
            )


if __name__ == '__main__':
    unittest.main()
