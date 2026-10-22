#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Split a Rockchip BL31 ELF (e.g. rkbin rk3568_bl31_v1.46.elf) into one binary per
PT_LOAD segment, named bl31_0x<load address>.bin, as referenced by u-boot/p25t.its.

Usage:  python3 split_bl31.py rk3568_bl31_v1.46.elf OUTDIR
"""
import struct
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    elf, out = Path(sys.argv[1]).read_bytes(), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    assert elf[:4] == b"\x7fELF" and elf[4] == 2, "not a 64-bit ELF"
    e_phoff, = struct.unpack_from("<Q", elf, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", elf, 0x36)
    for i in range(e_phnum):
        p_type, _flags, p_offset, _vaddr, p_paddr, p_filesz, _memsz, _align = \
            struct.unpack_from("<IIQQQQQQ", elf, e_phoff + i * e_phentsize)
        if p_type != 1 or p_filesz == 0:          # PT_LOAD with content only
            continue
        name = out / f"bl31_0x{p_paddr:08x}.bin"
        name.write_bytes(elf[p_offset:p_offset + p_filesz])
        print(f"{name.name}: {p_filesz} bytes")


if __name__ == "__main__":
    main()
