#!/usr/bin/env python3
"""Builds xlate/rt/sdkdb.c from a clang text AST dump of the SDK headers
(tools/sdk_all.m): for every C function and Objective-C method, its return
and parameter types in the bridge's type language, which says what each
value is in the i386 guest and on the host.

  v void          c/C int8   s/S int16   i/I int32   q/Q int64
  l/L long (32-bit in the guest, 64-bit on the host: long, NSInteger, size_t, CFIndex)
  f float         d double    F CGFloat (float in the guest, double on the host)
  B bool (_Bool)
  @ object or opaque reference (id, Class, CF types, opaque struct pointers): a handle
  : SEL           * pointer to bytes (same layout both sides)
  P<t> pointer to a value of type t that needs converting (id *, CGFloat *, NSRect *, ...)
  {Name} struct by value (layout in the struct table)
  ^ function pointer (callback)   ? unknown

usage: sdkdb.py <ast.txt> <out.c>
"""
import re
import sys

ast_path, out_path = sys.argv[1:3]

QUAL = re.compile(r'\b(const|volatile|restrict|__restrict|_Nullable|_Nonnull|_Null_unspecified|__strong|__weak|'
                  r'__unsafe_unretained|__autoreleasing|__kindof|_Nullable_result|__unused)\b')
TYPES = re.compile(r"'([^']*)'(?::'([^']*)')?")

structs = {}        # name -> list of (field spelled, canonical)
defined = set()     # struct names with a definition
enums = {}          # enum name -> underlying canonical type
typedefs = {}       # typedef name -> canonical


def norm(t):
    t = QUAL.sub('', t)
    t = re.sub(r'\s+', ' ', t).strip()
    t = t.replace(' *', '*').replace('* ', '*')
    return t


KEEP = {'id', 'Class', 'SEL', 'CGFloat'}


GENERIC = re.compile(r'^(ObjectType|KeyType|ValueType|ElementType|SectionIdentifierType|ItemIdentifierType|'
                     r'ResultType|AnchorType|UnitType|ContentType|ObjectTypeA|\w+Type)(\**)$')


def resolve(t):
    """canonical spelling through typedefs; whether CGFloat was on the way"""
    t = norm(t)
    g = GENERIC.match(t)
    if g and g.group(1) not in typedefs and g.group(1) not in structs:
        return 'id' + g.group(2), False
    cg = 'CGFloat' in t
    for _ in range(8):
        m = re.match(r'^(\w+)(\**)$', t)
        if not m or m.group(1) in KEEP or m.group(1) not in typedefs:
            break
        t = norm(typedefs[m.group(1)]) + m.group(2)
        cg = cg or 'CGFloat' in t
    if re.match(r'^CGFloat(\**)$', t):
        t = 'double' + t[7:]
        cg = True
    return t, cg


