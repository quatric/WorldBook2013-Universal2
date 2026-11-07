#!/usr/bin/env python3
"""Info.plist and icon of a translated CFM application bundle, from the
original's resources ('vers' 1, the 'icns' of the application's BNDL/FREF).

usage: mkinfo.py <original file> <executable name> <display name> <bundle>
"""
import os
import plistlib
import struct
import sys


def resources(path):
    d = open(path + '/..namedfork/rsrc', 'rb').read()
    do, mo, dl, ml = struct.unpack('>IIII', d[:16])
    m = d[mo:mo + ml]
    tl, nl = struct.unpack('>HH', m[24:28])
    n = struct.unpack('>H', m[tl:tl + 2])[0] + 1
    out = {}
    for i in range(n):
        t, cnt, off = struct.unpack('>4sHH', m[tl + 2 + 8 * i:tl + 10 + 8 * i])
        for k in range(cnt + 1):
            rid, no, attr_off, _ = struct.unpack('>hHII', m[tl + off + 12 * k:tl + off + 12 * k + 12])
            o = attr_off & 0xffffff
            ln = struct.unpack('>I', d[do + o:do + o + 4])[0]
            out[(t, rid)] = d[do + o + 4:do + o + 4 + ln]
    return out


def main():
    src, exe, name, app = sys.argv[1:5]
    r = resources(src)
    version = '1.0'
    v = r.get((b'vers', 1))
    if v:
        sl = v[6]
        version = v[7:7 + sl].decode('mac_roman')
    creator = 'WBwz'
    for (t, rid), data in r.items():
        if t == b'BNDL':
            creator = data[:4].decode('mac_roman')
    icns = [(rid, d) for (t, rid), d in r.items() if t == b'icns']
    info = {
        'CFBundleExecutable': exe,
        'CFBundleName': name,
        'CFBundleDisplayName': name,
        'CFBundleIdentifier': 'com.worldbook.' + exe.lower(),
        'CFBundlePackageType': 'APPL',
        'CFBundleSignature': creator,
        'CFBundleShortVersionString': version.split(' ')[0],
        'CFBundleVersion': version.split(' ')[0],
        'CFBundleGetInfoString': version,
        'LSMinimumSystemVersion': '11.0',
        'NSHighResolutionCapable': True,
        'NSRequiresAquaSystemAppearance': True,
        'NSPrincipalClass': 'NSApplication',
    }
    if icns:
        icns.sort()
        open(os.path.join(app, 'Contents/Resources/AppIcon.icns'), 'wb').write(icns[0][1])
        info['CFBundleIconFile'] = 'AppIcon'
    with open(os.path.join(app, 'Contents/Info.plist'), 'wb') as f:
        plistlib.dump(info, f)
    open(os.path.join(app, 'Contents/PkgInfo'), 'w').write('APPL' + creator)


if __name__ == '__main__':
    main()
