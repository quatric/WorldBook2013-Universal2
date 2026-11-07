#!/usr/bin/env python3
"""Extracts a MacKiev installer (InstallerMaker "YA" format): Archive.zplist
(a zlib-compressed NSArchiver typedstream, converted to an XML plist by
tools/unarch first) lists pack tasks, each installing a tree whose files are
zlib streams at given offsets in Archive.zp.
usage: unzp.py <index.plist> <Archive.zp> <out dir>"""
import os, plistlib, sys, zlib

index, archive, out = sys.argv[1:4]
p = plistlib.load(open(index, 'rb'))
files = p['YAAllObjectsPropertiesKey']
A = open(archive, 'rb')


def read_fork(fork):
    data = b''
    for seg in fork['Segments']:
        A.seek(seg['OffsLO'] + (seg.get('OffsHI', 0) << 32))
        raw = A.read(seg['Length'])
        try:
            data += zlib.decompress(raw)
        except zlib.error:
            # stored: the bytes, then a 9-byte trailer (length, checksum)
            data += raw[:-9]
    return data


n = 0
for task in p['YAAllTasksRepresentationsKey']:
    if task.get('PluginClassName') != 'YAPackTask':
        continue
    key = task['PluginClassProperties']['YAPluginClassUniquieKey']
    dest = task.get('kInstallSubpathKey') or os.path.basename(task['kSourceLocationKey'])
    root = os.path.normpath(os.path.join(out, dest))
    assert root.startswith(os.path.normpath(out))
    for e in files[key]['FilesList']:
        path = os.path.normpath(os.path.join(root, e['EntryPath']))
        assert path.startswith(root)
        attrs = e['Attributes']
        kind = attrs.get('NSFileType')
        if kind == 'NSFileTypeDirectory':
            os.makedirs(path, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        forks = {f.get('ForkName', ''): f for f in e.get('Forks', [])}
        if kind == 'NSFileTypeSymbolicLink':
            target = read_fork(forks['']).decode() if '' in forks else attrs.get('NSFileSymLinkDestination', '')
            if os.path.lexists(path):
                os.remove(path)
            os.symlink(target, path)
            continue
        with open(path, 'wb') as f:
            if '' in forks:
                f.write(read_fork(forks['']))
        for name, fork in forks.items():
            if name:   # resource fork
                with open(path + '/..namedfork/rsrc', 'wb') as f:
                    f.write(read_fork(fork))
        os.chmod(path, attrs.get('NSFilePosixPermissions', 0o644) & 0o777)
        n += 1
    print(dest)
print(n, 'files')
