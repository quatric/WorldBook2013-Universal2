"""Minimal reader for 32-bit (i386) Mach-O images of the 10.4/10.5 era:
segments and sections, symbols, the indirect symbol table (old-style
__IMPORT stubs and pointers) and the classic relocation tables."""
import struct

LC_SEGMENT, LC_SYMTAB, LC_DYSYMTAB, LC_ID_DYLIB, LC_LOAD_DYLIB, LC_UNIXTHREAD = 0x1, 0x2, 0xb, 0xd, 0xc, 0x5
LC_ROUTINES = 0x11
INDIRECT_SYMBOL_LOCAL, INDIRECT_SYMBOL_ABS = 0x80000000, 0x40000000
S_NON_LAZY_SYMBOL_POINTERS, S_LAZY_SYMBOL_POINTERS, S_SYMBOL_STUBS = 6, 7, 8
S_MOD_INIT_FUNC_POINTERS = 9
N_STAB, N_TYPE, N_EXT, N_SECT, N_UNDF = 0xe0, 0x0e, 0x01, 0x0e, 0x0
GENERIC_RELOC_VANILLA, GENERIC_RELOC_PAIR, GENERIC_RELOC_SECTDIFF = 0, 1, 2
GENERIC_RELOC_PB_LA_PTR, GENERIC_RELOC_LOCAL_SECTDIFF = 3, 4
R_SCATTERED = 0x80000000


class Section:
    def __init__(self, seg, name, addr, size, offset, flags, r1, r2, reloff, nreloc):
        self.seg, self.name, self.addr, self.size, self.offset = seg, name, addr, size, offset
        self.flags, self.reserved1, self.reserved2 = flags, r1, r2
        self.reloff, self.nreloc = reloff, nreloc

    @property
    def type(self):
        return self.flags & 0xff