def classify(spelled, canon, depth=0):
    if norm(spelled or '') == 'SEL':
        return ':'
    if norm(spelled or '') == 'SEL*':
        return 'P:'
    c, cg = resolve(canon or spelled)
    s = norm(spelled) + (' CGFloat' if cg else '')
    if depth > 4:
        return '?'
    if c in ('void',):
        return 'v'
    if '(^' in c:
        return '@'         # block: an object
    if '(*' in c or c.endswith(')') and '(' in c and '*' not in c:
        return '^'
    if c.startswith('enum '):
        u = enums.get(c[5:])
        return classify(u or 'int', u or 'int', depth + 1)
    base = {'int': 'i', 'unsigned int': 'I', 'short': 's', 'unsigned short': 'S', 'char': 'c', 'signed char': 'c',
            'unsigned char': 'C', '_Bool': 'B', 'bool': 'B', 'long': 'l', 'unsigned long': 'L', 'long long': 'q',
            'unsigned long long': 'Q', 'float': 'f', '__int128': 'q', 'long double': 'd'}
    if c in base:
        return base[c]
    if c == 'double':
        return 'F' if 'CGFloat' in s else 'd'
    if c in ('SEL',):
        return ':'
    if c in ('id', 'Class') or c.startswith('id<') or c.startswith('Class<'):
        return '@'
    if c.endswith('*'):
        p = c[:-1].strip()
        ps = s[:-1].strip() if s.endswith('*') else ''
        if p in ('char', 'unsigned char', 'signed char', 'void', 'short', 'unsigned short', 'int', 'unsigned int',
                 'float', 'double', 'long long', 'unsigned long long', '_Bool', 'wchar_t'):
            if p == 'double' and ('CGFloat' in ps or cg):
                return 'PF'
            return '*'
        if p in ('id', 'Class') or p.startswith('id<'):
            return 'P@'
        rp, rcg = resolve(p)
        if rp != p:
            k = classify(ps or p, p, depth + 1)
            if k in ('c', 'C', 's', 'S', 'i', 'I', 'q', 'Q', 'f', 'd', 'B'):
                return '*'
            if k.startswith('{'):
                return '*' if struct_code(k[1:-1], depth + 1) == '*' else 'P' + k
            if k in ('@',) and rp.endswith('*'):
                return 'P@'
            return 'P' + k if k not in ('?', '*', '^') else ('P@' if k == '^' else '*')
        if re.match(r'^[A-Z_a-z]\w*\s*(<.*>)?$', p) and not p.startswith('struct ') and not p.startswith('union ') \
                and p not in base and not p.startswith('enum '):
            return '@'     # ObjC class pointer (NSString *)
        if p.startswith('struct ') or p.startswith('union '):
            nm = p.split(' ', 1)[1]
            if nm in defined:
                f = struct_code(nm, depth + 1)
                return '*' if f == '*' else 'P{%s}' % nm
            return '@'     # opaque: CF types, CGContext, ...
        if p in ('long', 'unsigned long'):
            return 'Pl'
        if p in ('SEL',):
            return 'P:'
        if p in ('id', 'Class') or p.endswith('*') or p.startswith('id<'):
            inner = classify(ps or p, p, depth + 1)
            return 'P' + inner if inner in ('@', '*') else 'P' + inner
        if p.startswith('enum '):
            inner = classify(p, p, depth + 1)
            return '*' if inner in 'cCsSiIqQfdB' else 'P' + inner
        return '*'
    if c.startswith('struct ') or c.startswith('union '):
        nm = c.split(' ', 1)[1]
        return '{%s}' % nm
    if c.endswith(']'):
        return '*'
    return '?'


def struct_code(nm, depth=0):
    """'*' when the struct has the same layout in the guest and on the host"""
    fs = structs.get(nm)
    if not fs or depth > 4:
        return '*'
    for sp, cn in fs:
        k = classify(sp, cn, depth + 1)
        if k in ('l', 'L', 'F', '@', ':', '^', '?') or k.startswith('P') or k.startswith('{') and struct_code(k[1:-1], depth + 1) != '*':
            return 'x'
        if k == '*' and norm(cn).endswith('*'):
            return 'x'      # a pointer: 4 bytes in the guest
    return '*'


lines = open(ast_path, encoding='utf-8', errors='replace').read().split('\n')


def depth_of(line):
    m = re.match(r'^[| `]*[|`]-', line)
    return len(m.group(0)) // 2 if m else 0


# pass 1: records, enums, typedefs
cur_rec = None
rec_depth = 0
anon_n = 0
last_anon = None
for ln in lines:
    d = depth_of(ln)
    body = ln[d * 2:] if d else ln
    if cur_rec is not None and d <= rec_depth:
        cur_rec = None
    m = re.search(r'RecordDecl 0x[0-9a-f]+ .* (struct|union)(?: (\w+))? definition$', body)
    if m:
        if m.group(2):
            cur_rec = m.group(2)
        else:
            anon_n += 1
            cur_rec = last_anon = '__anon%d' % anon_n
        rec_depth = d
        defined.add(cur_rec)
        structs[cur_rec] = []
        continue
    if cur_rec is not None and 'FieldDecl' in body and d == rec_depth + 1:
        t = TYPES.findall(body)
        if t:
            structs[cur_rec].append((t[-1][0], t[-1][1] or t[-1][0]))
        continue
    m = re.search(r"EnumDecl 0x[0-9a-f]+ .* (\w+) '([^']*)'(?::'([^']*)')?$", body)
    if m:
        enums[m.group(1)] = m.group(3) or m.group(2)
        continue
    m = re.search(r"TypedefDecl 0x[0-9a-f]+ .* (\w+) '([^']*)'(?::'([^']*)')?$", body)
    if m:
        tgt = m.group(3) if m.group(3) and norm(m.group(3)) != m.group(1) else m.group(2)
        typedefs[m.group(1)] = tgt
        # an anonymous struct typedef: struct name from the canonical type
        cn = norm(tgt)
        if cn.startswith('struct ') and cn[7:] in structs and m.group(1) not in structs:
            structs[m.group(1)] = structs[cn[7:]]
            defined.add(m.group(1))
        elif cn.startswith('struct ') and m.group(1) not in structs and last_anon and cn[7:] == m.group(1):
            structs[m.group(1)] = structs[last_anon]
            defined.add(m.group(1))
            last_anon = None

