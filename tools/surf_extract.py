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
import os, re, shutil, struct, subprocess, sys, zlib

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


def image_size(data):
    """width, height of a GIF, JPEG or PNG, or None"""
    if data[:6] in (b'GIF87a', b'GIF89a'):
        return struct.unpack('<HH', data[6:10])
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return struct.unpack('>II', data[16:24])
    if data[:2] == b'\xff\xd8':
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xff:
                i += 1
                continue
            marker, n = data[i + 1], struct.unpack('>H', data[i + 2:i + 4])[0]
            if 0xc0 <= marker <= 0xcf and marker not in (0xc4, 0xc8, 0xcc):
                h, w = struct.unpack('>HH', data[i + 5:i + 9])
                return w, h
            i += 2 + n
    return None


def strip_colors(data):
    """mean colours of a picture's left edge (its first 2.5%) and of its right
    half, as (r, g, b) each; sips (macOS) scales it down to a BMP to read"""
    tmp = os.path.join(out, '.strip')
    with open(tmp, 'wb') as f:
        f.write(data)
    subprocess.run(['sips', '-s', 'format', 'bmp', '-z', '8', '200', tmp, '--out', tmp + '.bmp'],
                   capture_output=True, check=True)
    bmp = open(tmp + '.bmp', 'rb').read()
    os.remove(tmp)
    os.remove(tmp + '.bmp')
    start, = struct.unpack('<I', bmp[10:14])
    w, h, _, bpp = struct.unpack('<iiHH', bmp[18:30])
    step, row = bpp // 8, (w * bpp // 8 + 3) & ~3
    def mean(x0, x1):
        px = [bmp[start + y * row + x * step:start + y * row + x * step + 3]
              for y in range(abs(h)) for x in range(x0, x1)]
        return tuple(sum(c[i] for c in px) // len(px) for i in (2, 1, 0))   # BGR
    return mean(0, max(1, w // 40)), mean(w // 2, w)


# a page's background picture tiles in a browser; the app showed the pages
# in a window about 1068 x 731, so a picture drawn for that window never
# repeated across it. A wide, tall one (a scene behind the page) is shown
# once; a wide, short one with a border down its left edge repeats only
# downwards, the rest of the page in the colour of its right side; a plain
# texture, of any size, still tiles.
BODY_BG = re.compile(rb'<body\b[^>]*?\bbackground\s*=\s*["\']?([^"\'\s>]+)', re.I)


def body_style(data, name, files):
    m = BODY_BG.search(data)
    if not m:
        return data
    src = os.path.normpath(os.path.join(os.path.dirname(name), m.group(1).decode('latin-1'))).lower()
    size = image_size(files.get(src, b''))
    if not size or size[0] < 800:
        return data
    if size[1] >= 500:
        style = b'background-repeat:no-repeat;background-attachment:fixed'
    else:
        if src not in strips:
            strips[src] = strip_colors(files[src])
        left, right = strips[src]
        if sum(abs(a - b) for a, b in zip(left, right)) < 60:
            return data
        style = b'background-repeat:repeat-y;background-color:#%02x%02x%02x' % right
    return data[:m.start()] + b'<body style="' + style + b'"' + data[m.start() + 5:]


strips = {}


def fix_page(data, name):
    # stm://SurfTheAges/x from a page at a/b/c.htm -> ../../x
    up = b'../' * name.count('/')
    data = STM.sub(lambda m: up, data)
    data = WB_LINK.sub(lambda m: m.group(1), data)
    lower = lambda m: m.group(1) + m.group(2).lower()
    return BARE.sub(lower, QUOTED.sub(lower, data))


counts = {}
files = {}    # by lower-case path, as the archive names them
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
    files[os.path.normpath(name).lower()] = data
    counts[kind] = counts.get(kind, 0) + 1
for name, data in files.items():
    if name.endswith(('.htm', '.html')):
        data = body_style(data, name, files)
    path = os.path.normpath(os.path.join(out, name))
    assert path.startswith(out + os.sep)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
print(len(entries), 'files', counts)
