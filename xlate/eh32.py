"""Exception tables of an i386 image.

lsda_map(m): function start -> LSDA address, from the __unwind_info LSDA
index and from __eh_frame FDEs that carry an LSDA pointer.

parse_lsda(m, func, lsda): the call sites of a function, each
(start, end, landing pad, clauses, cleanup) where a clause is
(filter, addr, kind):
    kind 0: addr is the typeinfo itself (unslid address)
    kind 1: addr is a pointer-sized slot holding the typeinfo (read after load)
    filter > 0 with addr 0 is catch (...); filter < 0 is an exception spec.
"""
import struct


def uleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            return r, p


def sleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s; s += 7
        if not x & 0x80:
            if x & 0x40:
                r -= 1 << s
            return r, p


def read_enc(m, enc, addr):
    """a DW_EH_PE encoded value at addr -> (value, size); the indirect bit is left to the caller"""
    fmt = enc & 0x0f
    b = m.read(addr, 8)
    if fmt in (0x00, 0x03):          # absptr (4 bytes on i386), udata4
        v, n = struct.unpack_from('<I', b)[0], 4
    elif fmt == 0x0b:                # sdata4
        v, n = struct.unpack_from('<i', b)[0], 4
    elif fmt == 0x02:
        v, n = struct.unpack_from('<H', b)[0], 2
    elif fmt == 0x0a:
        v, n = struct.unpack_from('<h', b)[0], 2
    elif fmt == 0x01:
        v, p = uleb(b, 0); n = p
    elif fmt == 0x09:
        v, p = sleb(b, 0); n = p
    else:
        raise ValueError('pointer encoding %x' % enc)
    app = enc & 0x70
    if app == 0x10:                  # pcrel (a zero stays zero: catch (...))
        if v:
            v += addr
    elif app != 0x00:
        raise ValueError('pointer application %x' % enc)
    return v & 0xffffffff, n


def enc_size(enc):
    return {0x00: 4, 0x03: 4, 0x0b: 4, 0x02: 2, 0x0a: 2}.get(enc & 0x0f, 4)


def text_base(m):
    for s in m.segments:
        if s[0] == '__TEXT':
            return s[1]
    return 0


def unwind_lsdas(m):
    s = m.section('__TEXT', '__unwind_info')
    if s is None or s.size < 28:
        return {}
    b = m.read(s.addr, s.size)
    ver, cso, csc, po, pc, io, ic = struct.unpack_from('<7I', b, 0)
    if ver != 1:
        return {}
    tb = text_base(m)
    out = {}
    for k in range(ic):
        fo, slo, lo = struct.unpack_from('<3I', b, io + 12 * k)
        lo_next = struct.unpack_from('<3I', b, io + 12 * (k + 1))[2] if k + 1 < ic else lo
        for e in range(lo, lo_next, 8):
            f, l = struct.unpack_from('<2I', b, e)
            out[tb + f] = tb + l
    return out


def eh_frame_lsdas(m):
    s = m.section('__TEXT', '__eh_frame')
    if s is None:
        return {}
    out = {}
    cies = {}
    p, end = s.addr, s.addr + s.size
    while p < end:
        ln = m.u32(p)
        if ln == 0:
            break
        if ln == 0xffffffff:
            break    # 64-bit lengths are not used here
        body = p + 4
        nxt = body + ln
        cid = m.u32(body)
        if cid == 0:
            # CIE: version, augmentation string, code/data align, return reg, augmentation data
            b = m.read(body + 4, min(ln, 256))
            q = 1
            aug = b''
            while b[q]:
                aug += bytes([b[q]]); q += 1
            q += 1
            _, q = uleb(b, q); _, q = sleb(b, q)
            q += 1   # return address register (version 1: a byte)
            info = {'fde': 0x00, 'lsda': None}
            if aug.startswith(b'z'):
                _, q = uleb(b, q)
                for ch in aug[1:]:
                    if ch == ord('R'):
                        info['fde'] = b[q]; q += 1
                    elif ch == ord('L'):
                        info['lsda'] = b[q]; q += 1
                    elif ch == ord('P'):
                        penc = b[q]; q += 1
                        _, n = read_enc(m, penc & 0x7f, body + 4 + q)
                        q += n
                    elif ch == ord('S'):
                        pass
            cies[p] = info
        else:
            cie = cies.get(body - cid)
            if cie is not None:
                a = body + 4
                start, n = read_enc(m, cie['fde'], a); a += n
                _, n = read_enc(m, cie['fde'] & 0x0f, a); a += n
                if cie['lsda'] is not None and cie['lsda'] != 0xff:
                    _, a2 = uleb(m.read(a, 8), 0)
                    a += a2
                    l, _ = read_enc(m, cie['lsda'], a)
                    if l:
                        out[start] = l
        p = nxt
    return out


def lsda_map(m):
    out = {}
    try:
        out.update(eh_frame_lsdas(m))
    except Exception as ex:
        print('eh_frame: %s' % ex)
    try:
        out.update(unwind_lsdas(m))
    except Exception as ex:
        print('unwind_info: %s' % ex)
    return out


def parse_lsda(m, func, lsda):
    b = m.read(lsda, 8192)
    p = 0
    lpenc = b[p]; p += 1
    lpstart = func
    if lpenc != 0xff:
        lpstart, n = read_enc(m, lpenc, lsda + p); p += n
    ttenc = b[p]; p += 1
    ttbase = None
    if ttenc != 0xff:
        off, p = uleb(b, p)
        ttbase = lsda + p + off
    csenc = b[p]; p += 1
    cslen, p = uleb(b, p)
    cs_end = p + cslen
    actions = cs_end
    sites = []
    while p < cs_end:
        if csenc == 0x01:
            start, p = uleb(b, p); length, p = uleb(b, p); lp, p = uleb(b, p)
        else:
            start, length, lp = struct.unpack_from('<3I', b, p); p += 12
        act, p = uleb(b, p)
        if not lp:
            continue
        clauses = []
        cleanup = act == 0
        a = act
        while a:
            q = actions + a - 1
            filt, q2 = sleb(b, q)
            nxt, _ = sleb(b, q2)
            if filt == 0:
                cleanup = True
            elif filt > 0 and ttbase is not None:
                ta = ttbase - filt * enc_size(ttenc)
                v, _ = read_enc(m, ttenc & 0x7f, ta)
                if ttenc & 0x80:
                    clauses.append((filt, v, 1))          # v is a slot holding the typeinfo
                elif (ttenc & 0x70) == 0:
                    clauses.append((filt, ta if v else 0, 1))   # absolute: the entry is relocated in place
                else:
                    clauses.append((filt, v, 0))
            elif filt < 0:
                clauses.append((filt, 0, 2))              # exception specification: never selected here
            if nxt == 0:
                break
            a = (q2 - actions + 1) + nxt
        sites.append((lpstart + start, lpstart + start + length, lpstart + lp, clauses, cleanup))
    return sites
