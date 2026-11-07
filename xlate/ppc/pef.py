"""Preferred Executable Format (CFM, PowerPC) containers.

A PEF container holds sections (code, pattern-initialized data, loader). The
loader section names the imported libraries and symbols, the exports, the main,
init and term transition vectors, and the relocations of the data section.

`PEF.layout(code_base, data_base, import_tvec)` lays the instantiated sections
out at fixed guest addresses and applies every relocation, so the result can be
mapped as is: imported symbol i resolves to the address import_tvec(i).
"""
import struct


def be32(b, o):
    return struct.unpack_from('>I', b, o)[0]


class Section:
    def __init__(self, i, hdr, data):
        (self.name_off, self.default_addr, self.total, self.unpacked, self.container_len,
         self.container_off, self.kind, self.share, self.align, _) = struct.unpack('>iIIIIIBBBB', hdr)
        self.index = i
        self.raw = data[self.container_off:self.container_off + self.container_len]
        self.base = 0


def pidata(src):
    """the pattern-initialized data opcodes of a data section"""
    out = bytearray()
    i = 0

    def arg():
        nonlocal i
        v = 0
        while True:
            b = src[i]
            i += 1
            v = (v << 7) | (b & 0x7f)
            if not b & 0x80:
                return v

    while i < len(src):
        b = src[i]
        i += 1
        op, n = b >> 5, b & 0x1f
        if n == 0:
            n = arg()
        if op == 0:      # zero
            out += bytes(n)
        elif op == 1:    # block copy
            out += src[i:i + n]
            i += n
        elif op == 2:    # repeated block
            r = arg() + 1
            out += src[i:i + n] * r
            i += n
        elif op == 3:    # interleaved repeat, common data first
            common = n
            custom = arg()
            r = arg()
            cd = src[i:i + common]
            i += common
            for _ in range(r):
                out += cd
                out += src[i:i + custom]
                i += custom
            out += cd
        elif op == 4:    # interleaved zero
            common = n
            custom = arg()
            r = arg()
            for _ in range(r):
                out += bytes(common)
                out += src[i:i + custom]
                i += custom
            out += bytes(common)
        else:
            raise ValueError('pidata opcode %d' % op)
    return bytes(out)


