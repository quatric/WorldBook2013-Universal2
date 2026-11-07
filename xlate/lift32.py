#!/usr/bin/env python3
"""Static binary translator: i386 Mach-O image -> C running in a 32-bit
guest window (see docs/design.md).

usage: lift32.py <image path> <image id> <out dir> [other images...]

Every function (symbols, plus call and tail-jump targets) becomes a C
function `void F_<id>_<addr>(XLCPU *c)` on an emulated register file (the
general registers in C locals, XMM and x87 state in the CPU struct). Memory
is the guest window: guest address p is host address XG + p. Image addresses
are the original ones plus the image's guest slide `S`. Calls to imported
functions and the Objective-C messengers go through the runtime's bridges.

Also written: the image as laid out in memory (image.bin), its rebases,
binds, exports and section ranges (image.c) for the runtime's loader.
"""
import os
import re
import struct
import sys

import capstone
from capstone import x86

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import macho32  # noqa: E402
import eh32  # noqa: E402

LSDA = {}   # function start -> LSDA address

GPR = {}
for i, n in enumerate(['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi']):
    GPR[n] = (i, 32)
    GPR[n[1:]] = (i, 16)
for i, (lo, hi) in enumerate([('al', 'ah'), ('cl', 'ch'), ('dl', 'dh'), ('bl', 'bh')]):
    GPR[lo] = (i, 8)
    GPR[hi] = (i, 'h')
REGNAMES = ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi']

UT = {8: 'uint8_t', 16: 'uint16_t', 32: 'uint32_t', 64: 'uint64_t'}
ST = {8: 'int8_t', 16: 'int16_t', 32: 'int32_t', 64: 'int64_t'}
MASK = {8: '0xffu', 16: '0xffffu', 32: '0xffffffffu'}

CONDS = {'o': 'COND_O', 'no': '!COND_O', 'b': 'COND_B', 'ae': '!COND_B', 'e': 'COND_E', 'ne': '!COND_E',
         'be': 'COND_BE', 'a': '!COND_BE', 's': 'COND_S', 'ns': '!COND_S', 'p': 'COND_P', 'np': '!COND_P',
         'l': 'COND_L', 'ge': '!COND_L', 'le': 'COND_LE', 'g': '!COND_LE'}
CONDS.update({'c': CONDS['b'], 'nc': CONDS['ae'], 'z': CONDS['e'], 'nz': CONDS['ne'], 'nae': CONDS['b'],
              'nb': CONDS['ae'], 'na': CONDS['be'], 'nbe': CONDS['a'], 'nge': CONDS['l'], 'nl': CONDS['ge'],
              'ng': CONDS['le'], 'nle': CONDS['g'], 'pe': CONDS['p'], 'po': CONDS['np']})

MSGSEND = {'_objc_msgSend': 'XL_MSG_NORMAL', '_objc_msgSend_stret': 'XL_MSG_STRET',
           '_objc_msgSend_fpret': 'XL_MSG_FPRET', '_objc_msgSendSuper': 'XL_MSG_SUPER',
           '_objc_msgSendSuper_stret': 'XL_MSG_SUPER_STRET'}
# imports with their own handling in the runtime (guest-level semantics)
SETJMP = {'_setjmp', '__setjmp', '_sigsetjmp'}
NORETURN = {'__ZSt9terminatev', '___cxa_throw', '___cxa_rethrow', '__Unwind_Resume', '__Unwind_Resume_or_Rethrow',
            '___cxa_call_unexpected', '_abort', '_exit', '__exit', '___stack_chk_fail', '_objc_exception_throw',
            '__ZSt17__throw_bad_allocv', '__ZSt20__throw_length_errorPKc', '__ZSt20__throw_out_of_rangePKc',
            '__ZSt19__throw_logic_errorPKc', '___assert_rtn', '_longjmp', '_siglongjmp', '__longjmp'}


class Unsupported(Exception):
    pass


class Image:
    def __init__(self, path, ident):
        self.ident = ident
        m = macho32.MachO32(path)
        self.m = m
        self.lo, self.hi, self.mem = m.lo, m.hi, m.mem
        t = m.section('__TEXT', '__text')
        self.text = (t.addr, t.addr + t.size)
        self.stubs = m.stubs
        self.slots = m.slots
        self.names = m.names
        self.rebases = m.rebases
        self.starts = {a for a, n in m.names.items() if self.in_text(a)}
        # code locations whose 4 bytes are slid at load (text relocations)
        self.text_rebases = {r for r in m.rebases if self.in_text(r)}

    def read(self, a, n):
        return self.m.read(a, n)

    def u32(self, a):
        return self.m.u32(a)

    def i32(self, a):
        return self.m.i32(a)

    def in_text(self, a):
        return self.text[0] <= a < self.text[1]

    def in_image(self, a):
        return self.lo <= a < self.hi


def is_pc_thunk(img, a):
    """`mov reg, [esp]; ret` (__i686.get_pc_thunk.*): returns the register"""
    b = img.read(a, 4)
    regs = {b'\x8b\x04\x24\xc3': 0, b'\x8b\x0c\x24\xc3': 1, b'\x8b\x14\x24\xc3': 2, b'\x8b\x1c\x24\xc3': 3,
            b'\x8b\x2c\x24\xc3': 5, b'\x8b\x34\x24\xc3': 6, b'\x8b\x3c\x24\xc3': 7}
    return regs.get(b)


