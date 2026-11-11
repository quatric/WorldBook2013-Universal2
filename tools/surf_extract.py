#!/usr/bin/env python3
"""Extracts Surf The Ages (Surf.book in 2013 World Book's Resources) into a
folder of plain HTML that opens in a web browser.

Surf.book/Contents/Resources:
  Archive/ArticlePath.idx   every path: u32 length, path, u32 offset into DataIndex.idx
  DataIndex.idx             per path a record, big-endian:
                              1: u16 1, u16, u32 offset, u32 size, u32 zipped size  (zlib in the archive)
                              2: u16 2, u16, u32 offset, u32 size                   (stored in the archive)
                              3: u16 3, u16, u32 length, name                       (a file in the bundle:
                                                                                     Pictures/, Sounds/, Movies/)
  Archive/ArticleArchive.zip the zlib streams and stored files, back to back

The app serves these as stm://SurfTheAges/<path>; links between pages are
relative, apart from a few to stm:// itself, which become relative here.
usage: surf_extract.py <Surf.book> <out dir>"""
import os, re, shutil, struct, sys, zlib

book, out = sys.argv[1:3]
res = os.path.join(book, 'Contents', 'Resources')
paths = open(os.path.join(res, 'Archive', 'ArticlePath.idx'), 'rb').read()
index = open(os.path.join(res, 'DataIndex.idx'), 'rb').read()
archive = open(os.path.join(res, 'Archive', 'ArticleArchive.zip'), 'rb').read()

entries = []
i = 0
while i < len(paths):
    n, = struct.unpack('>I', paths[i:i + 4])
    name = paths[i + 4:i + 4 + n].decode('latin-1')
    rec, = struct.unpack('>I', paths[i + 4 + n:i + 8 + n])
    entries.append((name, rec))
    i += 8 + n

STM = re.compile(rb'stm://SurfTheAges/', re.I)
# a World Book article (stm://WB/<id>): only the app can show it, so its
# link becomes plain text
WB_LINK = re.compile(rb'<a\s+href\s*=\s*["\']?stm://WB/[^"\'\s>]*["\']?\s*>(.*?)</a>', re.I | re.S)
# the archive's names are all lower case, the pages' links to them are not
# (the app's protocol ignored case): relative file names in quotes or in
# unquoted attributes are lowered
EXT = rb'(?:html?|gif|jpe?g|png|wav|aiff?|au|mid|mov|swf|css|js|psd)'
QUOTED = re.compile(rb'(["\'])([^"\'<>:\s]+\.' + EXT + rb')(?=[#?"\'])', re.I)
BARE = re.compile(rb'(=)([^"\'<>:\s=]+\.' + EXT + rb')(?=[\s>#?])', re.I)


def fix_page(data, name):
    # stm://SurfTheAges/x from a page at a/b/c.htm -> ../../x
    up = b'../' * name.count('/')
    data = STM.sub(lambda m: up, data)
    data = WB_LINK.sub(lambda m: m.group(1), data)
    lower = lambda m: m.group(1) + m.group(2).lower()
    return BARE.sub(lower, QUOTED.sub(lower, data))


counts = {}
out = os.path.abspath(out)
for name, rec in entries:
    kind, = struct.unpack('>H', index[rec:rec + 2])
    if kind == 1:
        off, size, zsize = struct.unpack('>III', index[rec + 4:rec + 16])
        data = zlib.decompress(archive[off:off + zsize])
        assert len(data) == size, name
    elif kind == 2:
        off, size = struct.unpack('>II', index[rec + 4:rec + 12])
        data = archive[off:off + size]
    elif kind == 3:
        n, = struct.unpack('>I', index[rec + 4:rec + 8])
        src = os.path.join(res, index[rec + 8:rec + 8 + n].decode('latin-1'))
        if not os.path.exists(src):
            # three leftover .tmp entries point into a Tools/ folder that never shipped
            print('skipped', name, '(not in the bundle)')
            counts['missing'] = counts.get('missing', 0) + 1
            continue
        data = open(src, 'rb').read()
    else:
        raise SystemExit('%s: record type %d' % (name, kind))
    if name.lower().endswith(('.htm', '.html')):
        data = fix_page(data, name)
    path = os.path.normpath(os.path.join(out, name))
    assert path.startswith(out + os.sep)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    counts[kind] = counts.get(kind, 0) + 1
print(len(entries), 'files', counts)