class PEF:
    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:12] != b'Joy!peffpwpc':
            raise ValueError('not a PowerPC PEF container')
        nsec = struct.unpack_from('>H', d, 0x20)[0]
        self.sections = [Section(i, d[40 + 28 * i:68 + 28 * i], d) for i in range(nsec)]
        self.loader = next(s for s in self.sections if s.kind == 4)
        self.parse_loader()

    def parse_loader(self):
        ld = self.loader.raw
        (self.main_sec, self.main_off, self.init_sec, self.init_off, self.term_sec, self.term_off,
         nlib, nimp, self.nreloc_secs, self.reloc_instr_off, self.strings_off, self.hash_off,
         self.hash_power, self.nexports) = struct.unpack_from('>iIiIiIIIIIIIII', ld, 0)

        def name(o):
            e = ld.index(b'\0', self.strings_off + o)
            return ld[self.strings_off + o:e].decode('mac_roman')

        self.libs = []
        p = 56
        for _ in range(nlib):
            no, _, _, cnt, first, opts, _, _ = struct.unpack_from('>IIIIIBBH', ld, p)
            self.libs.append((name(no), cnt, first, opts))
            p += 24
        self.imports = []    # (name, class)
        for _ in range(nimp):
            w = be32(ld, p)
            self.imports.append((name(w & 0xffffff), w >> 24))
            p += 4
        self.relocs = []     # (section index, instruction count, first instruction offset)
        for _ in range(self.nreloc_secs):
            si, _, cnt, fo = struct.unpack_from('>HHII', ld, p)
            self.relocs.append((si, cnt, fo))
            p += 12
        # exports: hash table, key table, symbol table
        nhash = 1 << self.hash_power
        keys = self.hash_off + 4 * nhash
        syms = keys + 4 * self.nexports
        self.exports = []
        for i in range(self.nexports):
            namelen = be32(ld, keys + 4 * i) >> 16
            cn, off, sec = struct.unpack_from('>IIh', ld, syms + 10 * i)
            o = self.strings_off + (cn & 0xffffff)
            self.exports.append((ld[o:o + namelen].decode('mac_roman'), cn >> 24, sec, off))

    def instantiate(self, s):
        if s.kind == 0 or s.kind == 1:   # code, unpacked data
            img = bytes(s.raw) + bytes(max(0, s.total - len(s.raw)))
        elif s.kind == 2:                # pattern-initialized data
            img = pidata(s.raw)
            img += bytes(max(0, s.total - len(img)))
        elif s.kind == 3:                # constant
            img = bytes(s.raw) + bytes(max(0, s.total - len(s.raw)))
        else:
            return None
        return bytearray(img)

    def layout(self, bases, import_addr):
        """bases: section index -> guest address. Returns {section index: bytearray}
        with relocations applied, and the set of relocated word addresses with the
        section their value refers to: {address: ('code'|'data'|'import', value)}."""
        mem = {}
        for s in self.sections:
            if s.index in bases:
                s.base = bases[s.index]
                mem[s.index] = self.instantiate(s)
        ld = self.loader.raw
        refs = {}
        code = next(s.index for s in self.sections if s.kind == 0)
        datas = [s.index for s in self.sections if s.kind in (1, 2)]
        for si, cnt, fo in self.relocs:
            buf = mem[si]
            base = bases[si]
            ins = [struct.unpack_from('>H', ld, self.reloc_instr_off + fo + 2 * k)[0] for k in range(cnt)]
            pos = 0
            sec_c = bases.get(code, 0)
            sec_d = bases.get(datas[0], 0) if datas else 0
            imp = 0
            k = 0

            def add(v, kind):
                nonlocal pos
                w = (be32(buf, pos) + v) & 0xffffffff
                struct.pack_into('>I', buf, pos, w)
                refs[base + pos] = (kind, w)
                pos += 4

            def imp_ref(i):
                nonlocal pos
                w = (be32(buf, pos) + import_addr(i)) & 0xffffffff
                struct.pack_into('>I', buf, pos, w)
                refs[base + pos] = ('import', i)
                pos += 4

            while k < len(ins):
                w = ins[k]
                k += 1
                if w >> 14 == 0:                       # RelocBySectDWithSkip
                    skip, n = (w >> 6) & 0xff, w & 0x3f
                    pos += 4 * skip
                    for _ in range(n):
                        add(sec_d, 'data')
                elif w >> 13 == 2:                     # RelocBySectC/D, TVector12, TVector8, VTable8, ImportRun
                    sub, n = (w >> 9) & 0xf, (w & 0x1ff) + 1
                    for _ in range(n):
                        if sub == 0:
                            add(sec_c, 'code')
                        elif sub == 1:
                            add(sec_d, 'data')
                        elif sub == 2:
                            add(sec_c, 'code')
                            add(sec_d, 'data')
                            pos += 4
                        elif sub == 3:
                            add(sec_c, 'code')
                            add(sec_d, 'data')
                        elif sub == 4:
                            add(sec_d, 'data')
                            pos += 4
                        elif sub == 5:
                            imp_ref(imp)
                            imp += 1
                        else:
                            raise ValueError('reloc run %d' % sub)
                elif w >> 13 == 3:                     # RelocSmByImport, SmSetSectC, SmSetSectD, SmBySection
                    sub, idx = (w >> 9) & 0xf, w & 0x1ff
                    if sub == 0:
                        imp_ref(idx)
                        imp = idx + 1
                    elif sub == 1:
                        sec_c = bases[idx]
                    elif sub == 2:
                        sec_d = bases[idx]
                    elif sub == 3:
                        add(bases[idx], 'code' if idx == code else 'data')
                    else:
                        raise ValueError('reloc small %d' % sub)
                elif w >> 12 == 8:                     # RelocIncrPosition
                    pos += (w & 0xfff) + 1
                elif w >> 12 == 9:                     # RelocSmRepeat
                    blocks, reps = ((w >> 8) & 0xf) + 1, (w & 0xff) + 1
                    body = ins[k - 1 - blocks:k - 1]
                    ins[k:k] = body * reps
                elif w >> 10 == 0x28:                  # RelocSetPosition
                    pos = ((w & 0x3ff) << 16) | ins[k]
                    k += 1
                elif w >> 10 == 0x29:                  # RelocLgByImport
                    i = ((w & 0x3ff) << 16) | ins[k]
                    k += 1
                    imp_ref(i)
                    imp = i + 1
                elif w >> 10 == 0x2c:                  # RelocLgRepeat
                    blocks, reps = ((w >> 6) & 0xf) + 1, ((w & 0x3f) << 16) | ins[k]
                    k += 1
                    body = ins[k - 2 - blocks:k - 2]
                    ins[k:k] = body * reps
                elif w >> 10 == 0x2d:                  # RelocLgSetOrBySection
                    sub, idx = (w >> 6) & 0xf, ((w & 0x3f) << 16) | ins[k]
                    k += 1
                    if sub == 0:
                        add(bases[idx], 'code' if idx == code else 'data')
                    elif sub == 1:
                        sec_c = bases[idx]
                    elif sub == 2:
                        sec_d = bases[idx]
                    else:
                        raise ValueError('reloc lg set %d' % sub)
                else:
                    raise ValueError('reloc opcode %04x' % w)
        return mem, refs


if __name__ == '__main__':
    import sys
    p = PEF(sys.argv[1])
    for s in p.sections:
        print('section %d kind %d total %x unpacked %x container %x @%x align %d' % (
            s.index, s.kind, s.total, s.unpacked, s.container_len, s.container_off, s.align))
    print('main %d:%x init %d:%x term %d:%x' % (p.main_sec, p.main_off, p.init_sec, p.init_off, p.term_sec, p.term_off))
    print('libs', [(n, c, f, o) for n, c, f, o in p.libs])
    print('exports', p.exports[:20])
    mem, refs = p.layout({0: 0x01000000, 1: 0x02000000}, lambda i: 0x00100000 + 8 * i)
    kinds = {}
    for a, (k, v) in refs.items():
        kinds[k] = kinds.get(k, 0) + 1
    print('relocs', kinds)