class Func:
    def __init__(self, img, start, cs):
        self.img, self.start, self.cs = img, start, cs
        self.insns = {}
        self.leaders = {start}
        self.tables = {}          # jmp insn address -> list of targets
        self.ext_targets = set()
        self.picbase = {}         # call insn address -> (reg, value): a PIC base set up there
        self.sites = []           # C++ call sites: (start, end, landing pad, clauses, cleanup)
        if start in LSDA:
            try:
                self.sites = eh32.parse_lsda(img.m, start, LSDA[start])
            except Exception as ex:
                print('bad LSDA for %x: %s' % (start, ex))
        self.decode()

    def next_start(self):
        img = self.img
        return min((s for s in img.starts if s > self.start), default=img.text[1])

    def owns(self, tgt):
        img = self.img
        if tgt == self.start:
            return True
        if not img.in_text(tgt) or tgt in img.starts:
            return False
        return self.start < tgt < self.next_start()

    def decode(self):
        img = self.img
        work = [self.start]
        for st in self.sites:
            if self.owns(st[2]):
                self.leaders.add(st[2])
                work.append(st[2])
        pic = {}   # register -> known PIC base value (along the current path)
        spill = {}  # ebp displacement -> PIC base value stored there
        while work:
            a = work.pop()
            while a not in self.insns:
                if not img.in_text(a):
                    self.insns[a] = 'END'
                    break
                if a != self.start and a in img.starts:
                    self.insns[a] = None   # falls into the next function
                    break
                try:
                    i = next(self.cs.disasm(img.read(a, 16), a, 1))
                except StopIteration:
                    self.insns[a] = 'END'
                    break
                self.insns[a] = i
                m = i.mnemonic
                nxt = a + i.size
                if m == 'mov' and len(i.operands) == 2:
                    d, src = i.operands
                    if d.type == x86.X86_OP_MEM and src.type == x86.X86_OP_REG and d.mem.base == x86.X86_REG_EBP \
                            and not d.mem.index:
                        rn = self.cs.reg_name(src.reg)
                        if rn in pic:
                            spill[d.mem.disp] = pic[rn]
                        else:
                            spill.pop(d.mem.disp, None)
                    elif d.type == x86.X86_OP_REG and src.type == x86.X86_OP_MEM and src.mem.base == x86.X86_REG_EBP \
                            and not src.mem.index and src.mem.disp in spill:
                        pic[self.cs.reg_name(d.reg)] = spill[src.mem.disp]
                if m.startswith('j'):
                    op = i.operands[0]
                    if op.type == x86.X86_OP_IMM:
                        tgt = op.imm
                        if self.owns(tgt):
                            self.leaders.add(tgt)
                            work.append(tgt)
                        else:
                            self.ext_targets.add(tgt)
                        if m == 'jmp':
                            break
                        self.leaders.add(nxt)
                    else:
                        if m != 'jmp':
                            raise Unsupported('indirect jcc')
                        tg = self.jump_table(i, pic)
                        if tg:
                            self.tables[a] = tg
                            for t in tg:
                                self.leaders.add(t)
                                work.append(t)
                        break
                elif m == 'call':
                    op = i.operands[0]
                    if op.type == x86.X86_OP_IMM and img.stubs.get(op.imm) in NORETURN:
                        break
                    if op.type == x86.X86_OP_MEM and not op.mem.base and not op.mem.index and \
                            img.slots.get(op.mem.disp & 0xffffffff) in NORETURN:
                        break
                    if op.type == x86.X86_OP_IMM:
                        t = op.imm
                        if t == nxt:
                            # call next; pop reg: a PIC base
                            p = next(self.cs.disasm(img.read(nxt, 4), nxt, 1), None)
                            if p is not None and p.mnemonic == 'pop':
                                pic[self.cs.reg_name(p.operands[0].reg)] = nxt
                                self.picbase[a] = nxt
                        elif img.in_text(t):
                            r = is_pc_thunk(img, t)
                            if r is not None:
                                pic[REGNAMES[r]] = nxt
                            self.ext_targets.add(t)
                elif m in ('ret', 'retf', 'ud2', 'hlt'):
                    break
                a = nxt

    def jump_table(self, i, pic):
        """Targets of an indirect jmp: `jmp [tbl + idx*4]` (absolute entries)
        or `mov r, [pic + idx*4 + d]; add r, pic; jmp r` (entries relative to
        the PIC base)."""
        img = self.img
        op = i.operands[0]
        limit = 4096
        prev = sorted(x for x in self.insns if x < i.address and self.insns[x] not in (None, 'END'))[-16:]
        for k in range(len(prev) - 1, -1, -1):
            p = self.insns[prev[k]]
            if p.mnemonic == 'cmp' and len(p.operands) == 2 and p.operands[1].type == x86.X86_OP_IMM:
                nx = self.insns.get(prev[k] + p.size)
                if nx not in (None, 'END') and nx.mnemonic in ('ja', 'jae', 'jg', 'jge'):
                    limit = (p.operands[1].imm & 0xffffffff) + (1 if nx.mnemonic in ('ja', 'jg') else 0)
                break
        base, rel = None, None
        if op.type == x86.X86_OP_MEM and op.mem.base == 0 and op.mem.scale == 4:
            base, rel = op.mem.disp & 0xffffffff, 0
        elif op.type == x86.X86_OP_REG:
            # mov r, [b + idx*4 + d] (then add r, p) or add r, [r + idx*4 + d]
            rn = self.cs.reg_name(op.reg)
            added = None   # register added to r after the load
            for x in reversed(prev):
                p = self.insns[x]
                if len(p.operands) != 2 or p.operands[0].type != x86.X86_OP_REG or \
                        self.cs.reg_name(p.operands[0].reg) != rn:
                    continue
                src = p.operands[1]
                if p.mnemonic == 'add' and src.type == x86.X86_OP_REG:
                    added = self.cs.reg_name(src.reg)
                    continue
                if p.mnemonic in ('mov', 'add') and src.type == x86.X86_OP_MEM and src.mem.scale == 4:
                    mm = src.mem
                    bn = self.cs.reg_name(mm.base) if mm.base else None
                    if p.mnemonic == 'add':
                        if bn in pic:
                            base, rel = (pic[bn] + mm.disp) & 0xffffffff, pic[bn]
                    elif bn in pic:
                        base = (pic[bn] + mm.disp) & 0xffffffff
                        rel = pic.get(added, 0) if added else 0
                    elif not bn:
                        base = mm.disp & 0xffffffff
                        rel = pic.get(added, 0) if added else 0
                break
        if base is None or not img.in_image(base):
            return []
        tg = []
        for k in range(min(limit, 4096)):
            try:
                v = img.u32(base + 4 * k)
            except struct.error:
                break
            t = (v + rel) & 0xffffffff
            if not self.owns(t) or t == self.start:
                break
            tg.append(t)
        self.table_rel = getattr(self, 'table_rel', {})
        self.table_rel[i.address] = rel
        return sorted(set(tg))