class MachO32:
    def __init__(self, path):
        d = open(path, 'rb').read()
        self.data = d
        magic, cpu, sub, self.filetype, ncmds, sizecmds, self.flags = struct.unpack_from('<7I', d, 0)
        assert magic == 0xfeedface and cpu == 7, 'not an i386 Mach-O'
        self.segments = []
        self.sections = []
        self.dylibs = []
        self.entry = None
        self.init_routine = None
        off = 28
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<2I', d, off)
            if cmd == LC_SEGMENT:
                name = d[off + 8:off + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, fl = struct.unpack_from('<8I', d, off + 24)
                self.segments.append((name, vmaddr, vmsize, fileoff, filesize, initprot))
                so = off + 56
                for k in range(nsects):
                    sn = d[so:so + 16].rstrip(b'\0').decode()
                    sg = d[so + 16:so + 32].rstrip(b'\0').decode()
                    addr, ssize, soff, align, reloff, nreloc, flags, r1, r2 = struct.unpack_from('<9I', d, so + 32)
                    self.sections.append(Section(sg, sn, addr, ssize, soff, flags, r1, r2, reloff, nreloc))
                    so += 68
            elif cmd == LC_SYMTAB:
                self.symoff, self.nsyms, self.stroff, self.strsize = struct.unpack_from('<4I', d, off + 8)
            elif cmd == LC_DYSYMTAB:
                v = struct.unpack_from('<18I', d, off + 8)
                (self.ilocalsym, self.nlocalsym, self.iextdefsym, self.nextdefsym, self.iundefsym, self.nundefsym,
                 _, _, _, _, _, _, self.indirectsymoff, self.nindirectsyms, self.extreloff, self.nextrel,
                 self.locreloff, self.nlocrel) = v
            elif cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB):
                noff = struct.unpack_from('<I', d, off + 8)[0]
                nm = d[off + noff:off + size].split(b'\0')[0].decode()
                if cmd == LC_LOAD_DYLIB:
                    self.dylibs.append(nm)
                else:
                    self.install_name = nm
            elif cmd == LC_UNIXTHREAD:
                # i386_thread_state: eax ebx ecx edx edi esi ebp esp ss eflags eip
                self.entry = struct.unpack_from('<16I', d, off + 16)[10]
            elif cmd == LC_ROUTINES:
                self.init_routine = struct.unpack_from('<I', d, off + 8)[0]
            off += size
        segs = [s for s in self.segments if s[0] != '__PAGEZERO' and s[2]]
        self.lo = min(s[1] for s in segs)
        self.hi = max(s[1] + s[2] for s in segs)
        self.mem = bytearray(self.hi - self.lo)
        for name, vmaddr, vmsize, fileoff, filesize, prot in segs:
            self.mem[vmaddr - self.lo:vmaddr - self.lo + filesize] = d[fileoff:fileoff + filesize]
        self._symbols()
        self._imports()
        self._relocs()

    # ---- helpers ---------------------------------------------------------
    def section(self, seg, name):
        for s in self.sections:
            if s.name == name and (seg is None or s.seg == seg):
                return s
        return None

    def read(self, addr, n):
        return bytes(self.mem[addr - self.lo:addr - self.lo + n])

    def u32(self, addr):
        return struct.unpack('<I', self.read(addr, 4))[0]

    def i32(self, addr):
        return struct.unpack('<i', self.read(addr, 4))[0]

    def cstr(self, addr):
        o = addr - self.lo
        e = self.mem.index(0, o)
        return bytes(self.mem[o:e]).decode('latin-1')

    def contains(self, a):
        return self.lo <= a < self.hi

    # ---- symbols -----------------------------------------------------------
    def _symbols(self):
        d = self.data
        self.syms = []
        for k in range(self.nsyms):
            strx, ntype, nsect, ndesc, value = struct.unpack_from('<IBBhI', d, self.symoff + 12 * k)
            name = d[self.stroff + strx:d.index(b'\0', self.stroff + strx)].decode('latin-1')
            self.syms.append((name, ntype, nsect, ndesc, value))
        self.exports = {}
        self.names = {}
        for name, ntype, nsect, ndesc, value in self.syms:
            if ntype & N_STAB:
                continue
            if (ntype & N_TYPE) == N_SECT:
                self.names.setdefault(value, name)
                if ntype & N_EXT:
                    self.exports[name] = value

    def _imports(self):
        d = self.data
        ind = [struct.unpack_from('<I', d, self.indirectsymoff + 4 * k)[0] for k in range(self.nindirectsyms)]
        self.stubs = {}      # stub address -> symbol
        self.slots = {}      # pointer slot address -> symbol (bound at load)
        self.local_slots = {}  # pointer slot -> None for INDIRECT_SYMBOL_LOCAL (already holds the address)
        for s in self.sections:
            t = s.type
            if t == S_SYMBOL_STUBS:
                n = s.size // s.reserved2
                for k in range(n):
                    i = ind[s.reserved1 + k]
                    if i & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS):
                        continue
                    self.stubs[s.addr + k * s.reserved2] = self.syms[i][0]
            elif t in (S_NON_LAZY_SYMBOL_POINTERS, S_LAZY_SYMBOL_POINTERS):
                for k in range(s.size // 4):
                    i = ind[s.reserved1 + k]
                    a = s.addr + 4 * k
                    if i & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS):
                        self.local_slots[a] = None
                        continue
                    self.slots[a] = self.syms[i][0]

    def _relocs(self):
        """rebases: addresses holding an image address (slid at load);
        binds: address -> (symbol, addend) from external relocations."""
        d = self.data
        self.rebases = set()
        self.binds = {}
        base = self.segments[0][1] if self.filetype != 2 else 0
        # MH_DYLIB/MH_BUNDLE: r_address is relative to the first segment;
        # with MH_SPLIT_SEGS, to the first writable one
        if self.flags & 0x20:
            base = next(s[1] for s in self.segments if s[5] & 2)

        def entries(off, n):
            for k in range(n):
                w0, w1 = struct.unpack_from('<2I', d, off + 8 * k)
                yield w0, w1
        for w0, w1 in entries(self.locreloff, self.nlocrel):
            if w0 & R_SCATTERED:
                rtype = (w0 >> 24) & 0xf
                addr = w0 & 0xffffff
                if rtype in (GENERIC_RELOC_VANILLA, GENERIC_RELOC_PB_LA_PTR):
                    self.rebases.add(base + addr)
                continue
            addr, info = w0, w1
            length = (info >> 25) & 3
            pcrel = (info >> 24) & 1
            ext = (info >> 27) & 1
            if not pcrel and length == 2 and not ext:
                self.rebases.add(base + addr)
        for w0, w1 in entries(self.extreloff, self.nextrel):
            addr, info = w0, w1
            symnum = info & 0xffffff
            pcrel = (info >> 24) & 1
            length = (info >> 25) & 3
            if length == 2 and not pcrel:
                a = base + addr
                self.binds[a] = (self.syms[symnum][0], struct.unpack_from('<i', self.mem, a - self.lo)[0])
        # section relocations (object-file style, kept in some dylibs)
        for s in self.sections:
            for w0, w1 in entries(s.reloff, s.nreloc) if s.nreloc else ():
                if w0 & R_SCATTERED:
                    rtype = (w0 >> 24) & 0xf
                    if rtype == GENERIC_RELOC_VANILLA:
                        self.rebases.add(s.addr + (w0 & 0xffffff))
                    continue
                info = w1
                if not (info >> 24) & 1 and ((info >> 25) & 3) == 2 and not (info >> 27) & 1:
                    self.rebases.add(s.addr + w0)
