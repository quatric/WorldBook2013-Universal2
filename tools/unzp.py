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
        # compressed: a zlib stream, then a 9-byte trailer (length, checksum).
        # Stored: the bytes, then the trailer. A stored file can itself be a
        # zlib stream (maps_tree.zplst, World Book's "zdat" format: zlib data,
        # length, 'zdat'), which inflates too but leaves more than the trailer
        z = zlib.decompressobj()
        try:
            out = z.decompress(raw)
        except zlib.error:
            out = None
        data += out if out is not None and z.eof and len(z.unused_data) == 9 else raw[:-9]
    return data


n = 0
for task in p['YAAllTasksRepresentationsKey']:
    if task.get('PluginClassName') != 'YAPackTask':
        continue
    key = task['PluginClassProperties']['YAPluginClassUniquieKey']
    dest = task.get('kInstallSubpathKey') or os.path.basename(task['kSourceLocationKey'])
    while dest.startswith('../'):   # relative to the installer's target folder's parent
        dest = dest[3:]
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
            target = e.get('SymLinkData') or (read_fork(forks['']).decode() if '' in forks else attrs.get('NSFileSymLinkDestination', ''))
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