class Emitter:
    def __init__(self, img, func, imports):
        self.img, self.f, self.imports = img, func, imports
        self.cs = func.cs
        self.ehs = []

    def name(self, addr):
        return 'F_%s_%x' % (self.img.ident, addr)

    # ---- operands -------------------------------------------------------
    def reg(self, r):
        n = self.cs.reg_name(r)
        if n not in GPR:
            raise Unsupported('register %s' % n)
        return GPR[n]

    def disp(self, i, val, off):
        """an address-sized constant in the instruction: slid when a text
        relocation covers it, or when it is an absolute image address"""
        v = val & 0xffffffff
        if off is not None and (i.address + off) in self.img.text_rebases:
            return 'A(0x%x)' % v
        return '0x%xu' % v

    def addr(self, i, op):
        m = op.mem
        if m.segment != 0:
            raise Unsupported('segment override %s' % self.cs.reg_name(m.segment))
        parts = []
        if m.base:
            parts.append('r%d' % self.reg(m.base)[0])
        if m.index:
            idx = 'r%d' % self.reg(m.index)[0]
            parts.append(idx if m.scale == 1 else '%s*%d' % (idx, m.scale))
        if m.disp or not parts:
            parts.append(self.disp(i, m.disp, i.disp_offset if i.disp_offset else None))
        return '(uint32_t)(%s)' % ' + '.join(parts)

    def imm(self, i, op, size):
        v = op.imm & ((1 << size) - 1)
        if size == 32 and i.imm_offset and (i.address + i.imm_offset) in self.img.text_rebases:
            return 'A(0x%x)' % v
        return '0x%xu' % v

    def rd(self, i, op, size=None):
        size = size or op.size * 8
        if op.type == x86.X86_OP_REG:
            n, s = self.reg(op.reg)
            if s == 'h':
                return '((uint8_t)(r%d >> 8))' % n
            if s == 32 and size == 32:
                return 'r%d' % n
            return '((%s)r%d)' % (UT[size], n)
        if op.type == x86.X86_OP_IMM:
            return self.imm(i, op, size)
        return 'LD%d(%s)' % (size, self.addr(i, op))

    def wr(self, i, op, val, size=None):
        size = size or op.size * 8
        if op.type == x86.X86_OP_REG:
            n, s = self.reg(op.reg)
            if s == 'h':
                return 'r%d = (r%d & ~0xff00u) | ((uint32_t)(uint8_t)(%s) << 8);' % (n, n, val)
            if s == 32:
                return 'r%d = (uint32_t)(%s);' % (n, val)
            return 'r%d = (r%d & ~%s) | (%s)(%s);' % (n, n, MASK[s], UT[s], val)
        if op.type == x86.X86_OP_MEM:
            return 'ST%d(%s, %s);' % (size, self.addr(i, op), val)
        raise Unsupported('write to immediate')

    def xr(self, op):
        n = self.cs.reg_name(op.reg)
        if not n.startswith('xmm'):
            raise Unsupported('expected xmm, got %s' % n)
        return 'c->x[%s]' % n[3:]

    def is_xmm(self, op):
        return op.type == x86.X86_OP_REG and self.cs.reg_name(op.reg).startswith('xmm')

    def is_st(self, op):
        return op.type == x86.X86_OP_REG and self.cs.reg_name(op.reg).startswith('st')

    def st(self, op):
        return int(self.cs.reg_name(op.reg)[3:-1])

    def flags(self, kind, size, a, b, r):
        return 'fop = FOP_%s%d; fa = %s; fb = %s; fr = %s;' % (kind, size, a, b, r)

    # ---- calls ----------------------------------------------------------
    def import_call(self, sym, tail):
        if sym in MSGSEND:
            c = 'xl_msgsend(c, %s)' % MSGSEND[sym]
        else:
            idx = self.imports.setdefault(sym, len(self.imports))
            c = 'xl_ccall(c, &XI[%d])' % idx
        if tail:
            # the callee returns straight to our caller
            return 'SO; %s; return;' % c
        # a call pushes the return address; the bridge pops it like a callee
        return 'r4 -= 4; ST32(r4, 0); SO; %s; SI;' % c

    def site(self, a):
        for st in self.f.sites:
            if st[0] <= a < st[1] and self.f.owns(st[2]):
                return st
        return None

    TRYABLE = re.compile(r'^(.*SO; )(?:xl_ccall\(c, (&XI\[\d+\])\)|xl_msgsend\(c, (\w+)\)|xl_call\(c, (.*)\)|(F_\w+)\(c\)); SI;$')

    def try_wrap(self, a, code):
        """a call inside a protected range: on a caught exception go to the landing pad"""
        st = self.site(a)
        if st is None:
            return code
        mt = self.TRYABLE.match(code)
        if not mt:
            return code
        pre, imp, kind, tgt, fn = mt.groups()
        n = len(self.ehs)
        nm = 'EH_%s_%x_%d' % (self.img.ident, self.f.start, n)
        cl = ', '.join('{%d, 0x%x, %d}' % c for c in st[3])
        self.ehs.append('static const XLEHClause %s_cl[] = {%s};\nstatic const XLEH %s = {%d, %d, %s_cl};'
                        % (nm, cl or '{0, 0, 2}', nm, len(st[3]), 1 if st[4] else 0, nm))
        if imp:
            call = 'xl_try_ccall(c, %s, &%s, S)' % (imp, nm)
        elif kind:
            call = 'xl_try_msgsend(c, %s, &%s, S)' % (kind, nm)
        elif tgt:
            call = 'xl_try_call(c, %s, &%s, S)' % (tgt, nm)
        else:
            call = 'xl_try_fn(c, %s, &%s, S)' % (fn, nm)
        return '%sif (%s) { SI; goto L_%x; } SI;' % (pre, call, st[2])

    def setjmp_call(self, i, sym):
        """inline host setjmp, so a guest longjmp lands back in this frame"""
        return ('r4 -= 4; ST32(r4, 0); SO; { XLJmp *j = xl_setjmp(c, %d); if (sigsetjmp(j->host, 0)) { xl_longjmp_landed(c, j); } } '
                'SI; r4 += 4;' % (1 if sym == '_sigsetjmp' else 0))

    def call_target(self, i, op, tail):
        img = self.img
        f = self.f
        if op.type == x86.X86_OP_IMM:
            t = op.imm & 0xffffffff
            if t in img.stubs:
                sym = img.stubs[t]
                if sym in SETJMP and not tail:
                    return self.setjmp_call(i, sym)
                if sym in XEXPORTS:
                    return self.indirect('xl_export_addr("%s")' % sym, tail, i)
                return self.import_call(sym, tail)
            if i.mnemonic == 'call' and t == i.address + i.size:
                return 'r4 -= 4; ST32(r4, A(0x%x));' % t        # call next; pop: PIC base
            if img.in_text(t):
                if tail:
                    return 'SO; %s(c); return;' % self.name(t)
                return 'r4 -= 4; ST32(r4, A(0x%x)); SO; %s(c); SI;' % (i.address + i.size, self.name(t))
            raise Unsupported('call to %x' % t)
        if op.type == x86.X86_OP_MEM and not op.mem.base and not op.mem.index:
            slot = op.mem.disp & 0xffffffff
            if slot in img.slots:
                sym = img.slots[slot]
                if sym not in XEXPORTS:
                    return self.import_call(sym, tail)
        return self.indirect(self.rd(i, op, 32), tail, i)

    def indirect(self, target, tail, i):
        if tail:
            return 'SO; xl_jump(c, %s); return;' % target
        return 'r4 -= 4; ST32(r4, A(0x%x)); SO; xl_call(c, %s); SI;' % (i.address + i.size, target)

    # ---- one instruction ------------------------------------------------
    def insn(self, i):
        m = i.mnemonic
        ops = i.operands
        o = ops[0] if ops else None
        e = []
        if m in ('nop', 'cld', 'pause', 'fwait', 'wait', 'lock') or m.startswith('nop') or m.startswith('prefetch'):
            return []
        if m == 'mov':
            if self.is_xmm(ops[0]) or self.is_xmm(ops[1]):
                raise Unsupported('mov xmm')
            if ops[0].type == x86.X86_OP_REG and self.cs.reg_name(ops[0].reg) in ('cs', 'ds', 'es', 'ss', 'fs', 'gs'):
                raise Unsupported('segment register')
            return [self.wr(i, ops[0], self.rd(i, ops[1], ops[0].size * 8))]
        if m == 'movzx':
            return [self.wr(i, ops[0], self.rd(i, ops[1]))]
        if m == 'movsx':
            s = ops[1].size * 8
            return [self.wr(i, ops[0], '(uint32_t)(int32_t)(%s)%s' % (ST[s], self.rd(i, ops[1])))]
        if m == 'cdq':
            return ['r2 = (uint32_t)((int32_t)r0 >> 31);']
        if m == 'cwde':
            return ['r0 = (uint32_t)(int32_t)(int16_t)r0;']
        if m == 'cbw':
            return ['r0 = (r0 & ~0xffffu) | (uint16_t)(int16_t)(int8_t)r0;']
        if m == 'lea':
            return [self.wr(i, ops[0], self.addr(i, ops[1]))]
        if m == 'push':
            if o.type == x86.X86_OP_IMM:
                return ['r4 -= 4; ST32(r4, %s);' % self.imm(i, o, 32)]
            return ['{ uint32_t v = %s; r4 -= 4; ST32(r4, v); }' % self.rd(i, o, 32)]
        if m == 'pop':
            return ['{ uint32_t v = LD32(r4); r4 += 4; %s }' % self.wr(i, o, 'v')]
        if m == 'leave':
            return ['r4 = r5; r5 = LD32(r4); r4 += 4;']
        if m == 'xchg':
            return ['{ uint32_t a = %s, b = %s; %s %s }' % (self.rd(i, ops[0]), self.rd(i, ops[1]),
                                                           self.wr(i, ops[0], 'b'), self.wr(i, ops[1], 'a'))]
        if m in ('add', 'sub', 'and', 'or', 'xor', 'cmp', 'test', 'adc', 'sbb'):
            s = o.size * 8
            if self.is_xmm(o):
                raise Unsupported('xmm alu')
            a = self.rd(i, ops[0], s)
            b = self.rd(i, ops[1], s)
            if m == 'xor' and ops[0].type == x86.X86_OP_REG and ops[1].type == x86.X86_OP_REG and ops[0].reg == ops[1].reg:
                return [self.wr(i, ops[0], '0'), self.flags('LOGIC', s, '0', '0', '0')]
            op = {'add': '+', 'sub': '-', 'and': '&', 'or': '|', 'xor': '^', 'cmp': '-', 'test': '&'}.get(m)
            if m in ('adc', 'sbb'):
                return ['{ uint64_t a = %s, b = %s, cf = COND_B; uint64_t r = (a %s b %s cf) & %s; fr = xl_flags_%s(%d, a, b, cf, r); fop = FOP_DIRECT; %s }'
                        % (a, b, '+' if m == 'adc' else '-', '+' if m == 'adc' else '-', MASK[s], m, s, self.wr(i, ops[0], 'r'))]
            kind = {'add': 'ADD', 'sub': 'SUB', 'cmp': 'SUB'}.get(m, 'LOGIC')
            e.append('{ uint64_t a = %s, b = %s, r = (a %s b) & %s; %s' % (a, b, op, MASK[s], self.flags(kind, s, 'a', 'b', 'r')))
            if m not in ('cmp', 'test'):
                e.append(self.wr(i, ops[0], 'r'))
            e.append('}')
            return [' '.join(e)]
        if m in ('inc', 'dec', 'neg', 'not'):
            s = o.size * 8
            a = self.rd(i, o, s)
            if m == 'not':
                return [self.wr(i, o, '~%s' % a)]
            if m == 'neg':
                return ['{ uint64_t b = %s, r = (0 - b) & %s; %s %s }' % (a, MASK[s], self.flags('SUB', s, '0', 'b', 'r'), self.wr(i, o, 'r'))]
            return ['{ uint64_t a = %s, r = (a %s 1) & %s; fcf = COND_B; %s %s }' % (
                a, '+' if m == 'inc' else '-', MASK[s], self.flags(m.upper(), s, 'a', '1', 'r'), self.wr(i, o, 'r'))]
        if m in ('shl', 'shr', 'sar', 'sal', 'rol', 'ror'):
            s = o.size * 8
            cnt = '1' if len(ops) == 1 else self.rd(i, ops[1], 8)
            a = self.rd(i, o, s)
            if m in ('shl', 'sal'):
                r = '(a << n)'
            elif m == 'shr':
                r = '(a >> n)'
            elif m == 'sar':
                r = '(uint64_t)(uint%d_t)((%s)(%s)a >> n)' % (s, ST[s], ST[s])
            elif m == 'rol':
                r = '((a << (n %% %d)) | (a >> ((%d - n %% %d) %% %d)))' % (s, s, s, s)
            else:
                r = '((a >> (n %% %d)) | (a << ((%d - n %% %d) %% %d)))' % (s, s, s, s)
            kind = {'shl': 'SHL', 'sal': 'SHL', 'shr': 'SHR', 'sar': 'SAR', 'rol': 'ROL', 'ror': 'ROR'}[m]
            return ['{ unsigned n = (unsigned)(%s) & 31; uint64_t a = %s; if (n) { uint64_t r = %s & %s; %s %s } }'
                    % (cnt, a, r, MASK[s], self.flags(kind, s, 'a', 'n', 'r'), self.wr(i, o, 'r'))]
        if m in ('shld', 'shrd'):
            s = o.size * 8
            cnt = self.rd(i, ops[2], 8)
            a, b = self.rd(i, ops[0], s), self.rd(i, ops[1], s)
            if m == 'shld':
                r = '((a << n) | (b >> (%d - n)))' % s
            else:
                r = '((a >> n) | (b << (%d - n)))' % s
            return ['{ unsigned n = (unsigned)(%s) & 31; uint64_t a = %s, b = %s; if (n) { uint64_t r = %s & %s; fop = FOP_LOGIC%d; fr = r; %s } }'
                    % (cnt, a, b, r, MASK[s], s, self.wr(i, o, 'r'))]
        if m in ('bt', 'btc', 'bts', 'btr'):
            s = o.size * 8
            if ops[0].type == x86.X86_OP_MEM and ops[1].type == x86.X86_OP_REG:
                raise Unsupported('bt mem,reg')
            a = self.rd(i, o, s)
            n = '(%s & %d)' % (self.rd(i, ops[1], 8 if ops[1].type == x86.X86_OP_IMM else s), s - 1)
            e = ['{ uint64_t a = %s; unsigned n = (unsigned)%s; fr = xl_flags_all(fop, fa, fb, fr, fcf) & ~1ULL; fr |= (a >> n) & 1; fop = FOP_DIRECT;' % (a, n)]
            if m != 'bt':
                v = {'btc': 'a ^ (1ULL << n)', 'bts': 'a | (1ULL << n)', 'btr': 'a & ~(1ULL << n)'}[m]
                e.append(self.wr(i, o, v))
            e.append('}')
            return [' '.join(e)]
        if m == 'bswap':
            return [self.wr(i, o, '__builtin_bswap32(%s)' % self.rd(i, o))]
        if m == 'imul':
            s = o.size * 8
            if len(ops) == 1:
                if s == 32:
                    return ['{ int64_t p = (int64_t)(int32_t)r0 * (int32_t)%s; r0 = (uint32_t)p; r2 = (uint32_t)((uint64_t)p >> 32); fr = (p != (int32_t)p) ? 0x801 : 0; fop = FOP_DIRECT; }' % self.rd(i, o)]
                raise Unsupported('imul size')
            a = self.rd(i, ops[1] if len(ops) == 3 else ops[0], s)
            b = self.rd(i, ops[2] if len(ops) == 3 else ops[1], s)
            return ['{ int64_t p = (int64_t)(%s)%s * (int64_t)(%s)%s; %s fr = (p != (int64_t)(%s)p) ? 0x801 : 0; fop = FOP_DIRECT; }'
                    % (ST[s], a, ST[s], b, self.wr(i, ops[0], '(uint32_t)p'), ST[s])]
        if m == 'mul':
            s = o.size * 8
            if s == 32:
                return ['{ uint64_t p = (uint64_t)r0 * (uint32_t)%s; r0 = (uint32_t)p; r2 = (uint32_t)(p >> 32); fr = (p >> 32) ? 0x801 : 0; fop = FOP_DIRECT; }' % self.rd(i, o)]
            if s == 16:
                return ['{ uint32_t p = (uint32_t)(uint16_t)r0 * (uint16_t)%s; r0 = (r0 & ~0xffffu) | (p & 0xffff); r2 = (r2 & ~0xffffu) | (p >> 16); fr = (p >> 16) ? 0x801 : 0; fop = FOP_DIRECT; }' % self.rd(i, o)]
            if s == 8:
                return ['{ uint32_t p = (uint32_t)(uint8_t)r0 * (uint8_t)%s; r0 = (r0 & ~0xffffu) | (p & 0xffff); fr = (p >> 8) ? 0x801 : 0; fop = FOP_DIRECT; }' % self.rd(i, o)]
            raise Unsupported('mul size')
        if m in ('div', 'idiv'):
            s = o.size * 8
            if s == 32:
                if m == 'div':
                    return ['{ uint64_t n = ((uint64_t)r2 << 32) | r0; uint32_t d = %s; r0 = (uint32_t)(n / d); r2 = (uint32_t)(n %% d); }' % self.rd(i, o)]
                return ['{ int64_t n = (int64_t)(((uint64_t)r2 << 32) | r0); int32_t d = (int32_t)%s; r0 = (uint32_t)(int32_t)(n / d); r2 = (uint32_t)(int32_t)(n %% d); }' % self.rd(i, o)]
            raise Unsupported('div size')
        if m.startswith('set'):
            return [self.wr(i, o, '(%s) ? 1 : 0' % CONDS[m[3:]])]
        if m.startswith('cmov'):
            s = o.size * 8
            return [self.wr(i, ops[0], '(%s) ? %s : %s' % (CONDS[m[4:]], self.rd(i, ops[1], s), self.rd(i, ops[0], s)))]
        if m == 'stc':
            return ['fr = xl_flags_all(fop, fa, fb, fr, fcf) | 1; fop = FOP_DIRECT;']
        if m == 'clc':
            return ['fr = xl_flags_all(fop, fa, fb, fr, fcf) & ~1ULL; fop = FOP_DIRECT;']
        if m == 'cmc':
            return ['fr = xl_flags_all(fop, fa, fb, fr, fcf) ^ 1; fop = FOP_DIRECT;']
        if m in ('rep movsd', 'rep movsb', 'rep movsw'):
            n = {'rep movsd': 4, 'rep movsb': 1, 'rep movsw': 2}[m]
            return ['memmove(G(r7), G(r6), (size_t)r1 * %d); r7 += r1 * %d; r6 += r1 * %d; r1 = 0;' % (n, n, n)]
        if m in ('movsd', 'movsb', 'movsw') and not ops:
            n = {'movsd': 4, 'movsb': 1, 'movsw': 2}[m]
            return ['ST%d(r7, LD%d(r6)); r7 += %d; r6 += %d;' % (n * 8, n * 8, n, n)]
        if m in ('rep stosd', 'rep stosb', 'rep stosw'):
            n = {'rep stosd': 4, 'rep stosb': 1, 'rep stosw': 2}[m]
            return ['for (; r1; r1--, r7 += %d) ST%d(r7, r0);' % (n, n * 8)]
        if m in ('stosd', 'stosb', 'stosw') and len(ops) <= 2:
            n = {'stosd': 4, 'stosb': 1, 'stosw': 2}[m]
            return ['ST%d(r7, r0); r7 += %d;' % (n * 8, n)]
        if m in ('lodsb', 'lodsd'):
            n = {'lodsd': 4, 'lodsb': 1}[m]
            return ['%s r6 += %d;' % (self.wr(i, ops[0], 'LD%d(r6)' % (n * 8), n * 8) if ops else 'r0 = LD32(r6);', n)]
        if m in ('ud2', 'hlt', 'int3'):
            return ['xl_trap(c, A(0x%x));' % i.address]
        if m == 'sahf':
            return ['fr = (r0 >> 8) & 0xd5; fop = FOP_DIRECT;']
        if m == 'lahf':
            return ['r0 = (r0 & ~0xff00u) | (((uint32_t)xl_flags_all(fop, fa, fb, fr, fcf) & 0xd5) | 2) << 8;']
        x = self.x87(i, m, ops)
        if x is not None:
            return x
        x = self.sse(i, m, ops)
        if x is not None:
            return x
        raise Unsupported('%s %s' % (m, i.op_str))

    # ---- x87 ------------------------------------------------------------
    def fmem(self, i, op):
        """value of a memory operand as a double"""
        a = self.addr(i, op)
        if op.size == 4:
            return 'BITS2F(LD32(%s))' % a
        if op.size == 8:
            return 'BITS2D(LD64(%s))' % a
        if op.size == 10:
            return 'xl_ld80(%s)' % a
        raise Unsupported('x87 operand size %d' % op.size)

    def fimem(self, i, op):
        a = self.addr(i, op)
        return {2: '(double)(int16_t)LD16(%s)', 4: '(double)(int32_t)LD32(%s)', 8: '(double)(int64_t)LD64(%s)'}[op.size] % a

    def x87(self, i, m, ops):
        if not m.startswith('f'):
            return None
        P = 'FPUSH(%s);'
        if m == 'fld':
            if self.is_st(ops[0]):
                return ['{ double v = FST(%d); FPUSH(v); }' % self.st(ops[0])]
            return [P % self.fmem(i, ops[0])]
        if m == 'fild':
            return [P % self.fimem(i, ops[0])]
        if m == 'fld1':
            return [P % '1.0']
        if m == 'fldz':
            return [P % '0.0']
        if m in ('fst', 'fstp'):
            pop = ' FPOP;' if m == 'fstp' else ''
            d = ops[0]
            if self.is_st(d):
                return ['FST(%d) = FST(0);%s' % (self.st(d), pop)]
            a = self.addr(i, d)
            if d.size == 4:
                return ['{ float v = (float)FST(0); uint32_t w; memcpy(&w, &v, 4); ST32(%s, w); }%s' % (a, pop)]
            if d.size == 8:
                return ['{ double v = FST(0); uint64_t w; memcpy(&w, &v, 8); ST64(%s, w); }%s' % (a, pop)]
            if d.size == 10:
                return ['xl_st80(%s, FST(0));%s' % (a, pop)]
            raise Unsupported('fst size')
        if m in ('fist', 'fistp', 'fisttp'):
            d = ops[0]
            a = self.addr(i, d)
            cv = 'xl_fround(c, FST(0))' if m != 'fisttp' else 'trunc(FST(0))'
            st = {2: 'ST16(%s, (uint16_t)(int16_t)%s);', 4: 'ST32(%s, (uint32_t)xl_cvtt32(%s));', 8: 'ST64(%s, (uint64_t)(int64_t)%s);'}[d.size] % (a, cv)
            return [st + (' FPOP;' if m != 'fist' else '')]
        if m == 'fxch':
            k = self.st(ops[0]) if ops else 1
            return ['{ double t = FST(0); FST(0) = FST(%d); FST(%d) = t; }' % (k, k)]
        if m == 'fchs':
            return ['FST(0) = -FST(0);']
        if m == 'fabs':
            return ['FST(0) = fabs(FST(0));']
        if m == 'fsqrt':
            return ['FST(0) = sqrt(FST(0));']
        if m == 'frndint':
            return ['FST(0) = xl_fround(c, FST(0));']
        if m in ('fldcw',):
            return ['c->fcw = (uint16_t)LD16(%s);' % self.addr(i, ops[0])]
        if m in ('fnstcw', 'fstcw'):
            return ['ST16(%s, c->fcw);' % self.addr(i, ops[0])]
        if m in ('fnstsw', 'fstsw'):
            v = 'xl_fsw(c)'
            if ops[0].type == x86.X86_OP_REG:
                return ['r0 = (r0 & ~0xffffu) | %s;' % v]
            return ['ST16(%s, %s);' % (self.addr(i, ops[0]), v)]
        arith = {'fadd': '+', 'fsub': '-', 'fmul': '*', 'fdiv': '/', 'fsubr': 'r-', 'fdivr': 'r/'}
        base = m[:-1] if m.endswith('p') and m[:-1] in arith else m
        if m.startswith('fi') and 'f' + m[2:] in arith:
            o = arith['f' + m[2:]]
            v = self.fimem(i, ops[0])
            if o.startswith('r'):
                return ['FST(0) = %s %s FST(0);' % (v, o[1])]
            return ['FST(0) = FST(0) %s %s;' % (o, v)]
        if base in arith:
            o = arith[base]
            pop = m.endswith('p')
            if len(ops) == 1 and not self.is_st(ops[0]):
                v = self.fmem(i, ops[0])
                if o.startswith('r'):
                    return ['FST(0) = %s %s FST(0);' % (v, o[1])]
                return ['FST(0) = FST(0) %s %s;' % (o, v)]
            if not ops:
                d, s = 1, 0
            elif len(ops) == 1:
                d, s = 0, self.st(ops[0])
            else:
                d, s = self.st(ops[0]), self.st(ops[1])
            if o.startswith('r'):
                expr = 'FST(%d) %s FST(%d)' % (s, o[1], d)
            else:
                expr = 'FST(%d) %s FST(%d)' % (d, o, s)
            return ['FST(%d) = %s;%s' % (d, expr, ' FPOP;' if pop else '')]
        if m in ('fucomi', 'fucomip', 'fucompi', 'fcomi', 'fcomip', 'fcompi'):
            k = self.st(ops[1]) if len(ops) > 1 else self.st(ops[0])
            return ['fr = xl_ucom(FST(0), FST(%d)); fop = FOP_DIRECT;%s' % (k, ' FPOP;' if 'p' in m[4:] else '')]
        if m in ('fucom', 'fucomp', 'fucompp', 'fcom', 'fcomp', 'fcompp', 'ficom', 'ficomp', 'ftst'):
            if m == 'ftst':
                v = '0.0'
            elif m.startswith('fi'):
                v = self.fimem(i, ops[0])
            elif ops and not self.is_st(ops[0]):
                v = self.fmem(i, ops[0])
            else:
                v = 'FST(%d)' % (self.st(ops[0]) if ops else 1)
            npop = 2 if m.endswith('pp') else (1 if m.endswith('p') else 0)
            return ['c->fcc = xl_fcom(FST(0), %s);%s' % (v, ' FPOP;' * npop)]
        if m == 'ffree':
            return []
        if m == 'fnstenv':
            return []
        raise Unsupported('x87 %s %s' % (m, i.op_str))

    # ---- SSE ------------------------------------------------------------
    def xsrc64(self, i, op):
        if self.is_xmm(op):
            return '%s.q[0]' % self.xr(op)
        return 'LD64(%s)' % self.addr(i, op)

    def xsrc32(self, i, op):
        if self.is_xmm(op):
            return '%s.d[0]' % self.xr(op)
        return 'LD32(%s)' % self.addr(i, op)

    def xsrc128(self, i, op):
        if self.is_xmm(op):
            return self.xr(op)
        return 'LDX(%s)' % self.addr(i, op)

    def sse(self, i, m, ops):
        if not ops:
            return None
        d = ops[0]
        s = ops[1] if len(ops) > 1 else None
        if m in ('movsd', 'movss'):
            q = m == 'movsd'
            if self.is_xmm(d) and self.is_xmm(s):
                return ['%s.%s = %s.%s;' % (self.xr(d), 'q[0]' if q else 'd[0]', self.xr(s), 'q[0]' if q else 'd[0]')]
            if self.is_xmm(d):
                if q:
                    return ['%s.q[0] = LD64(%s); %s.q[1] = 0;' % (self.xr(d), self.addr(i, s), self.xr(d))]
                return ['%s.q[0] = LD32(%s); %s.q[1] = 0;' % (self.xr(d), self.addr(i, s), self.xr(d))]
            return ['ST%d(%s, %s.%s);' % (64 if q else 32, self.addr(i, d), self.xr(s), 'q[0]' if q else 'd[0]')]
        if m in ('movaps', 'movapd', 'movups', 'movupd', 'movdqa', 'movdqu'):
            if self.is_xmm(d):
                return ['%s = %s;' % (self.xr(d), self.xsrc128(i, s))]
            return ['STX(%s, %s);' % (self.addr(i, d), self.xr(s))]
        if m in ('movq', 'movd'):
            w = 64 if m == 'movq' else 32
            if self.is_xmm(d):
                if s.type == x86.X86_OP_REG and not self.is_xmm(s):
                    v = self.rd(i, s, 32)
                elif self.is_xmm(s):
                    v = '%s.q[0]' % self.xr(s)
                else:
                    v = 'LD%d(%s)' % (w, self.addr(i, s))
                return ['{ uint64_t v = %s; %s.q[0] = v; %s.q[1] = 0; }' % (v if w == 64 else '(uint32_t)(%s)' % v, self.xr(d), self.xr(d))]
            v = '%s.q[0]' % self.xr(s)
            if d.type == x86.X86_OP_REG:
                return [self.wr(i, d, '(uint32_t)' + v, 32)]
            return ['ST%d(%s, %s);' % (w, self.addr(i, d), v)]
        if m in ('movhpd', 'movhps'):
            if self.is_xmm(d):
                return ['%s.q[1] = LD64(%s);' % (self.xr(d), self.addr(i, s))]
            return ['ST64(%s, %s.q[1]);' % (self.addr(i, d), self.xr(s))]
        if m in ('movlpd', 'movlps'):
            if self.is_xmm(d):
                return ['%s.q[0] = LD64(%s);' % (self.xr(d), self.addr(i, s))]
            return ['ST64(%s, %s.q[0]);' % (self.addr(i, d), self.xr(s))]
        if m == 'movhlps':
            return ['%s.q[0] = %s.q[1];' % (self.xr(d), self.xr(s))]
        if m == 'movlhps':
            return ['%s.q[1] = %s.q[0];' % (self.xr(d), self.xr(s))]
        if m == 'movmskpd':
            return [self.wr(i, d, '(uint32_t)((%s.q[0] >> 63) | ((%s.q[1] >> 63) << 1))' % (self.xr(s), self.xr(s)))]
        if m == 'movmskps':
            return [self.wr(i, d, '(uint32_t)((%s.d[0] >> 31) | ((%s.d[1] >> 31) << 1) | ((%s.d[2] >> 31) << 2) | ((%s.d[3] >> 31) << 3))' % ((self.xr(s),) * 4))]
        X = self.xr(d) if self.is_xmm(d) else None
        if m in ('xorps', 'xorpd', 'pxor', 'andps', 'andpd', 'pand', 'orps', 'orpd', 'por', 'andnps', 'andnpd', 'pandn'):
            if m.startswith('andn') or m == 'pandn':
                return ['{ XMM b = %s; %s.q[0] = ~%s.q[0] & b.q[0]; %s.q[1] = ~%s.q[1] & b.q[1]; }' % (self.xsrc128(i, s), X, X, X, X)]
            o = {'pxor': '^', 'pand': '&', 'por': '|'}.get(m) or {'x': '^', 'a': '&', 'o': '|'}[m[0]]
            if self.is_xmm(s) and s.reg == d.reg and o == '^':
                return ['%s.q[0] = 0; %s.q[1] = 0;' % (X, X)]
            return ['{ XMM b = %s; %s.q[0] %s= b.q[0]; %s.q[1] %s= b.q[1]; }' % (self.xsrc128(i, s), X, o, X, o)]
        sd = {'addsd': '+', 'subsd': '-', 'mulsd': '*', 'divsd': '/'}
        if m in sd:
            return ['{ double b = BITS2D(%s); %s.f64[0] = %s.f64[0] %s b; }' % (self.xsrc64(i, s), X, X, sd[m])]
        ss = {'addss': '+', 'subss': '-', 'mulss': '*', 'divss': '/'}
        if m in ss:
            return ['{ float b = BITS2F(%s); %s.f32[0] = %s.f32[0] %s b; }' % (self.xsrc32(i, s), X, X, ss[m])]
        pd = {'addpd': '+', 'subpd': '-', 'mulpd': '*', 'divpd': '/'}
        if m in pd:
            return ['{ XMM b = %s; %s.f64[0] = %s.f64[0] %s b.f64[0]; %s.f64[1] = %s.f64[1] %s b.f64[1]; }'
                    % (self.xsrc128(i, s), X, X, pd[m], X, X, pd[m])]
        if m in ('addps', 'subps', 'mulps', 'divps'):
            o = {'addps': '+', 'subps': '-', 'mulps': '*', 'divps': '/'}[m]
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.f32[k] = %s.f32[k] %s b.f32[k]; }' % (self.xsrc128(i, s), X, X, o)]
        if m in ('maxsd', 'minsd'):
            cmpop = '>' if m == 'maxsd' else '<'
            return ['{ double b = BITS2D(%s), a = %s.f64[0]; %s.f64[0] = (a %s b) ? a : b; }' % (self.xsrc64(i, s), X, X, cmpop)]
        if m in ('maxss', 'minss'):
            cmpop = '>' if m == 'maxss' else '<'
            return ['{ float b = BITS2F(%s), a = %s.f32[0]; %s.f32[0] = (a %s b) ? a : b; }' % (self.xsrc32(i, s), X, X, cmpop)]
        if m in ('maxps', 'minps'):
            cmpop = '>' if m == 'maxps' else '<'
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.f32[k] = (%s.f32[k] %s b.f32[k]) ? %s.f32[k] : b.f32[k]; }' % (self.xsrc128(i, s), X, X, cmpop, X)]
        if m == 'sqrtsd':
            return ['%s.f64[0] = sqrt(BITS2D(%s));' % (X, self.xsrc64(i, s))]
        if m == 'sqrtss':
            return ['%s.f32[0] = sqrtf(BITS2F(%s));' % (X, self.xsrc32(i, s))]
        if m == 'cvtss2sd':
            return ['%s.f64[0] = (double)BITS2F(%s);' % (X, self.xsrc32(i, s))]
        if m == 'cvtsd2ss':
            return ['%s.f32[0] = (float)BITS2D(%s);' % (X, self.xsrc64(i, s))]
        if m in ('cvtsi2sd', 'cvtsi2ss'):
            v = '(int32_t)%s' % self.rd(i, s, 32)
            if m == 'cvtsi2sd':
                return ['%s.f64[0] = (double)%s;' % (X, v)]
            return ['%s.f32[0] = (float)%s;' % (X, v)]
        if m in ('cvttsd2si', 'cvttss2si', 'cvtsd2si', 'cvtss2si'):
            v = 'BITS2D(%s)' % self.xsrc64(i, s) if 'sd' in m else 'BITS2F(%s)' % self.xsrc32(i, s)
            if not m.startswith('cvtt'):
                v = 'nearbyint(%s)' % v
            return [self.wr(i, d, 'xl_cvtt32(%s)' % v)]
        if m == 'cvtps2pd':
            return ['{ uint64_t v = %s; float a = BITS2F((uint32_t)v), b = BITS2F((uint32_t)(v >> 32)); %s.f64[0] = a; %s.f64[1] = b; }' % (self.xsrc64(i, s), X, X)]
        if m == 'cvtpd2ps':
            return ['{ XMM b = %s; %s.f32[0] = (float)b.f64[0]; %s.f32[1] = (float)b.f64[1]; %s.q[1] = 0; }' % (self.xsrc128(i, s), X, X, X)]
        if m == 'cvtdq2ps':
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.f32[k] = (float)(int32_t)b.d[k]; }' % (self.xsrc128(i, s), X)]
        if m == 'cvttps2dq':
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.d[k] = (uint32_t)xl_cvtt32(b.f32[k]); }' % (self.xsrc128(i, s), X)]
        if m in ('ucomisd', 'comisd'):
            return ['fr = xl_ucom(%s.f64[0], BITS2D(%s)); fop = FOP_DIRECT;' % (X, self.xsrc64(i, s))]
        if m in ('ucomiss', 'comiss'):
            return ['fr = xl_ucom(%s.f32[0], BITS2F(%s)); fop = FOP_DIRECT;' % (X, self.xsrc32(i, s))]
        import re
        cm = re.match(r'cmp(eq|lt|le|unord|neq|nlt|nle|ord)(sd|pd|ss|ps)$', m)
        if cm:
            pred = {'eq': 'a == b', 'lt': 'a < b', 'le': 'a <= b', 'unord': 'a != a || b != b', 'neq': '!(a == b)',
                    'nlt': '!(a < b)', 'nle': '!(a <= b)', 'ord': 'a == a && b == b'}[cm.group(1)]
            k = cm.group(2)
            if k == 'sd':
                return ['{ double a = %s.f64[0], b = BITS2D(%s); %s.q[0] = (%s) ? ~0ULL : 0; }' % (X, self.xsrc64(i, s), X, pred)]
            if k == 'pd':
                return ['{ XMM bb = %s; for (int k = 0; k < 2; k++) { double a = %s.f64[k], b = bb.f64[k]; %s.q[k] = (%s) ? ~0ULL : 0; } }' % (self.xsrc128(i, s), X, X, pred)]
            if k == 'ss':
                return ['{ float a = %s.f32[0], b = BITS2F(%s); %s.d[0] = (%s) ? ~0U : 0; }' % (X, self.xsrc32(i, s), X, pred)]
            return ['{ XMM bb = %s; for (int k = 0; k < 4; k++) { float a = %s.f32[k], b = bb.f32[k]; %s.d[k] = (%s) ? ~0U : 0; } }' % (self.xsrc128(i, s), X, X, pred)]
        if m in ('unpcklpd', 'punpcklqdq'):
            return ['{ XMM b = %s; %s.q[1] = b.q[0]; }' % (self.xsrc128(i, s), X)]
        if m in ('unpckhpd', 'punpckhqdq'):
            return ['{ XMM b = %s; %s.q[0] = %s.q[1]; %s.q[1] = b.q[1]; }' % (self.xsrc128(i, s), X, X, X)]
        if m in ('unpcklps', 'punpckldq'):
            return ['{ XMM b = %s, a = %s; %s.d[0] = a.d[0]; %s.d[1] = b.d[0]; %s.d[2] = a.d[1]; %s.d[3] = b.d[1]; }' % (self.xsrc128(i, s), X, X, X, X, X)]
        if m in ('unpckhps', 'punpckhdq'):
            return ['{ XMM b = %s, a = %s; %s.d[0] = a.d[2]; %s.d[1] = b.d[2]; %s.d[2] = a.d[3]; %s.d[3] = b.d[3]; }' % (self.xsrc128(i, s), X, X, X, X, X)]
        if m == 'pshufd':
            imm = ops[2].imm
            return ['{ XMM b = %s; %s.d[0] = b.d[%d]; %s.d[1] = b.d[%d]; %s.d[2] = b.d[%d]; %s.d[3] = b.d[%d]; }'
                    % (self.xsrc128(i, s), X, imm & 3, X, (imm >> 2) & 3, X, (imm >> 4) & 3, X, (imm >> 6) & 3)]
        if m == 'shufps':
            imm = ops[2].imm
            return ['{ XMM a = %s, b = %s; %s.d[0] = a.d[%d]; %s.d[1] = a.d[%d]; %s.d[2] = b.d[%d]; %s.d[3] = b.d[%d]; }'
                    % (X, self.xsrc128(i, s), X, imm & 3, X, (imm >> 2) & 3, X, (imm >> 4) & 3, X, (imm >> 6) & 3)]
        if m == 'shufpd':
            imm = ops[2].imm
            return ['{ XMM a = %s, b = %s; %s.q[0] = a.q[%d]; %s.q[1] = b.q[%d]; }' % (X, self.xsrc128(i, s), X, imm & 1, X, (imm >> 1) & 1)]
        if m in ('pcmpeqd', 'pcmpgtd'):
            o = '==' if m == 'pcmpeqd' else '>'
            cast = '' if m == 'pcmpeqd' else '(int32_t)'
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.d[k] = (%s%s.d[k] %s %sb.d[k]) ? ~0U : 0; }' % (self.xsrc128(i, s), X, cast, X, o, cast)]
        if m in ('paddd', 'psubd'):
            o = '+' if m == 'paddd' else '-'
            return ['{ XMM b = %s; for (int k = 0; k < 4; k++) %s.d[k] %s= b.d[k]; }' % (self.xsrc128(i, s), X, o)]
        if m in ('paddq', 'psubq'):
            o = '+' if m == 'paddq' else '-'
            return ['{ XMM b = %s; %s.q[0] %s= b.q[0]; %s.q[1] %s= b.q[1]; }' % (self.xsrc128(i, s), X, o, X, o)]
        if m in ('psrlq', 'psllq', 'psrld', 'pslld', 'psrad') and ops[1].type == x86.X86_OP_IMM:
            n = ops[1].imm
            o = '>>' if m.startswith('psr') else '<<'
            if m.endswith('q'):
                if n > 63:
                    return ['%s.q[0] = 0; %s.q[1] = 0;' % (X, X)]
                return ['%s.q[0] %s= %d; %s.q[1] %s= %d;' % (X, o, n, X, o, n)]
            if m == 'psrad':
                return ['for (int k = 0; k < 4; k++) %s.d[k] = (uint32_t)((int32_t)%s.d[k] >> %d);' % (X, X, min(n, 31))]
            if n > 31:
                return ['%s.q[0] = 0; %s.q[1] = 0;' % (X, X)]
            return ['for (int k = 0; k < 4; k++) %s.d[k] %s= %d;' % (X, o, n)]
        if m in ('psrldq', 'pslldq') and ops[1].type == x86.X86_OP_IMM:
            n = min(ops[1].imm, 16)
            if m == 'psrldq':
                return ['{ XMM a = %s; for (int k = 0; k < 16; k++) %s.b[k] = (k + %d < 16) ? a.b[k + %d] : 0; }' % (X, X, n, n)]
            return ['{ XMM a = %s; for (int k = 0; k < 16; k++) %s.b[k] = (k >= %d) ? a.b[k - %d] : 0; }' % (X, X, n, n)]
        return None

    # ---- whole function ---------------------------------------------------
    def emit(self):
        f = self.f
        out = ['void %s(XLCPU *c)\n{\n\tREGS;\n\tXL_TRACE(A(0x%x));\n\tgoto L_%x;' % (self.name(f.start), f.start, f.start)]
        for a in sorted(f.insns):
            i = f.insns[a]
            if a in f.leaders or a == f.start:
                out.append('L_%x:' % a)
            if i is None:
                out.append('\tSO; %s(c); return;' % self.name(a))
                continue
            if isinstance(i, str):
                out.append('\txl_trap(c, A(0x%x));' % a)
                continue
            m = i.mnemonic
            body = None
            try:
                if m == 'call':
                    body = [self.try_wrap(a, self.call_target(i, i.operands[0], False))]
                elif m == 'jmp':
                    op = i.operands[0]
                    if op.type == x86.X86_OP_IMM and f.owns(op.imm):
                        body = ['goto L_%x;' % op.imm]
                    elif a in f.tables:
                        v = self.rd(i, op, 32)
                        cases = ' '.join('case 0x%x: goto L_%x;' % (t, t) for t in f.tables[a])
                        body = ['switch ((uint32_t)(%s - S)) { %s default: xl_badjump(c, %s); }' % (v, cases, v)]
                    else:
                        body = [self.call_target(i, op, True)]
                elif m.startswith('j'):
                    cond = CONDS[m[1:]] if m[1:] in CONDS else None
                    if m == 'jecxz':
                        cond = 'r1 == 0'
                    if cond is None:
                        raise Unsupported(m)
                    t = i.operands[0].imm
                    if f.owns(t):
                        body = ['if (%s) goto L_%x;' % (cond, t)]
                    else:
                        body = ['if (%s) { %s }' % (cond, self.call_target(i, i.operands[0], True))]
                elif m == 'ret':
                    n = i.operands[0].imm if i.operands else 0
                    body = ['r4 += %d; SO; return;' % (4 + n)]
                else:
                    body = self.insn(i)
            except Unsupported as ex:
                body = ['xl_unsupported(c, A(0x%x), "%s");' % (a, str(ex).replace('"', "'"))]
                UNSUP.append((a, str(ex)))
            out.append('\t/* %x: %s %s */ %s' % (a, m, i.op_str, ' '.join(body)))
            nxt = a + i.size
            if m not in ('jmp', 'ret', 'ud2', 'hlt') and nxt not in f.insns:
                out.append('\txl_trap(c, A(0x%x));' % nxt)
        out.append('}\n')
        return '\n'.join(self.ehs + out)