# pass 2: functions and methods
funcs = {}
methods = []    # (container, kind, selector, types, variadic)
container = None
cont_depth = 0
cur = None      # (kind, name, ret, params, variadic, container) being collected
cur_depth = 0


def finish():
    global cur
    if cur is None:
        return
    kind, name, ret, params, variadic, cont = cur
    sig = '|'.join([ret] + params)
    if kind == 'F':
        funcs.setdefault(name, (sig, variadic))
    else:
        methods.append((cont, kind, name, sig, variadic))
    cur = None


for ln in lines:
    d = depth_of(ln)
    body = ln[d * 2:] if d else ln
    if cur is not None and d <= cur_depth:
        finish()
    if container is not None and d <= cont_depth:
        container = None
    m = re.search(r'ObjC(Interface|Protocol|Category)Decl 0x[0-9a-f]+ .*? (\w+)$', body)
    if m and d <= 1:
        container = m.group(2)
        if m.group(1) == 'Category':
            # the category's class is on a child line; keep the category name
            pass
        cont_depth = d
        continue
    if container is not None and body.startswith('ObjCInterface ') and d == cont_depth + 1:
        mm = re.search(r"'(\w+)'", body)
        if mm:
            container = mm.group(1)
        continue
    m = re.search(r"ObjCMethodDecl 0x[0-9a-f]+ .* ([-+]) ([\w:]+) '([^']*)'(?::'([^']*)')?( variadic)?", body)
    if m and container is not None:
        finish()
        ret = classify(m.group(3), m.group(4) or m.group(3))
        cur = (m.group(1), m.group(2), ret, [], bool(m.group(5)), container)
        cur_depth = d
        continue
    m = re.search(r"FunctionDecl 0x[0-9a-f]+ .*? (\w+) '([^']*)'(?::'([^']*)')?", body)
    if m and d <= 1:
        finish()
        ft = m.group(2)
        rm = re.match(r'^(.*?)\s*\((.*)\)\s*$', ft)
        rets = rm.group(1) if rm else ft
        cft = m.group(3) or ft
        crm = re.match(r'^(.*?)\s*\((.*)\)\s*$', cft)
        retc = crm.group(1) if crm else rets
        cur = ('F', m.group(1), classify(rets, retc), [], '...' in ft, None)
        cur_depth = d
        continue
    if cur is not None and 'ParmVarDecl' in body and d == cur_depth + 1:
        t = TYPES.findall(body)
        if t:
            cur[3].append(classify(t[-1][0], t[-1][1] or t[-1][0]))
finish()

# struct table: only structs used by value or through P{...}
used = set()
for sig, _ in funcs.values():
    used.update(re.findall(r'\{(\w+)\}', sig))
for _, _, _, sig, _ in methods:
    used.update(re.findall(r'\{(\w+)\}', sig))
todo = list(used)
while todo:
    nm = todo.pop()
    for sp, cn in structs.get(nm, []):
        k = classify(sp, cn)
        for inner in re.findall(r'\{(\w+)\}', k):
            if inner not in used:
                used.add(inner)
                todo.append(inner)


def cstr(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')


out = ['// Generated by tools/sdkdb.py from the SDK headers; see the type language there.',
       '#include "sdkdb.h"', '', 'const XLFuncType xl_sdk_funcs[] = {']
for name in sorted(funcs):
    sig, var = funcs[name]
    out.append('\t{%s, %s, %d},' % (cstr('_' + name), cstr(sig), 1 if var else 0))
out.append('\t{0}\n};')
out.append('const size_t xl_sdk_nfuncs = %d;' % len(funcs))
methods.sort(key=lambda x: (x[2], x[0]))
out.append('const XLMethodType xl_sdk_methods[] = {')
for cont, kind, sel, sig, var in methods:
    out.append('\t{%s, %s, %s, %d},' % (cstr(sel), cstr(cont), cstr(kind + sig), 1 if var else 0))
out.append('\t{0}\n};')
out.append('const size_t xl_sdk_nmethods = %d;' % len(methods))
out.append('const XLStructType xl_sdk_structs[] = {')
nst = 0
for nm in sorted(used):
    fs = structs.get(nm)
    if fs is None:
        continue
    nst += 1
    out.append('\t{%s, %s},' % (cstr(nm), cstr('|'.join(classify(sp, cn) for sp, cn in fs))))
out.append('\t{0}\n};')
out.append('const size_t xl_sdk_nstructs = %d;' % nst)
open(out_path, 'w').write('\n'.join(out) + '\n')
print('%d functions, %d methods, %d structs' % (len(funcs), len(methods), len(used)))
