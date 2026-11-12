"""Disassembles the functions and methods of a 32-bit Objective-C 1 image with the selector and
class names of the references they load (otool shows only the addresses).
usage: python3 tools/objcdis.py <i386 image> <name substring>..."""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'xlate'))
from macho32 import MachO32  # noqa: E402

img = sys.argv[1]
m = MachO32(img)
names = {}
for seg, sect in (('__OBJC', '__message_refs'), ('__OBJC', '__cls_refs')):
    s = m.section(seg, sect)
    if s:
        for a in range(s.addr, s.addr + s.size, 4):
            try:
                names[a] = m.cstr(m.u32(a))
            except ValueError:
                pass
cstr = m.section('__TEXT', '__cstring')
cfs = m.section('__DATA', '__cfstring')
out = subprocess.run(['otool', '-tV', img], capture_output=True, text=True).stdout
cur = None
for line in out.splitlines():
    if line.endswith(':') and not line.startswith('\t') and not re.match(r'^[0-9a-f]{8}\t', line):
        cur = line[:-1]
        if any(p in cur for p in sys.argv[2:]):
            print(line)
        continue
    if not cur or not any(p in cur for p in sys.argv[2:]):
        continue

    def ann(mo):
        a = int(mo.group(1), 16)
        if a in names:
            return mo.group(0) + ' <' + names[a] + '>'
        if cfs and cfs.addr <= a < cfs.addr + cfs.size:
            try:
                return mo.group(0) + ' @"' + m.cstr(m.u32(a + 8)) + '"'
            except ValueError:
                pass
        if cstr and cstr.addr <= a < cstr.addr + cstr.size:
            return mo.group(0) + ' "' + m.cstr(a) + '"'
        return mo.group(0)
    print(re.sub(r'\$?0x([0-9a-f]{5,8})\b', ann, line))