XEXPORTS = set()
UNSUP = []


def main():
    path, ident, outdir = sys.argv[1:4]
    for o in sys.argv[4:]:
        XEXPORTS.update(macho32.MachO32(o).exports)
    img = Image(path, ident)
    LSDA.update(eh32.lsda_map(img.m))
    cs = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    cs.detail = True
    funcs, failed = {}, {}
    todo = sorted(img.starts)
    while todo:
        s = todo.pop()
        if s in funcs or s in failed:
            continue
        try:
            fn = Func(img, s, cs)
        except Unsupported as ex:
            failed[s] = str(ex)
            continue
        funcs[s] = fn
        for t in fn.ext_targets:
            if img.in_text(t) and t not in funcs and t not in img.stubs:
                if t not in img.starts:
                    img.starts.add(t)
                todo.append(t)
    order = sorted(funcs)
    os.makedirs(outdir, exist_ok=True)
    imports = {}
    hdr = ['#include "xlcode.h"', 'extern uint32_t xl_slide_%s;' % ident, '#define S xl_slide_%s' % ident,
           'extern XLImport xl_imports_%s[];' % ident, '#define XI xl_imports_%s' % ident]
    hdr += ['void F_%s_%x(XLCPU *c);' % (ident, a) for a in order]
    for s, why in failed.items():
        hdr.append('/* not translated: %x %s */' % (s, why))
    open(os.path.join(outdir, 'code.h'), 'w').write('\n'.join(hdr) + '\n')
    chunk, n, fileno = [], 0, 0

    def flush():
        nonlocal chunk, n, fileno
        if chunk:
            p = os.path.join(outdir, 'code%03d.c' % fileno)
            body = '#include "code.h"\n\n' + '\n'.join(chunk)
            if not os.path.exists(p) or open(p).read() != body:
                open(p, 'w').write(body)
            fileno += 1
        chunk, n = [], 0
    for a in order:
        em = Emitter(img, funcs[a], imports)
        chunk.append(em.emit())
        n += len(funcs[a].insns)
        if n > 6000:
            flush()
    flush()
    m = img.m
    t = ['#include "code.h"', '', 'uint32_t xl_slide_%s;' % ident, 'static XLFunc funcs[] = {']
    for a in order:
        nm = img.names.get(a, '')
        t.append('\t{F_%s_%x, 0x%x, "%s"},' % (ident, a, a, nm.replace('"', '').replace('\\', '')))
    t.append('};')
    t.append('XLImport xl_imports_%s[] = {' % ident)
    for sym, k in sorted(imports.items(), key=lambda x: x[1]):
        t.append('\t{"%s"},' % sym)
    t.append('\t{0}\n};')
    open(os.path.join(outdir, 'image.bin'), 'wb').write(bytes(img.mem))
    t.append('static const uint32_t rebases[] = {%s};' % ', '.join('0x%x' % r for r in sorted(img.rebases)))
    binds = dict(m.binds)
    for slot, sym in m.slots.items():
        binds[slot] = (sym, 0)
    t.append('static const XLBind binds[] = {')
    for slot, (sym, add) in sorted(binds.items()):
        t.append('\t{0x%x, "%s", %d},' % (slot, sym, add))
    t.append('\t{0}};')
    t.append('static const XLBind stubs[] = {')
    for a, sym in sorted(m.stubs.items()):
        t.append('\t{0x%x, "%s", 0},' % (a, sym))
    t.append('\t{0}};')
    t.append('static const XLExport exports[] = {')
    for nm, a in sorted(m.exports.items()):
        t.append('\t{"%s", 0x%x},' % (nm, a))
    t.append('\t{0}};')
    t.append('static const XLSection sections[] = {')
    for s in m.sections:
        t.append('\t{"%s", "%s", 0x%x, 0x%x, 0x%x},' % (s.seg, s.name, s.addr, s.size, s.flags))
    t.append('\t{0}};')
    t.append('static const char *dylibs[] = {%s0};' % ''.join('"%s", ' % d for d in m.dylibs))
    t.append('extern const unsigned char xl_blob_%s[];' % ident)
    t.append('XLImage xl_image_%s = {"%s", "%s", 0x%x, 0x%x, xl_blob_%s, rebases, %d, binds, %d, stubs, %d, exports, %d, '
             'funcs, %d, xl_imports_%s, %d, sections, dylibs, &xl_slide_%s, 0x%x, 0x%x};'
             % (ident, ident, getattr(m, 'install_name', ''), img.lo, img.hi - img.lo, ident, len(img.rebases), len(binds),
                len(m.stubs), len(m.exports), len(order), ident, len(imports), ident, m.entry or 0, m.init_routine or 0))
    t.append('__attribute__((constructor)) static void load_%s(void) { xl_register_image(&xl_image_%s); }' % (ident, ident))
    open(os.path.join(outdir, 'image.c'), 'w').write('\n'.join(t) + '\n')
    open(os.path.join(outdir, 'blob.S'), 'w').write(
        '\t.section __DATA,__xlimage\n\t.globl _xl_blob_%s\n\t.p2align 14\n_xl_blob_%s:\n\t.incbin "%s"\n'
        % (ident, ident, os.path.abspath(os.path.join(outdir, 'image.bin'))))
    print('%s: %d functions (%d failed), %d imports, %d unsupported instructions, %d code files'
          % (ident, len(order), len(failed), len(imports), len(UNSUP), fileno))
    from collections import Counter
    print(Counter(w.split(' ')[0] + ' ' + (w.split(' ')[1] if len(w.split(' ')) > 1 else '') for _, w in UNSUP).most_common(30))
    for s, why in list(failed.items())[:10]:
        print('failed %x: %s' % (s, why))


if __name__ == '__main__':
    main()
