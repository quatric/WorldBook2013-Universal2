#!/usr/bin/env python3
"""Static binary translator: PowerPC PEF (CFM) application -> C.

usage: liftppc.py <PEF file> <out dir>

The code and data sections are laid out at fixed guest addresses (CODE_BASE,
DATA_BASE) with every relocation applied; the result is image.bin, mapped as is
by the runtime (xlate/ppc/rt). Guest memory is big-endian, as on the original.
Imported symbol i resolves to the transition vector at IMPORT_TV + 8 i, whose
code address IMPORT_CODE + 4 i is the runtime's shim for it.

Every function becomes `void F_<addr>(PPC *c)` on the register file in the CPU
struct. Functions come from the CodeWarrior traceback tables (name and extent),
`bl` targets and the transition vectors in the data section. Inside a function
branches are gotos; `bl` is a C call; `blr` returns; `bctr` goes to a jump table
target of this function or else, as a tail call, through ppc_call (transition
vector glue, calls through function pointers).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pef  # noqa: E402

CODE_BASE = 0x01000000
DATA_BASE = 0x02000000
IMPORT_TV = 0x00f00000
IMPORT_CODE = 0xff000000


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


def mask32(mb, me):
    if mb <= me:
        m = ((0xffffffff >> mb) & (0xffffffff << (31 - me))) & 0xffffffff
    else:
        m = ((0xffffffff >> mb) | (0xffffffff << (31 - me))) & 0xffffffff
    return m


class Image:
    def __init__(self, path):
        self.pef = p = pef.PEF(path)
        self.code_sec = next(s for s in p.sections if s.kind == 0)
        self.data_sec = next(s for s in p.sections if s.kind in (1, 2))
        bases = {self.code_sec.index: CODE_BASE, self.data_sec.index: DATA_BASE}
        self.mem, self.refs = p.layout(bases, lambda i: IMPORT_TV + 8 * i)
        self.code = self.mem[self.code_sec.index]
        self.data = self.mem[self.data_sec.index]
        self.code_end = CODE_BASE + len(self.code)
        self.imports = p.imports
        mo = p.main_off
        self.main_tv = DATA_BASE + mo
        self.names = {}
        self.extent = {}     # function start -> end (traceback table)
        self.traceback()

    def in_code(self, a):
        return CODE_BASE <= a < self.code_end and not a & 3

    def word(self, a):
        return struct.unpack_from('>I', self.code, a - CODE_BASE)[0]

    def dword(self, a):
        return struct.unpack_from('>I', self.data, a - DATA_BASE)[0]

    def traceback(self):
        c = self.code
        n = len(c) // 4
        for i in range(n - 3):
            if struct.unpack_from('>I', c, 4 * i)[0] != 0:
                continue
            if i == 0:
                continue
            pw = struct.unpack_from('>I', c, 4 * i - 4)[0]
            if pw not in (0x4e800020, 0x4e800420, 0x4c000064) and (pw >> 26) != 18 and pw != 0x7fe00008:
                continue
            o = 4 * i + 4
            if o + 8 > len(c):
                continue
            ver, lang, f2, f3, f4, f5, fixp, flp = struct.unpack_from('>8B', c, o)
            if ver != 0 or lang > 12:
                continue
            o += 8
            if fixp or (flp >> 1):
                o += 4
            if not f2 & 0x20:
                continue
            tboff = struct.unpack_from('>I', c, o)[0]
            o += 4
            start = CODE_BASE + 4 * i - tboff
            if not tboff or tboff & 3 or start < CODE_BASE:
                continue
            if f3 & 0x80:      # int_hndl
                o += 4
            if f2 & 0x08:      # has_ctl
                cnt = struct.unpack_from('>I', c, o)[0]
                o += 4 + 4 * cnt
            name = None
            if f3 & 0x40 and o + 2 <= len(c):
                ln = struct.unpack_from('>H', c, o)[0]
                if ln < 512:
                    name = c[o + 2:o + 2 + ln].decode('mac_roman', 'replace').lstrip('.')
            self.extent[start] = CODE_BASE + 4 * i
            if name:
                self.names[start] = name


# ---------------------------------------------------------------- decoding

class Insn:
    __slots__ = ('addr', 'w', 'op', 'kind', 'targets', 'fallthrough', 'call')

    def __init__(self, addr, w):
        self.addr, self.w = addr, w
        self.op = w >> 26
        self.kind = 'op'          # op, b, bc, blr, bctr, trap
        self.targets = []
        self.fallthrough = True
        self.call = None


def fields(w):
    return (w >> 21) & 31, (w >> 16) & 31, (w >> 11) & 31


def classify(img, a):
    w = img.word(a)
    i = Insn(a, w)
    op = i.op
    if op == 18:
        li = w & 0x03fffffc
        if li & 0x02000000:
            li -= 0x04000000
        t = (li if w & 2 else a + li) & 0xffffffff
        if w & 1:
            i.kind, i.call = 'bl', t
        else:
            i.kind, i.targets, i.fallthrough = 'b', [t], False
    elif op == 16:
        bd = w & 0xfffc
        if bd & 0x8000:
            bd -= 0x10000
        t = (bd if w & 2 else a + bd) & 0xffffffff
        bo = (w >> 21) & 31
        if w & 1:
            i.kind, i.call = 'bcl', t
        else:
            i.kind, i.targets = 'bc', [t]
            if bo & 0x14 == 0x14:
                i.fallthrough = False
    elif op == 19:
        xo = (w >> 1) & 0x3ff
        bo = (w >> 21) & 31
        if xo == 16:
            i.kind = 'bclr'
            if bo & 0x14 == 0x14 and not w & 1:
                i.fallthrough = False
        elif xo == 528:
            i.kind = 'bcctr'
            if bo & 0x14 == 0x14 and not w & 1:
                i.fallthrough = False
    elif op == 31 and ((w >> 1) & 0x3ff) == 4 and ((w >> 21) & 31) == 31:
        i.kind = 'trap'
    elif op == 3 and ((w >> 21) & 31) == 31:
        i.kind = 'trap'
    return i


class Func:
    def __init__(self, img, start, starts, jt_targets, limit):
        self.img, self.start = img, start
        self.end = img.extent.get(start) or limit
        self.insns = {}
        self.labels = set()
        self.bctr_targets = {}
        self.resume = []          # catch blocks: entered from the exception unwinder
        self.starts, self.jt = starts, jt_targets
        self.explore(start)

    def explore(self, seed):
        img, start, starts, jt_targets = self.img, self.start, self.starts, self.jt
        work = [seed]
        while work:
            a = work.pop()
            while True:
                if a in self.insns:
                    break
                if not img.in_code(a) or (self.end and not (start <= a < self.end) and a not in self.labels):
                    break
                ins = classify(img, a)
                self.insns[a] = ins
                if ins.kind in ('b', 'bc'):
                    for t in ins.targets:
                        if self.is_tail(t, starts):
                            continue
                        self.labels.add(t)
                        work.append(t)
                if ins.kind == 'bcctr' and not ins.w & 1:
                    # jump table targets inside this function
                    lo, hi = start, self.end or start + 0x4000
                    ts = sorted(t for t in jt_targets if lo <= t < hi)
                    self.bctr_targets[a] = ts
                    for t in ts:
                        self.labels.add(t)
                        work.append(t)
                if not ins.fallthrough:
                    break
                a += 4
                if self.end and a >= self.end:
                    break
                if a in starts and a != start:
                    # falls into the next function: a tail call
                    ins.kind = ins.kind if ins.kind != 'op' else 'op'
                    self.insns[a - 4].fallthrough = 'into'
                    break

    def add_catch_blocks(self):
        """Code in this function that no branch reaches: the catch blocks the
        exception tables name. Each becomes a place a throw can resume."""
        if not self.end:
            return
        a = self.start
        while a < self.end:
            if a not in self.insns and self.img.word(a) != 0 and classify(self.img, a).kind != 'trap':
                self.resume.append(a)
                self.labels.add(a)
                self.explore(a)
            a += 4

    def switches_stack(self):
        # lwz r1, d(rX) with X other than r1: the catch transfer (or longjmp)
        return any(i.op == 32 and (i.w >> 21) & 31 == 1 and (i.w >> 16) & 31 not in (0, 1)
                   for i in self.insns.values())

    def is_tail(self, t, starts):
        if t == self.start:
            return False
        if t in starts:
            return True
        if self.end and not (self.start <= t < self.end):
            return t in starts
        return False


# ---------------------------------------------------------------- C emission

def ea_d(ra, d):
    return ('(uint32_t)%d' % d) if ra == 0 else 'R(%d) + (uint32_t)%d' % (ra, d)


def ea_x(ra, rb):
    return 'R(%d)' % rb if ra == 0 else 'R(%d) + R(%d)' % (ra, rb)


def rc0(w, expr='R(%d)'):
    return ''


class Emitter:
    def __init__(self, img, funcs):
        self.img = img
        self.funcs = funcs

    def fname(self, a):
        return 'F_%08x' % a

    def branch_cond(self, bo, bi, allow_ctr=True):
        conds = []
        pre = ''
        if not bo & 4 and allow_ctr:
            pre = 'c->ctr--; '
            conds.append('c->ctr != 0' if not bo & 2 else 'c->ctr == 0')
        if not bo & 16:
            conds.append('CRB(%d)' % bi if bo & 8 else '!CRB(%d)' % bi)
        return pre, (' && '.join(conds) if conds else '1')

    def call_to(self, t, nxt):
        if t in self.funcs:
            return 'c->lr = 0x%08x; %s(c);' % (nxt, self.fname(t))
        return 'c->lr = 0x%08x; ppc_call(c, 0x%08x);' % (nxt, t)

    def tail_to(self, t):
        if t in self.funcs:
            return '%s(c); return;' % self.fname(t)
        return 'ppc_call(c, 0x%08x); return;' % t

    def insn(self, f, ins):
        w, a = ins.w, ins.addr
        op = ins.op
        nxt = a + 4
        rd, ra, rb = fields(w)
        rc = w & 1
        simm = s16(w & 0xffff)
        uimm = w & 0xffff
        k = ins.kind
        if k == 'b':
            t = ins.targets[0]
            if t in f.labels:
                return 'goto L_%08x;' % t
            return self.tail_to(t)
        if k == 'bl':
            return self.call_to(ins.call, nxt)
        if k in ('bc', 'bcl'):
            pre, cond = self.branch_cond(rd, ra)
            if k == 'bcl':
                t = ins.call
                if t == nxt:   # bcl 20,31,$+4: the program counter in lr
                    return '%sc->lr = 0x%08x;' % (pre, nxt)
                return '%sif (%s) { %s }' % (pre, cond, self.call_to(t, nxt))
            t = ins.targets[0]
            if t in f.labels:
                return '%sif (%s) goto L_%08x;' % (pre, cond, t)
            return '%sif (%s) { %s }' % (pre, cond, self.tail_to(t))
        if k == 'bclr':
            pre, cond = self.branch_cond(rd, ra)
            if rc:
                return '%sif (%s) { uint32_t t = c->lr; c->lr = 0x%08x; ppc_call(c, t); }' % (pre, cond, nxt)
            if f.stack_switch:
                ret = 'ppc_resume(c, c->lr); return;'
                if cond == '1':
                    return pre + ret
                return '%sif (%s) { %s }' % (pre, cond, ret)
            if cond == '1':
                return pre + 'return;'
            return '%sif (%s) return;' % (pre, cond)
        if k == 'bcctr':
            pre, cond = self.branch_cond(rd, ra, False)
            if rc:
                return 'if (%s) { c->lr = 0x%08x; ppc_call(c, c->ctr); }' % (cond, nxt)
            ts = f.bctr_targets.get(a, [])
            body = 'uint32_t t = c->ctr; '
            if ts:
                body += 'switch (t) { %s default: break; } ' % ' '.join(
                    'case 0x%08x: goto L_%08x;' % (t, t) for t in ts)
            body += 'ppc_call(c, t); return;'
            if cond == '1':
                return '{ %s }' % body
            return 'if (%s) { %s }' % (cond, body)
        if k == 'trap':
            return 'ppc_trap(c, 0x%08x);' % a
        if op == 14:
            return 'R(%d) = %s;' % (rd, ea_d(ra, simm))
        if op == 15:
            return 'R(%d) = %s;' % (rd, ea_d(ra, (simm << 16) & 0xffffffff if simm >= 0 else (simm << 16)))
        if op == 7:
            return 'R(%d) = (uint32_t)((int32_t)R(%d) * %d);' % (rd, ra, simm)
        if op == 8:
            return '{ uint64_t t = (uint64_t)(uint32_t)~R(%d) + (uint32_t)%d + 1; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (
                ra, simm & 0xffffffff, rd)
        if op == 10:
            crf = rd >> 2
            return 'CMPU(%d, R(%d), %du);' % (crf, ra, uimm)
        if op == 11:
            crf = rd >> 2
            return 'CMPS(%d, R(%d), %d);' % (crf, ra, simm)
        if op in (12, 13):
            s = '{ uint64_t t = (uint64_t)R(%d) + (uint32_t)%d; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (
                ra, simm & 0xffffffff, rd)
            if op == 13:
                s += ' CR0(R(%d));' % rd
            return s
        if op == 20:   # rlwimi
            sh, mb, me = rb, (w >> 6) & 31, (w >> 1) & 31
            m = mask32(mb, me)
            s = 'R(%d) = (ROTL(R(%d), %d) & 0x%08xu) | (R(%d) & 0x%08xu);' % (ra, rd, sh, m, ra, (~m) & 0xffffffff)
            return s + (' CR0(R(%d));' % ra if rc else '')
        if op == 21:   # rlwinm
            sh, mb, me = rb, (w >> 6) & 31, (w >> 1) & 31
            m = mask32(mb, me)
            s = 'R(%d) = ROTL(R(%d), %d) & 0x%08xu;' % (ra, rd, sh, m)
            return s + (' CR0(R(%d));' % ra if rc else '')
        if op == 23:   # rlwnm
            mb, me = (w >> 6) & 31, (w >> 1) & 31
            m = mask32(mb, me)
            s = 'R(%d) = ROTL(R(%d), R(%d) & 31) & 0x%08xu;' % (ra, rd, rb, m)
            return s + (' CR0(R(%d));' % ra if rc else '')
        if op == 24:
            if rd == 0 and ra == 0 and uimm == 0:
                return ';'
            return 'R(%d) = R(%d) | 0x%xu;' % (ra, rd, uimm)
        if op == 25:
            return 'R(%d) = R(%d) | 0x%xu;' % (ra, rd, uimm << 16)
        if op == 26:
            return 'R(%d) = R(%d) ^ 0x%xu;' % (ra, rd, uimm)
        if op == 27:
            return 'R(%d) = R(%d) ^ 0x%xu;' % (ra, rd, uimm << 16)
        if op == 28:
            return 'R(%d) = R(%d) & 0x%xu; CR0(R(%d));' % (ra, rd, uimm, ra)
        if op == 29:
            return 'R(%d) = R(%d) & 0x%xu; CR0(R(%d));' % (ra, rd, uimm << 16, ra)
        # loads and stores, D form
        LS = {32: ('L32', 'z'), 33: ('L32', 'u'), 34: ('L8', 'z'), 35: ('L8', 'u'), 40: ('L16', 'z'),
              41: ('L16', 'u'), 42: ('L16S', 'z'), 43: ('L16S', 'u'),
              36: ('S32', 'z'), 37: ('S32', 'u'), 38: ('S8', 'z'), 39: ('S8', 'u'), 44: ('S16', 'z'), 45: ('S16', 'u'),
              48: ('LFS', 'z'), 49: ('LFS', 'u'), 50: ('LFD', 'z'), 51: ('LFD', 'u'),
              52: ('SFS', 'z'), 53: ('SFS', 'u'), 54: ('SFD', 'z'), 55: ('SFD', 'u')}
        if op in LS:
            kind, upd = LS[op]
            ea = ea_d(ra, simm) if upd == 'z' else 'R(%d) + (uint32_t)%d' % (ra, simm)
            return self.ls(kind, rd, ea, ra if upd == 'u' else None)
        if op == 46:   # lmw
            return 'for (int i = %d; i < 32; i++) R(i) = LD32(%s + 4 * (i - %d));' % (rd, ea_d(ra, simm), rd)
        if op == 47:
            return 'for (int i = %d; i < 32; i++) ST32(%s + 4 * (i - %d), R(i));' % (rd, ea_d(ra, simm), rd)
        if op == 31:
            return self.op31(f, ins, rd, ra, rb, rc)
        if op == 59:
            return self.fp(ins, rd, ra, rb, (w >> 6) & 31, rc, True)
        if op == 63:
            return self.fp(ins, rd, ra, rb, (w >> 6) & 31, rc, False)
        if op == 19:
            return self.op19(ins, rd, ra, rb)
        if op == 17:
            return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (a, w)
        return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (a, w)

    def ls(self, kind, rd, ea, upd):
        e = 'uint32_t ea = %s; ' % ea
        tail = (' R(%d) = ea;' % upd) if upd is not None else ''
        if kind == 'L32':
            s = 'R(%d) = LD32(ea);' % rd
        elif kind == 'L16':
            s = 'R(%d) = LD16(ea);' % rd
        elif kind == 'L16S':
            s = 'R(%d) = (uint32_t)(int32_t)(int16_t)LD16(ea);' % rd
        elif kind == 'L8':
            s = 'R(%d) = LD8(ea);' % rd
        elif kind == 'S32':
            s = 'ST32(ea, R(%d));' % rd
        elif kind == 'S16':
            s = 'ST16(ea, R(%d));' % rd
        elif kind == 'S8':
            s = 'ST8(ea, R(%d));' % rd
        elif kind == 'LFS':
            s = 'FD(%d) = (double)LDF(ea);' % rd
        elif kind == 'LFD':
            s = 'FU(%d) = LD64(ea);' % rd
        elif kind == 'SFS':
            s = 'STF(ea, (float)FD(%d));' % rd
        elif kind == 'SFD':
            s = 'ST64(ea, FU(%d));' % rd
        else:
            raise ValueError(kind)
        # with update and rD == rA, the load result wins: write ea first
        if upd is not None and kind.startswith('L') and upd == rd and kind not in ('LFS', 'LFD'):
            return '{ %s%s }' % (e, s)
        return '{ %s%s%s }' % (e, s, tail)

    def op19(self, ins, bt, ba, bb):
        w = ins.w
        xo = (w >> 1) & 0x3ff
        if xo == 0:   # mcrf
            return 'SETCRF(%d, CRF(%d));' % (bt >> 2, ba >> 2)
        ops = {257: 'a & b', 129: 'a & !b', 289: '!(a ^ b)', 225: '!(a & b)', 33: '!(a | b)', 449: 'a | b',
               417: 'a | !b', 193: 'a ^ b'}
        if xo in ops:
            return '{ int a = CRB(%d), b = CRB(%d); SETCRB(%d, %s); }' % (ba, bb, bt, ops[xo])
        if xo in (150, 50):   # isync, rfi
            return ';'
        return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (ins.addr, w)

    def op31(self, f, ins, rd, ra, rb, rc):
        w, a = ins.w, ins.addr
        xo = (w >> 1) & 0x3ff
        xo9 = (w >> 1) & 0x1ff
        rec = (' CR0(R(%d));' % rd) if rc else ''
        XO = {
            266: 'R(%d) = R(%d) + R(%d);' % (rd, ra, rb),
            40: 'R(%d) = R(%d) - R(%d);' % (rd, rb, ra),
            235: 'R(%d) = (uint32_t)((int32_t)R(%d) * (int32_t)R(%d));' % (rd, ra, rb),
            75: 'R(%d) = (uint32_t)(((int64_t)(int32_t)R(%d) * (int64_t)(int32_t)R(%d)) >> 32);' % (rd, ra, rb),
            11: 'R(%d) = (uint32_t)(((uint64_t)R(%d) * (uint64_t)R(%d)) >> 32);' % (rd, ra, rb),
            491: 'R(%d) = DIVW(R(%d), R(%d));' % (rd, ra, rb),
            459: 'R(%d) = R(%d) ? R(%d) / R(%d) : 0;' % (rd, rb, ra, rb),
            104: 'R(%d) = (uint32_t)-(int32_t)R(%d);' % (rd, ra),
            10: '{ uint64_t t = (uint64_t)R(%d) + R(%d); R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rb, rd),
            138: '{ uint64_t t = (uint64_t)R(%d) + R(%d) + c->ca; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rb, rd),
            8: '{ uint64_t t = (uint64_t)(uint32_t)~R(%d) + R(%d) + 1; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rb, rd),
            136: '{ uint64_t t = (uint64_t)(uint32_t)~R(%d) + R(%d) + c->ca; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rb, rd),
            202: '{ uint64_t t = (uint64_t)R(%d) + c->ca; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rd),
            200: '{ uint64_t t = (uint64_t)(uint32_t)~R(%d) + c->ca; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rd),
            234: '{ uint64_t t = (uint64_t)R(%d) + c->ca + 0xffffffffu; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rd),
            232: '{ uint64_t t = (uint64_t)(uint32_t)~R(%d) + c->ca + 0xffffffffu; R(%d) = (uint32_t)t; c->ca = t >> 32; }' % (ra, rd),
        }
        if xo9 in XO:
            return XO[xo9] + rec
        reca = (' CR0(R(%d));' % ra) if rc else ''
        LOG = {28: '&', 444: '|', 316: '^'}
        if xo in LOG:
            if xo == 444 and rd == rb:
                return 'R(%d) = R(%d);' % (ra, rd) + reca
            return 'R(%d) = R(%d) %s R(%d);' % (ra, rd, LOG[xo], rb) + reca
        if xo == 60:
            return 'R(%d) = R(%d) & ~R(%d);' % (ra, rd, rb) + reca
        if xo == 412:
            return 'R(%d) = R(%d) | ~R(%d);' % (ra, rd, rb) + reca
        if xo == 476:
            return 'R(%d) = ~(R(%d) & R(%d));' % (ra, rd, rb) + reca
        if xo == 124:
            return 'R(%d) = ~(R(%d) | R(%d));' % (ra, rd, rb) + reca
        if xo == 284:
            return 'R(%d) = ~(R(%d) ^ R(%d));' % (ra, rd, rb) + reca
        if xo == 954:
            return 'R(%d) = (uint32_t)(int32_t)(int8_t)R(%d);' % (ra, rd) + reca
        if xo == 922:
            return 'R(%d) = (uint32_t)(int32_t)(int16_t)R(%d);' % (ra, rd) + reca
        if xo == 26:
            return 'R(%d) = R(%d) ? __builtin_clz(R(%d)) : 32;' % (ra, rd, rd) + reca
        if xo == 24:
            return 'R(%d) = (R(%d) & 0x20) ? 0 : R(%d) << (R(%d) & 31);' % (ra, rb, rd, rb) + reca
        if xo == 536:
            return 'R(%d) = (R(%d) & 0x20) ? 0 : R(%d) >> (R(%d) & 31);' % (ra, rb, rd, rb) + reca
        if xo == 792:
            return 'R(%d) = SRAW(c, R(%d), R(%d) & 63);' % (ra, rd, rb) + reca
        if xo == 824:
            return 'R(%d) = SRAW(c, R(%d), %d);' % (ra, rd, rb) + reca
        if xo == 0:
            return 'CMPS(%d, R(%d), R(%d));' % (rd >> 2, ra, rb)
        if xo == 32:
            return 'CMPU(%d, R(%d), R(%d));' % (rd >> 2, ra, rb)
        LSX = {23: ('L32', 0), 55: ('L32', 1), 87: ('L8', 0), 119: ('L8', 1), 279: ('L16', 0), 311: ('L16', 1),
               343: ('L16S', 0), 375: ('L16S', 1), 151: ('S32', 0), 183: ('S32', 1), 215: ('S8', 0), 247: ('S8', 1),
               407: ('S16', 0), 439: ('S16', 1), 535: ('LFS', 0), 567: ('LFS', 1), 599: ('LFD', 0), 631: ('LFD', 1),
               663: ('SFS', 0), 695: ('SFS', 1), 727: ('SFD', 0), 759: ('SFD', 1), 20: ('L32', 0)}
        if xo in LSX:
            kind, u = LSX[xo]
            return self.ls(kind, rd, ea_x(ra, rb) if not u else 'R(%d) + R(%d)' % (ra, rb), ra if u else None)
        if xo == 150:   # stwcx.
            return '{ ST32(%s, R(%d)); SETCRF(0, 2 | c->so); }' % (ea_x(ra, rb), rd)
        if xo == 534:
            return 'R(%d) = __builtin_bswap32(LD32(%s));' % (rd, ea_x(ra, rb))
        if xo == 790:
            return 'R(%d) = __builtin_bswap16((uint16_t)LD16(%s));' % (rd, ea_x(ra, rb))
        if xo == 662:
            return 'ST32(%s, __builtin_bswap32(R(%d)));' % (ea_x(ra, rb), rd)
        if xo == 918:
            return 'ST16(%s, __builtin_bswap16((uint16_t)R(%d)));' % (ea_x(ra, rb), rd)
        if xo == 983:
            return 'ST32(%s, (uint32_t)FU(%d));' % (ea_x(ra, rb), rd)
        if xo == 597:   # lswi
            n = rb or 32
            return 'LSWI(c, %s, %d, %d);' % (ea_d(ra, 0), rd, n)
        if xo == 725:
            n = rb or 32
            return 'STSWI(c, %s, %d, %d);' % (ea_d(ra, 0), rd, n)
        if xo == 533:
            return 'LSWI(c, %s, %d, c->xer_bc);' % (ea_x(ra, rb), rd)
        if xo == 661:
            return 'STSWI(c, %s, %d, c->xer_bc);' % (ea_x(ra, rb), rd)
        if xo == 339:   # mfspr
            spr = ra | (rb << 5)
            if spr == 8:
                return 'R(%d) = c->lr;' % rd
            if spr == 9:
                return 'R(%d) = c->ctr;' % rd
            if spr == 1:
                return 'R(%d) = XER_GET(c);' % rd
            return 'R(%d) = 0;' % rd
        if xo == 467:
            spr = ra | (rb << 5)
            if spr == 8:
                return 'c->lr = R(%d);' % rd
            if spr == 9:
                return 'c->ctr = R(%d);' % rd
            if spr == 1:
                return 'XER_SET(c, R(%d));' % rd
            return ';'
        if xo == 371:
            return 'R(%d) = ppc_timebase(%d);' % (rd, ra | (rb << 5))
        if xo == 19:
            return 'R(%d) = c->cr;' % rd
        if xo == 144:
            fxm = (w >> 12) & 0xff
            m = 0
            for i in range(8):
                if fxm & (0x80 >> i):
                    m |= 0xf0000000 >> (4 * i)
            return 'c->cr = (c->cr & 0x%08xu) | (R(%d) & 0x%08xu);' % ((~m) & 0xffffffff, rd, m)
        if xo == 512:
            return 'SETCRF(%d, (c->so << 3) | (c->ov << 2) | (c->ca << 1)); c->so = c->ov = c->ca = 0;' % (rd >> 2)
        if xo == 1014:
            return 'memset(G((%s) & ~31u), 0, 32);' % ea_x(ra, rb)
        if xo in (54, 86, 246, 278, 470, 598, 982, 854):   # cache, sync, eieio
            return ';'
        if xo == 83:
            return 'R(%d) = 0;' % rd
        if xo == 4:   # tw
            return 'if (TW(%d, R(%d), R(%d))) ppc_trap(c, 0x%08x);' % (rd, ra, rb, a)
        return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (a, w)

    def fp(self, ins, fd, fa, fb, fc, rc, single):
        w, a = ins.w, ins.addr
        xo5 = (w >> 1) & 31
        xo = (w >> 1) & 0x3ff
        rnd = (lambda e: '(double)(float)(%s)' % e) if single else (lambda e: e)
        rec = ' SETCRF(1, FPSCR_CR1(c));' if rc else ''
        A = {21: 'FD(%d) + FD(%d)' % (fa, fb), 20: 'FD(%d) - FD(%d)' % (fa, fb), 25: 'FD(%d) * FD(%d)' % (fa, fc),
             18: 'FD(%d) / FD(%d)' % (fa, fb), 22: 'sqrt(FD(%d))' % fb,
             29: 'fma(FD(%d), FD(%d), FD(%d))' % (fa, fc, fb), 28: 'fma(FD(%d), FD(%d), -FD(%d))' % (fa, fc, fb),
             31: '-fma(FD(%d), FD(%d), FD(%d))' % (fa, fc, fb), 30: '-fma(FD(%d), FD(%d), -FD(%d))' % (fa, fc, fb),
             24: '1.0 / FD(%d)' % fb, 26: '1.0 / sqrt(FD(%d))' % fb}
        if xo5 in A and (single or xo5 not in (24,)):
            return 'FD(%d) = %s;' % (fd, rnd(A[xo5])) + rec
        if xo5 == 23 and not single:
            return 'FD(%d) = FD(%d) >= 0.0 ? FD(%d) : FD(%d);' % (fd, fa, fc, fb) + rec
        if single:
            return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (a, w)
        if xo in (0, 32):
            return 'SETCRF(%d, FCMP(FD(%d), FD(%d)));' % (fd >> 2, fa, fb)
        if xo == 12:
            return 'FD(%d) = (double)(float)FD(%d);' % (fd, fb) + rec
        if xo == 14:
            return 'FU(%d) = 0xfff8000000000000ull | (uint32_t)FCTIW(c, FD(%d), c->fpscr & 3);' % (fd, fb) + rec
        if xo == 15:
            return 'FU(%d) = 0xfff8000000000000ull | (uint32_t)FCTIW(c, FD(%d), 1);' % (fd, fb) + rec
        if xo == 40:
            return 'FU(%d) = FU(%d) ^ 0x8000000000000000ull;' % (fd, fb) + rec
        if xo == 72:
            return 'FU(%d) = FU(%d);' % (fd, fb) + rec
        if xo == 136:
            return 'FU(%d) = FU(%d) | 0x8000000000000000ull;' % (fd, fb) + rec
        if xo == 264:
            return 'FU(%d) = FU(%d) & 0x7fffffffffffffffull;' % (fd, fb) + rec
        if xo == 583:
            return 'FU(%d) = 0xfff8000000000000ull | c->fpscr;' % fd
        if xo == 711:
            fm = (w >> 17) & 0xff
            m = 0
            for i in range(8):
                if fm & (0x80 >> i):
                    m |= 0xf0000000 >> (4 * i)
            return 'c->fpscr = (c->fpscr & 0x%08xu) | ((uint32_t)FU(%d) & 0x%08xu);' % ((~m) & 0xffffffff, fb, m)
        if xo == 134:
            crf = fd >> 2
            imm = (w >> 12) & 15
            sh = 28 - 4 * crf
            return 'c->fpscr = (c->fpscr & ~(0xfu << %d)) | (%du << %d);' % (sh, imm, sh)
        if xo == 38:
            return 'c->fpscr |= 0x80000000u >> %d;' % fd
        if xo == 70:
            return 'c->fpscr &= ~(0x80000000u >> %d);' % fd
        if xo == 64:
            return 'SETCRF(%d, (c->fpscr >> (28 - 4 * %d)) & 15);' % (fd >> 2, fa >> 2)
        return 'ppc_unimpl(c, 0x%08x, 0x%08x);' % (a, w)

    def function(self, f, out):
        name = self.img.names.get(f.start, '')
        if f.resume:
            # a function with catch blocks: a host frame a throw can longjmp back to
            fn = self.fname(f.start)
            out.append('static void B%s(PPC *c);\n// %s\nvoid %s(PPC *c)\n{\n'
                       '\tPPCResume rf;\n\tppc_resume_push(&rf, 0x%08x, c->r[1]);\n'
                       '\t_setjmp(rf.jb);\n\tB%s(c);\n\tppc_resume_pop(&rf);\n}\n'
                       'static void B%s(PPC *c)\n{\n\tPTRACE(0x%08x);\n' % (fn[1:], name, fn, f.start, fn[1:], fn[1:], f.start))
            out.append('\tif (c->resume_pc) {\n\t\tuint32_t t = c->resume_pc;\n\t\tc->resume_pc = 0;\n\t\tswitch (t) {\n')
            for r in f.resume:
                out.append('\t\tcase 0x%08x: goto L_%08x;\n' % (r, r))
            out.append('\t\t}\n\t\tppc_bad_resume(c, t);\n\t}\n')
        else:
            out.append('// %s\nvoid %s(PPC *c)\n{\n\tPTRACE(0x%08x);\n' % (name, self.fname(f.start), f.start))
        addrs = sorted(f.insns)
        prev = None
        for a in addrs:
            ins = f.insns[a]
            if prev is not None and prev + 4 != a:
                # a gap: the previous block must not fall through
                pins = f.insns[prev]
                if pins.fallthrough is True and pins.kind not in ('b',):
                    out.append('\tgoto L_%08x;\n' % (prev + 4))
                    f.labels.add(prev + 4)
            if a in f.labels or a == f.start:
                out.append('L_%08x:\n' % a)
            out.append('\t%s\n' % self.insn(f, ins))
            if ins.fallthrough == 'into':
                out.append('\t%s\n' % self.tail_to(a + 4))
            prev = a
        last = f.insns[addrs[-1]]
        if last.fallthrough is True:
            out.append('\t%s\n' % self.tail_to(addrs[-1] + 4))
        out.append('}\n\n')


def exception_functions(img, starts):
    """CodeWarrior's exception index ends the code section: 12-byte entries
    {function offset, length (bit 31: no table), table offset}. Returns the
    functions with a full table, the ones that can catch."""
    a = img.code_end - 12
    ents = []
    prev = None
    while a >= CODE_BASE:
        off, ln = img.word(a), img.word(a + 4)
        f = CODE_BASE + off
        if f not in starts or (prev is not None and f >= prev) or (ln & 0x7fffffff) == 0:
            break
        ents.append((f, ln))
        prev = f
        a -= 12
    if len(ents) < 4:
        return []
    return [f for f, ln in ents if not ln & 0x80000000]


def main():
    path, outdir = sys.argv[1:3]
    os.makedirs(outdir, exist_ok=True)
    img = Image(path)
    # jump table candidates: relocated words in data that hold code addresses
    codeptrs = {v for a, (k, v) in img.refs.items() if k == 'code'}
    tvec_code = set()
    for a, (k, v) in img.refs.items():
        if k == 'code' and img.refs.get(a + 4, (None,))[0] == 'data' and img.in_code(v):
            tvec_code.add(v)
    starts = set(img.extent) | tvec_code
    starts.add(img.dword(img.main_tv))
    # bl targets (linear sweep: PowerPC code is fixed width)
    for a in range(CODE_BASE, img.code_end, 4):
        w = img.word(a)
        if w >> 26 == 18 and w & 1:
            li = w & 0x03fffffc
            if li & 0x02000000:
                li -= 0x04000000
            t = (li if w & 2 else a + li) & 0xffffffff
            if img.in_code(t):
                starts.add(t)
    starts = {s for s in starts if img.in_code(s)}
    jt = codeptrs - tvec_code
    funcs = {}
    order = sorted(starts)
    for i, s in enumerate(order):
        funcs[s] = Func(img, s, starts, jt, order[i + 1] if i + 1 < len(order) else img.code_end)
    for f in funcs.values():
        f.stack_switch = f.switches_stack()
    nres = 0
    for s in exception_functions(img, starts):
        if s in funcs:
            funcs[s].add_catch_blocks()
            nres += len(funcs[s].resume)
    em = Emitter(img, funcs)
    # import glue names
    for s, f in funcs.items():
        if s in img.names:
            continue
        ws = [img.word(s + 4 * i) for i in range(6)] if s + 24 <= img.code_end else []
        if ws and ws[0] >> 16 == 0x8182:   # lwz r12, off(r2)
            img.names[s] = 'glue'
    names_out = []
    order = sorted(funcs)
    chunk = 250
    hdr = ['#include "ppccode.h"\n']
    for s in order:
        hdr.append('void F_%08x(PPC *c);\n' % s)
    open(os.path.join(outdir, 'funcs.h'), 'w').write(''.join(hdr))
    for n in range(0, len(order), chunk):
        out = ['#include "funcs.h"\n\n']
        for s in order[n:n + chunk]:
            em.function(funcs[s], out)
        p = os.path.join(outdir, 'f%04d.c' % (n // chunk))
        s = ''.join(out)
        if not os.path.exists(p) or open(p).read() != s:
            open(p, 'w').write(s)
    # the image
    blob = bytearray(img.code)
    pad = (DATA_BASE - CODE_BASE) - len(blob)
    assert pad >= 0
    open(os.path.join(outdir, 'code.bin'), 'wb').write(bytes(img.code))
    open(os.path.join(outdir, 'data.bin'), 'wb').write(bytes(img.data))
    t = ['#include "funcs.h"\n#include "ppcrt.h"\n\n']
    t.append('const PPCFunc ppc_funcs[] = {\n')
    for s in order:
        nm = img.names.get(s, '')
        t.append('\t{0x%08x, F_%08x, "%s"},\n' % (s, s, nm.replace('\\', '\\\\').replace('"', '\\"')))
    t.append('};\nconst size_t ppc_nfuncs = %d;\n' % len(order))
    t.append('const char *const ppc_import_names[] = {\n')
    for nm, cl in img.imports:
        t.append('\t"%s",\n' % nm)
    t.append('};\nconst unsigned char ppc_import_class[] = {%s};\n' % ', '.join(str(cl) for nm, cl in img.imports))
    t.append('const size_t ppc_nimports = %d;\n' % len(img.imports))
    t.append('const uint32_t ppc_main_tv = 0x%08x;\n' % img.main_tv)
    t.append('const uint32_t ppc_code_size = 0x%x, ppc_data_size = 0x%x;\n' % (len(img.code), len(img.data)))
    open(os.path.join(outdir, 'image.c'), 'w').write(''.join(t))
    open(os.path.join(outdir, 'blob.S'), 'w').write(
        '\t.section __DATA,__ppcimg\n\t.globl _ppc_code_bin\n\t.p2align 4\n_ppc_code_bin:\n\t.incbin "%s"\n'
        '\t.globl _ppc_data_bin\n\t.p2align 4\n_ppc_data_bin:\n\t.incbin "%s"\n' % (
            os.path.abspath(os.path.join(outdir, 'code.bin')), os.path.abspath(os.path.join(outdir, 'data.bin'))))
    nb = sum(len(f.bctr_targets) for f in funcs.values())
    print('%d functions (%d named), %d imports, %d bctr sites with jump tables, %d catch blocks in %d functions' % (
        len(funcs), len(img.names), len(img.imports), sum(1 for f in funcs.values() for v in f.bctr_targets.values() if v),
        nres, sum(1 for f in funcs.values() if f.resume)))
    unimpl = {}
    for f in funcs.values():
        for ins in f.insns.values():
            s = em.insn(f, ins)
            if 'ppc_unimpl' in s:
                key = (ins.op, (ins.w >> 1) & 0x3ff)
                unimpl[key] = unimpl.get(key, 0) + 1
    if unimpl:
        print('%d undecodable words (data reached only through bogus seeds)' % sum(unimpl.values()))


if __name__ == '__main__':
    main()
