// Objective-C 1 metadata of the translated images, registered with the
// modern runtime; handles for objects; closures for translated methods.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include "rt.h"
#include <dlfcn.h>
#include <ctype.h>
#include <ffi/ffi.h>

// ---- selectors ---------------------------------------------------------------------
static XLMap g2sel, sel2g, selname;   // guest -> SEL, SEL -> guest, name hash -> guest

static uint64_t namehash(const char *s)
{
	uint64_t h = 1469598103934665603ULL;
	while (*s)
		h = (h ^ (uint8_t)*s++) * 1099511628211ULL;
	return h | 1;
}

SEL xl_hsel(uint32_t g)
{
	SEL s = (SEL)xl_map_get(&g2sel, g);
	if (s)
		return s;
	const char *nm = GP(g);
	s = sel_registerName(nm);
	xl_map_put(&g2sel, g, (uint64_t)s);
	if (!xl_map_get(&sel2g, (uint64_t)s))
		xl_map_put(&sel2g, (uint64_t)s, g);
	return s;
}

uint32_t xl_gsel(SEL s)
{
	uint32_t g = (uint32_t)xl_map_get(&sel2g, (uint64_t)s);
	if (g)
		return g;
	const char *nm = sel_getName(s);
	g = (uint32_t)xl_map_get(&selname, namehash(nm));
	if (!g || strcmp(GP(g), nm)) {
		g = xl_strdup(nm);
		xl_map_put(&selname, namehash(nm), g);
	}
	xl_map_put(&sel2g, (uint64_t)s, g);
	xl_map_put(&g2sel, g, (uint64_t)s);
	return g;
}

// canonical guest address for a selector name (first one seen wins)
static uint32_t canon_sel(uint32_t g)
{
	const char *nm = GP(g);
	uint64_t h = namehash(nm);
	uint32_t c = (uint32_t)xl_map_get(&selname, h);
	if (c && !strcmp(GP(c), nm))
		return c;
	if (!c)
		xl_map_put(&selname, h, g);
	xl_hsel(g);
	return c ? c : g;
}

// ---- guest classes -------------------------------------------------------------------
typedef struct GClass {
	uint32_t addr;       // objc1 class struct (the class handle)
	const char *name;
	Class host, hmeta;
	uint32_t isize;
	int done;
	XLImage *img;
} GClass;

static GClass *gclasses;
static int ngclasses, capgclasses;
static XLMap class_by_name;   // name hash -> GClass index + 1
static XLMap ginfo;           // host Class (and metaclass) -> GClass *

bool xl_is_guest_class(Class c)
{
	return xl_map_get(&ginfo, (uint64_t)c) != 0;
}

static GClass *gclass_named(const char *nm)
{
	uint64_t i = xl_map_get(&class_by_name, namehash(nm));
	return i ? &gclasses[i - 1] : NULL;
}

// ---- object handles ---------------------------------------------------------------------
static XLMap p2h_obj;   // translated instances: host -> shadow handle
static char assoc_key;

@interface XLShadowOwner : NSObject {
@public
	uint32_t h;
	void *obj;
}
@end
@implementation XLShadowOwner
- (void)dealloc
{
	if (xl_verbose > 1)
		xl_log("shadow %08x freed (%s)", h, obj ? class_getName(object_getClass((id)obj)) : "?");
	xl_map_del(&p2h_obj, (uint64_t)obj);
	xl_free(h - 8);
	[super dealloc];
}
@end

static uint32_t make_shadow(id o, GClass *g)
{
	uint32_t size = g->isize < 4 ? 4 : g->isize;
	uint32_t h = xl_cell(o, size);
	*(uint32_t *)GP(h) = g->addr;      // isa
	xl_map_put(&p2h_obj, (uint64_t)o, h);
	XLShadowOwner *own = [XLShadowOwner new];
	own->h = h;
	own->obj = o;
	objc_setAssociatedObject(o, &assoc_key, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[own release];
	return h;
}

uint32_t xl_hobj(id o)
{
	if (!o)
		return 0;
	uint32_t h = (uint32_t)xl_map_get(&p2h_obj, (uint64_t)o);
	if (h)
		return h;
	// opaque references typed like objects (AUGraph, AudioUnit, ...) need not
	// point at anything: nothing lives below 4 GB on arm64 and objects are aligned
	if (!((uintptr_t)o & (1UL << 63)) && !((uintptr_t)o & 7) && (uintptr_t)o >= 0x100000000ull) {
		Class cls = object_getClass(o);
		GClass *g = (GClass *)xl_map_get(&ginfo, (uint64_t)cls);
		if (g) {
			if (cls == g->hmeta)      // o is the translated class itself
				return g->addr;
			return make_shadow(o, g);
		}
		// a translated metaclass
		g = (GClass *)xl_map_get(&ginfo, (uint64_t)o);
		if (g)
			return o == (id)g->host ? g->addr : *(uint32_t *)GP(g->addr);
	}
	return xl_h(o);
}

Class xl_hclass(uint32_t h)
{
	return (Class)xl_p(h);
}

// ---- type encodings -----------------------------------------------------------------------
// guest (i386) objc type encoding -> bridge type
static const char *skip_quals(const char *s)
{
	while (*s && strchr("rnNoORV", *s))
		s++;
	return s;
}

static const char *skip_digits(const char *s)
{
	while (*s == '-' || (*s >= '0' && *s <= '9'))
		s++;
	return s;
}

static const char *skip_enc(const char *s)
{
	s = skip_quals(s);
	switch (*s) {
	case '{': case '(': {
		char open = *s, close = open == '{' ? '}' : ')';
		int d = 0;
		do {
			if (*s == open)
				d++;
			else if (*s == close)
				d--;
			s++;
		} while (d && *s);
		return s;
	}
	case '[': {
		int d = 0;
		do {
			if (*s == '[')
				d++;
			else if (*s == ']')
				d--;
			s++;
		} while (d && *s);
		return s;
	}
	case '^':
		return skip_enc(s + 1);
	case 'b':
		return skip_digits(s + 1);
	case '@':
		if (s[1] == '"') {
			const char *e = strchr(s + 2, '"');
			return e ? e + 1 : s + 1;
		}
		if (s[1] == '?')
			return s + 2;
		return s + 1;
	default:
		return *s ? s + 1 : s;
	}
}

static const char *skip_enc(const char *s);
static XLType *enc_type(const char *s)
{
	s = skip_quals(s);
	const char *k = NULL;
	switch (*s) {
	case 'c': k = "c"; break;
	case 'C': k = "C"; break;
	case 'B': k = "B"; break;
	case 's': k = "s"; break;
	case 'S': k = "S"; break;
	case 'i': case 'l': k = "i"; break;
	case 'I': case 'L': k = "I"; break;
	case 'q': k = "q"; break;
	case 'Q': k = "Q"; break;
	case 'f': k = "f"; break;
	case 'd': k = "d"; break;
	case 'v': k = "v"; break;
	case '@': case '#': k = "@"; break;
	case ':': k = ":"; break;
	case '*': k = "*"; break;
	case '^':
		if (s[1] == '@')
			k = "P@";
		else
			k = "*";
		break;
	case '{': {
		const char *e = s + 1;
		while (*e && *e != '=' && *e != '}')
			e++;
		size_t n = (size_t)(e - s - 1);
		char nm[64];
		if (n > 63)
			n = 63;
		memcpy(nm, s + 1, n);
		nm[n] = 0;
		const char *map = nm;
		if (!strcmp(nm, "_NSRect") || !strcmp(nm, "NSRect"))
			map = "CGRect";
		else if (!strcmp(nm, "_NSPoint") || !strcmp(nm, "NSPoint"))
			map = "CGPoint";
		else if (!strcmp(nm, "_NSSize") || !strcmp(nm, "NSSize"))
			map = "CGSize";
		else if (!strcmp(nm, "NSRange"))
			map = "_NSRange";
		XLType *t = strcmp(map, "?") ? xl_type_struct(map) : NULL;
		if (t)
			return t;
		// build it from the encoding's own fields (guest view of every field)
		XLType *f[64];
		int nf = 0;
		if (*e == '=') {
			const char *q = e + 1;
			while (*q && *q != '}' && nf < 64) {
				if (*q == '"') {        // field name
					q = strchr(q + 1, '"');
					if (!q)
						break;
					q++;
					continue;
				}
				f[nf++] = enc_type(q);
				q = skip_enc(q);
			}
		}
		return xl_type_fields(nm, f, nf);
	}
	case '[': {
		// fixed array: as many copies of the element
		int cnt = atoi(s + 1);
		const char *q = s + 1;
		while (*q >= '0' && *q <= '9')
			q++;
		XLType *el = enc_type(q);
		XLType *f[64];
		if (cnt > 64)
			cnt = 64;
		for (int i = 0; i < cnt; i++)
			f[i] = el;
		return xl_type_fields("[]", f, cnt);
	}
	default: k = "I"; break;
	}
	const char *p = k;
	return xl_type_parse(&p);
}

// split an objc method encoding into ret + args (self and _cmd included)
static int enc_split(const char *enc, XLType **out, int max)
{
	int n = 0;
	const char *s = enc;
	while (*s && n < max) {
		out[n++] = enc_type(s);
		s = skip_enc(s);
		s = skip_digits(s);
	}
	return n;
}

// SDK signatures that say void * for what is a CF object: a CGContextRef
// crosses as an object handle, not as a pointer into the guest window
static const XLMethodType sdk_fixes[] = {
	{"graphicsPort", "NSGraphicsContext", "-@", 0},
	{"graphicsContextWithGraphicsPort:flipped:", "NSGraphicsContext", "+@|@|B", 0},
};

// the SDK signature for a selector, preferring entries declared on cls or its protocols
const XLMethodType *xl_sdk_method(SEL sel, Class cls, int meta)
{
	const char *nm = sel_getName(sel);
	for (size_t i = 0; i < sizeof sdk_fixes / sizeof *sdk_fixes; i++)
		if (!strcmp(sdk_fixes[i].sel, nm) && sdk_fixes[i].type[0] == (meta ? '+' : '-'))
			return &sdk_fixes[i];
	size_t lo = 0, hi = xl_sdk_nmethods;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		if (strcmp(xl_sdk_methods[mid].sel, nm) < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	if (lo >= xl_sdk_nmethods || strcmp(xl_sdk_methods[lo].sel, nm))
		return NULL;
	size_t first = lo, last = lo;
	while (last + 1 < xl_sdk_nmethods && !strcmp(xl_sdk_methods[last + 1].sel, nm))
		last++;
	char want = meta ? '+' : '-';
	for (Class c = cls; c; c = class_getSuperclass(c)) {
		const char *cn = class_getName(c);
		for (size_t i = first; i <= last; i++)
			if (xl_sdk_methods[i].type[0] == want && !strcmp(xl_sdk_methods[i].container, cn))
				return &xl_sdk_methods[i];
	}
	if (cls)
		for (size_t i = first; i <= last; i++) {
			Protocol *p = objc_getProtocol(xl_sdk_methods[i].container);
			if (p && xl_sdk_methods[i].type[0] == want && class_conformsToProtocol(cls, p))
				return &xl_sdk_methods[i];
		}
	for (size_t i = first; i <= last; i++)
		if (xl_sdk_methods[i].type[0] == want)
			return &xl_sdk_methods[i];
	return &xl_sdk_methods[first];
}

// bridge signature for a method: t[0] ret, t[1] self, t[2] _cmd, t[3..] args
int xl_method_sig(SEL sel, Class cls, int meta, const char *guest_enc, XLType **t, int max, int *variadic)
{
	static XLType *tself, *tcmd;
	if (!tself) {
		const char *a = "@", *b = ":";
		tself = xl_type_parse(&a);
		tcmd = xl_type_parse(&b);
	}
	XLType *sdk[32];
	int ns = 0;
	const XLMethodType *mt = xl_sdk_method(sel, cls, meta);
	if (variadic)
		*variadic = mt ? mt->variadic : 0;
	if (mt)
		ns = xl_sig_split(mt->type, sdk, 32);
	int nargs = 0;
	for (const char *s = sel_getName(sel); *s; s++)
		nargs += *s == ':';
	if (guest_enc) {
		XLType *g[32];
		int ng = enc_split(guest_enc, g, 32);
		if (ng < 3)
			return 0;
		int ok = ns == ng - 2;
		t[0] = g[0];
		if (ok && sdk[0]->gsize == g[0]->gsize && (g[0]->kind != '{' || sdk[0]->kind == '{'))
			t[0] = sdk[0];
		t[1] = tself;
		t[2] = tcmd;
		for (int i = 3; i < ng && i < max; i++) {
			t[i] = g[i];
			if (ok && sdk[i - 2]->gsize == g[i]->gsize && (g[i]->kind != '{' || sdk[i - 2]->kind == '{'))
				t[i] = sdk[i - 2];
		}
		// a guest override of a method the SDK does not declare (a private
		// one): pointers take the host method's pointee widths
		Method hm = !mt && cls ? (meta ? class_getClassMethod(class_getSuperclass(cls), sel)
			: class_getInstanceMethod(class_getSuperclass(cls), sel)) : NULL;
		if (hm && !xl_in_window((void *)method_getImplementation(hm)) && method_getNumberOfArguments(hm) == (unsigned)ng - 1) {
			for (int i = 3; i < ng && i < max; i++) {
				if (g[i]->kind != '*')
					continue;
				char a[256];
				method_getArgumentType(hm, (unsigned)i - 1, a, sizeof a);
				XLType *h = xl_from_host_enc(a);
				if (h->kind == 'P')
					t[i] = h;
				if (xl_verbose > 1)
					xl_log("  %s arg %d: host %s -> %c", sel_getName(sel), i - 3, a, t[i]->kind);
			}
		}
		return ng;
	}
	if (mt && ns == nargs + 1) {
		t[0] = sdk[0];
		t[1] = tself;
		t[2] = tcmd;
		for (int i = 1; i < ns && i + 2 < max; i++)
			t[i + 2] = sdk[i];
		return ns + 2;
	}
	return -1;
}

static void host_enc(XLType *t, char *out, size_t n)
{
	const char *k;
	switch (t->kind) {
	case 'l': k = "q"; break;
	case 'L': k = "Q"; break;
	case 'F': k = "d"; break;
	case 'P':
		// keep the pointee: the encoding is read back for super calls
		if (t->sub && strchr("lLF@{", t->sub->kind) && n > 1) {
			out[0] = '^';
			host_enc(t->sub, out + 1, n - 1);
			return;
		}
		k = "^v";
		break;
	case 'p': case 'h': k = "^v"; break;
	case '^': k = "^?"; break;
	case '{': {
		size_t o = (size_t)snprintf(out, n, "{%s=", t->name);
		for (int i = 0; i < t->nfields && o < n; i++)
			host_enc(t->fields[i], out + o, n - o), o += strlen(out + o);
		if (o + 2 < n)
			strcat(out, "}");
		return;
	}
	default: {
		static char one[2];
		one[0] = t->kind;
		k = one;
		snprintf(out, n, "%c", t->kind);
		return;
	}
	}
	snprintf(out, n, "%s", k);
}

// ---- closures: host calls a translated method ------------------------------------------------
typedef struct XLMeth {
	uint32_t guest;
	int n;               // types incl. return
	XLType *t[32];
	ffi_cif cif;
	ffi_type *ft[32];
	ffi_closure *closure;
	void *code;
} XLMeth;

static XLMap imp2meth;

uint32_t xl_guest_imp_of(IMP imp)
{
	XLMeth *m = (XLMeth *)xl_map_get(&imp2meth, (uint64_t)imp);
	return m ? m->guest : 0;
}

static int guest_mem_ret(XLType *r)
{
	return r->kind == '{' && !(r->gsize == 1 || r->gsize == 2 || r->gsize == 4 || r->gsize == 8);
}

// host value -> guest return registers
static void ret_from_guest(XLType *r, XLResult *res, uint32_t sret, void *out)
{
	switch (r->kind) {
	case 'v': break;
	case 'c': *(ffi_sarg *)out = (int8_t)res->eax; break;
	case 'C': case 'B': *(ffi_arg *)out = (uint8_t)res->eax; break;
	case 's': *(ffi_sarg *)out = (int16_t)res->eax; break;
	case 'S': *(ffi_arg *)out = (uint16_t)res->eax; break;
	case 'i': *(ffi_sarg *)out = (int32_t)res->eax; break;
	case 'I': *(ffi_arg *)out = res->eax; break;
	case 'l': *(int64_t *)out = (int32_t)res->eax; break;
	case 'L': *(uint64_t *)out = res->eax; break;
	case 'q': case 'Q': *(uint64_t *)out = res->eax | (uint64_t)res->edx << 32; break;
	case 'f': *(float *)out = (float)res->st0; break;
	case 'd': case 'F': *(double *)out = res->st0; break;
	case '@': case 'p': case 'h': *(void **)out = xl_p(res->eax); break;
	case ':': *(SEL *)out = res->eax ? xl_hsel(res->eax) : NULL; break;
	case '*': case 'P': *(void **)out = res->eax ? GP(res->eax) : NULL; break;
	case '^': *(void **)out = NULL; break;
	case '{':
		if (sret) {
			xl_g2h(r, sret, out);
		} else {
			XLCPU *c = xl_cpu();
			uint32_t tmp = c->r[ESP] - 128;
			*(uint32_t *)GP(tmp) = res->eax;
			*(uint32_t *)GP(tmp + 4) = res->edx;
			xl_g2h(r, tmp, out);
		}
		break;
	}
}

static void closure_entry(ffi_cif *cif, void *ret, void **args, void *ud)
{
	XLMeth *m = ud;
	XLCPU *c = xl_cpu();
	XLType *rt = m->t[0];
	int mem = guest_mem_ret(rt);
	uint32_t nbytes = mem ? 4 : 0;
	for (int i = 1; i < m->n; i++)
		nbytes += (m->t[i]->gsize + 3) & ~3u;
	uint32_t sret = mem ? xl_malloc(rt->gsize) : 0;
	uint32_t sp = xl_guest_frame(c, nbytes), o = sp;
	if (mem) {
		*(uint32_t *)GP(o) = sret;
		o += 4;
	}
	// pointers to values whose width differs (NSUInteger *, NSPoint *, id *)
	// point at guest copies, written back after the call
	uint32_t tmp[32] = {0};
	for (int i = 1; i < m->n; i++) {
		XLType *t = m->t[i];
		void *hp = t->kind == 'P' ? *(void **)args[i - 1] : NULL;
		if (hp && t->sub && strchr("lLF@{", t->sub->kind) && !xl_in_window(hp)) {
			tmp[i] = xl_malloc(t->sub->gsize);
			xl_h2g(t->sub, hp, tmp[i]);
			*(uint32_t *)GP(o) = tmp[i];
		} else
			xl_h2g(t, args[i - 1], o);
		o += (t->gsize + 3) & ~3u;
	}
	if (xl_verbose > 3)
		xl_log("-> %s", xl_name_at(m->guest));
	XLResult res;
	xl_guest_run(c, m->guest, sp, &res);
	for (int i = 1; i < m->n; i++)
		if (tmp[i]) {
			xl_g2h(m->t[i]->sub, tmp[i], *(void **)args[i - 1]);
			xl_free(tmp[i]);
		}
	ret_from_guest(rt, &res, sret, ret);
	if (sret)
		xl_free(sret);
}

static IMP make_closure(uint32_t guest, XLType **t, int n)
{
	XLMeth *m = calloc(1, sizeof *m);
	m->guest = guest;
	m->n = n;
	for (int i = 0; i < n; i++) {
		m->t[i] = t[i];
		m->ft[i] = t[i]->ffi;
	}
	if (ffi_prep_cif(&m->cif, FFI_DEFAULT_ABI, n - 1, m->ft[0], m->ft + 1) != FFI_OK)
		xl_die("ffi_prep_cif failed for %s", xl_name_at(guest));
	m->closure = ffi_closure_alloc(sizeof(ffi_closure), &m->code);
	if (ffi_prep_closure_loc(m->closure, &m->cif, closure_entry, m, m->code) != FFI_OK)
		xl_die("ffi closure failed");
	xl_map_put(&imp2meth, (uint64_t)m->code, (uint64_t)m);
	return (IMP)m->code;
}

// generic closure for a guest function pointer called by host code with a known signature
void *xl_closure_for(uint32_t guest, const char *sig)
{
	XLType *t[32];
	int n = xl_sig_split(sig, t, 32);
	return (void *)make_closure(guest, t, n);
}

// Guest categories on Foundation classes add what later systems have (firstObject,
// containsString:, ...) or helpers. Where the host class already implements the
// method, its version stays: host code calls it too (CFSetGetValues calls
// -getObjects:) and expects host conventions.
static int host_keeps(Class target, SEL sel)
{
	Class cls = class_isMetaClass(target) ? objc_getClass(class_getName(target)) : target;
	const char *img = cls ? class_getImageName(cls) : NULL;
	if (!img || cls == [NSObject class] || (!strstr(img, "/Foundation.framework/") && !strstr(img, "/CoreFoundation.framework/")))
		return 0;     // NSObject's overrides are deliberate; other classes' are their own
	Method m = class_getInstanceMethod(target, sel);
	if (!m || xl_map_get(&imp2meth, (uint64_t)method_getImplementation(m)))
		return 0;
	Dl_info di;
	if (!dladdr((void *)method_getImplementation(m), &di) || !di.dli_fname)
		return 0;
	return strstr(di.dli_fname, "/Foundation.framework/") || strstr(di.dli_fname, "/CoreFoundation.framework/");
}

static void add_methods(Class cls, int meta, uint32_t list, int replace)
{
	if (!list)
		return;
	int cnt = *(int32_t *)GP(list + 4);
	for (int i = 0; i < cnt; i++) {
		uint32_t e = list + 8 + 12 * i;
		uint32_t name = *(uint32_t *)GP(e), types = *(uint32_t *)GP(e + 4), imp = *(uint32_t *)GP(e + 8);
		uint32_t cname = canon_sel(name);
		*(uint32_t *)GP(e) = cname;
		SEL sel = xl_hsel(cname);
		XLType *t[32];
		int n = xl_method_sig(sel, meta ? cls : cls, meta, GP(types), t, 32, NULL);
		if (n < 3) {
			xl_log("bad method encoding %s %s", sel_getName(sel), (char *)GP(types));
			continue;
		}
		char enc[512] = "", one[256];
		for (int k = 0; k < n; k++) {
			host_enc(t[k], one, sizeof one);
			strlcat(enc, one, sizeof enc);
		}
		Class target = meta ? object_getClass((id)cls) : cls;
		if (replace && host_keeps(target, sel)) {
			if (xl_verbose > 0)
				xl_log("category method %c[%s %s] left to the host", meta ? '+' : '-', class_getName(cls), sel_getName(sel));
			continue;
		}
		IMP fn = make_closure(imp, t, n);
		IMP old = NULL;
		if (replace)
			old = class_replaceMethod(target, sel, fn, enc);
		else if (!class_addMethod(target, sel, fn, enc))
			old = class_replaceMethod(target, sel, fn, enc);
		if (old && !xl_in_window((void *)old))
			xl_host_method_replaced(target, sel, old, fn);
	}
}

static void add_method_lists(Class cls, int meta, uint32_t gcls)
{
	uint32_t info = *(uint32_t *)GP(gcls + 16);
	uint32_t ml = *(uint32_t *)GP(gcls + 28);
	if (!ml)
		return;
	if (info & 0x100) {      // CLS_METHOD_ARRAY: array of lists ending in -1
		for (uint32_t p = ml;; p += 4) {
			uint32_t l = *(uint32_t *)GP(p);
			if (!l || l == 0xffffffff)
				break;
			add_methods(cls, meta, l, 0);
		}
	} else {
		add_methods(cls, meta, ml, 0);
	}
}

// ---- protocols ---------------------------------------------------------------------------
static Protocol *protocol_for(uint32_t gp);

static void add_protocols(Class cls, uint32_t plist)
{
	for (uint32_t l = plist; l; l = *(uint32_t *)GP(l)) {
		int cnt = *(int32_t *)GP(l + 4);
		for (int i = 0; i < cnt; i++) {
			Protocol *p = protocol_for(*(uint32_t *)GP(l + 8 + 4 * i));
			if (p)
				class_addProtocol(cls, p);
		}
	}
}

static Protocol *protocol_for(uint32_t gp)
{
	if (!gp)
		return nil;
	Protocol *p = (Protocol *)xl_p_quiet(gp);
	if (p)
		return p;
	const char *nm = GP(*(uint32_t *)GP(gp + 4));
	p = objc_getProtocol(nm);
	if (!p) {
		p = objc_allocateProtocol(nm);
		if (p) {
			for (int which = 0; which < 2; which++) {
				uint32_t dl = *(uint32_t *)GP(gp + 12 + 4 * which);
				if (!dl)
					continue;
				int cnt = *(int32_t *)GP(dl);
				for (int i = 0; i < cnt; i++) {
					uint32_t nmg = *(uint32_t *)GP(dl + 4 + 8 * i);
					uint32_t ty = *(uint32_t *)GP(dl + 8 + 8 * i);
					protocol_addMethodDescription(p, xl_hsel(canon_sel(nmg)), ty ? GP(ty) : "v@:", NO, which == 0);
				}
			}
			for (uint32_t l = *(uint32_t *)GP(gp + 8); l; l = *(uint32_t *)GP(l)) {
				int cnt = *(int32_t *)GP(l + 4);
				for (int i = 0; i < cnt; i++) {
					Protocol *sub = protocol_for(*(uint32_t *)GP(l + 8 + 4 * i));
					if (sub)
						protocol_addProtocol(p, sub);
				}
			}
			objc_registerProtocol(p);
		} else {
			p = objc_getProtocol(nm);
		}
	}
	if (p)
		xl_bind_handle(gp, p);
	return p;
}

// ---- classes --------------------------------------------------------------------------------
static IMP super_awz(Class meta_of_native)
{
	return class_getMethodImplementation(meta_of_native, @selector(allocWithZone:));
}

static id xl_allocWithZone(id self, SEL _cmd, NSZone *zone)
{
	// self is a class; find the first native ancestor's allocator
	Class c = (Class)self;
	Class n = c;
	while (n && xl_is_guest_class(n))
		n = class_getSuperclass(n);
	IMP imp = super_awz(object_getClass((id)n));
	id o = ((id (*)(id, SEL, NSZone *))imp)(self, _cmd, zone);
	if (o) {
		GClass *g = (GClass *)xl_map_get(&ginfo, (uint64_t)object_getClass(o));
		if (g)
			make_shadow(o, g);
	}
	return o;
}

// ---- KVC on guest instance variables ------------------------------------------------------
// Translated classes have no host ivars (their ivars live in the i386 shadow
// block), so nib outlets and KVC keys without accessors end up in the
// undefined-key methods; these look the key up in the guest ivar lists.
// objc1 class: isa super name version info instance_size ivars methods cache protocols
static int guest_ivar(id self, NSString *key, uint32_t *off, const char **type)
{
	const char *k = [key UTF8String];
	char alt[3][256];
	snprintf(alt[0], sizeof alt[0], "_%s", k);
	snprintf(alt[1], sizeof alt[1], "is%c%s", toupper((unsigned char)k[0]), k[0] ? k + 1 : "");
	snprintf(alt[2], sizeof alt[2], "_is%c%s", toupper((unsigned char)k[0]), k[0] ? k + 1 : "");
	const char *names[4] = {k, alt[0], alt[1], alt[2]};
	for (int pass = 0; pass < 4; pass++)
		for (Class c = object_getClass(self); c && xl_is_guest_class(c); c = class_getSuperclass(c)) {
			GClass *g = (GClass *)xl_map_get(&ginfo, (uint64_t)c);
			uint32_t il = *(uint32_t *)GP(g->addr + 24);
			if (!il)
				continue;
			int32_t n = *(int32_t *)GP(il);
			for (int32_t i = 0; i < n && i < 4096; i++) {
				uint32_t e = il + 4 + 12 * i;
				uint32_t nm = *(uint32_t *)GP(e);
				if (nm && !strcmp((const char *)GP(nm), names[pass])) {
					uint32_t ty = *(uint32_t *)GP(e + 4);
					*type = ty ? (const char *)GP(ty) : "@";
					*off = *(uint32_t *)GP(e + 8);
					return 1;
				}
			}
		}
	return 0;
}

static void xl_setValueForUndefinedKey(id self, SEL _cmd, id value, NSString *key)
{
	uint32_t off;
	const char *t;
	int found = guest_ivar(self, key, &off, &t);
	if (xl_verbose > 1)
		xl_log("KVC set %s.%s = %s (%s)", class_getName(object_getClass(self)), [key UTF8String],
			value ? class_getName(object_getClass(value)) : "nil", found ? t : "no guest ivar");
	if (!found) {
		Class n = object_getClass(self);
		while (n && xl_is_guest_class(n))
			n = class_getSuperclass(n);
		IMP imp = class_getMethodImplementation(n, _cmd);
		((void (*)(id, SEL, id, NSString *))imp)(self, _cmd, value, key);
		return;
	}
	uint8_t *p = GP(xl_hobj(self) + off);
	switch (*t) {
	case '@': case '#': *(uint32_t *)p = xl_hobj(value); break;    // outlets are not retained
	case 'c': case 'C': case 'B':   // strings ("YES", from plists) have no -charValue
		*p = [value respondsToSelector:@selector(charValue)] ? [value charValue] : [value boolValue];
		break;
	case 's': case 'S': *(int16_t *)p = [value shortValue]; break;
	case 'i': case 'I': case 'l': case 'L': *(int32_t *)p = [value intValue]; break;
	case 'f': *(float *)p = [value floatValue]; break;
	case 'd': *(double *)p = [value doubleValue]; break;
	case 'q': case 'Q': *(int64_t *)p = [value longLongValue]; break;
	default: xl_log("KVC set of %s (type %s) on %s not supported", [key UTF8String], t, class_getName(object_getClass(self)));
	}
}

static id xl_valueForUndefinedKey(id self, SEL _cmd, NSString *key)
{
	uint32_t off;
	const char *t;
	if (!guest_ivar(self, key, &off, &t)) {
		Class n = object_getClass(self);
		while (n && xl_is_guest_class(n))
			n = class_getSuperclass(n);
		IMP imp = class_getMethodImplementation(n, _cmd);
		return ((id (*)(id, SEL, NSString *))imp)(self, _cmd, key);
	}
	uint8_t *p = GP(xl_hobj(self) + off);
	switch (*t) {
	case '@': case '#': return XL_ID(*(uint32_t *)p);
	case 'c': return [NSNumber numberWithChar:*(int8_t *)p];
	case 'C': case 'B': return [NSNumber numberWithUnsignedChar:*p];
	case 's': return [NSNumber numberWithShort:*(int16_t *)p];
	case 'S': return [NSNumber numberWithUnsignedShort:*(uint16_t *)p];
	case 'i': case 'l': return [NSNumber numberWithInt:*(int32_t *)p];
	case 'I': case 'L': return [NSNumber numberWithUnsignedInt:*(uint32_t *)p];
	case 'f': return [NSNumber numberWithFloat:*(float *)p];
	case 'd': return [NSNumber numberWithDouble:*(double *)p];
	case 'q': return [NSNumber numberWithLongLong:*(int64_t *)p];
	case 'Q': return [NSNumber numberWithUnsignedLongLong:*(uint64_t *)p];
	case '{': {   // the i386 forms of the Foundation geometry structs
		const float *f = (const float *)p;
		if (!strncmp(t, "{_NSRange=", 10))
			return [NSValue valueWithRange:NSMakeRange(((uint32_t *)p)[0], ((uint32_t *)p)[1])];
		if (!strncmp(t, "{_NSRect=", 9))
			return [NSValue valueWithRect:NSMakeRect(f[0], f[1], f[2], f[3])];
		if (!strncmp(t, "{_NSPoint=", 10))
			return [NSValue valueWithPoint:NSMakePoint(f[0], f[1])];
		if (!strncmp(t, "{_NSSize=", 9))
			return [NSValue valueWithSize:NSMakeSize(f[0], f[1])];
		break;
	}
	}
	return nil;
}

// nib outlets of translated owners: a setter if the class has one (KVC), else the guest ivar
static IMP orig_establish;
static void xl_establishConnection(id self, SEL _cmd)
{
	id src = [self valueForKey:@"source"];
	if (src && xl_is_guest_class(object_getClass(src))) {
		NSString *label = [self valueForKey:@"label"];
		id dst = [self valueForKey:@"destination"];
		uint32_t off;
		const char *t;
		NSString *setter = [NSString stringWithFormat:@"set%@%@:", [[label substringToIndex:1] uppercaseString],
			[label substringFromIndex:1]];
		if (label.length && ![src respondsToSelector:NSSelectorFromString(setter)] && guest_ivar(src, label, &off, &t)) {
			if (xl_verbose > 1)
				xl_log("outlet %s.%s = %s", class_getName(object_getClass(src)), [label UTF8String],
					dst ? class_getName(object_getClass(dst)) : "nil");
			*(uint32_t *)GP(xl_hobj(src) + off) = xl_hobj(dst);
			return;
		}
	}
	((void (*)(id, SEL))orig_establish)(self, _cmd);
}

// +[NSBundle bundleForClass:] of a translated class: the framework bundle of
// the image that defines it (from its install name), else the main bundle
static IMP orig_bundleForClass;
static NSBundle *xl_bundleForClass(id self, SEL _cmd, Class cls)
{
	GClass *g = cls ? (GClass *)xl_map_get(&ginfo, (uint64_t)cls) : NULL;
	if (g && g->img && g->img->install && !strncmp(g->img->install, "@executable_path/", 17)) {
		static NSMutableDictionary *cache;
		if (!cache)
			cache = [NSMutableDictionary new];
		NSString *inst = [NSString stringWithUTF8String:g->img->install];
		NSBundle *b = cache[inst];
		if (!b) {
			NSString *exe = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
			NSString *p = [[exe stringByAppendingPathComponent:[inst substringFromIndex:17]] stringByStandardizingPath];
			static NSSet *bundle_exts;
			if (!bundle_exts)
				bundle_exts = [[NSSet alloc] initWithObjects:@"framework", @"prefPane", @"plugin", @"bundle", nil];
			while (p.length > 1 && ![bundle_exts containsObject:[p pathExtension]])
				p = [p stringByDeletingLastPathComponent];
			b = p.length > 1 ? [NSBundle bundleWithPath:p] : nil;
			if (!b)
				b = [NSBundle mainBundle];
			cache[inst] = b;
		}
		return b;
	}
	return ((NSBundle *(*)(id, SEL, Class))orig_bundleForClass)(self, _cmd, cls);
}

static void hook_outlets(void)
{
	Class k = objc_getClass("NSNibOutletConnector");
	Method m = k ? class_getInstanceMethod(k, @selector(establishConnection)) : NULL;
	if (m)
		orig_establish = method_setImplementation(m, (IMP)xl_establishConnection);
	else
		xl_log("NSNibOutletConnector not found: outlets of translated classes stay unset");
	Method bm = class_getClassMethod([NSBundle class], @selector(bundleForClass:));
	orig_bundleForClass = method_setImplementation(bm, (IMP)xl_bundleForClass);
}

static Class native_class(const char *nm)
{
	Class c = objc_getClass(nm);
	if (c)
		return c;
	if (!strcmp(nm, "NSMovieView") || !strcmp(nm, "QTMovieView")) {
		c = objc_allocateClassPair([NSView class], nm, 0);
		objc_registerClassPair(c);
		return c;
	}
	xl_log("missing superclass %s, using NSObject", nm);
	return [NSObject class];
}

static void build_class(GClass *g)
{
	if (g->done)
		return;
	g->done = 1;
	uint32_t a = g->addr;
	uint32_t meta = *(uint32_t *)GP(a);
	uint32_t sname = *(uint32_t *)GP(a + 4);
	Class sup = nil;
	uint32_t suph = 0, supmeta = 0;
	if (sname) {
		const char *sn = GP(sname);
		GClass *sg = gclass_named(sn);
		if (sg) {
			build_class(sg);
			sup = sg->host;
			suph = sg->addr;
			supmeta = *(uint32_t *)GP(sg->addr);
		} else {
			sup = native_class(sn);
			suph = xl_hobj((id)sup);
			supmeta = xl_hobj((id)object_getClass((id)sup));
		}
	}
	Class cls = objc_allocateClassPair(sup, g->name, 0);
	if (!cls) {
		// a second image (a preference pane, say) defines a class the app
		// already has: like dyld, keep the first and point this one at it
		Class first = objc_getClass(g->name);
		GClass *fg = first ? (GClass *)xl_map_get(&ginfo, (uint64_t)first) : NULL;
		if (!fg)
			xl_die("cannot create class %s", g->name);
		xl_log("class %s defined twice, using the first", g->name);
		g->host = fg->host;
		g->hmeta = fg->hmeta;
		g->isize = fg->isize;
		xl_bind_handle(a, fg->host);
		xl_bind_handle(meta, fg->hmeta);
		*(uint32_t *)GP(a + 4) = suph;
		*(uint32_t *)GP(meta + 4) = supmeta;
		*(uint32_t *)GP(meta) = *(uint32_t *)GP(*(uint32_t *)GP(fg->addr));   // the root metaclass
		return;
	}
	g->host = cls;
	g->hmeta = object_getClass((id)cls);
	g->isize = *(uint32_t *)GP(a + 20);
	xl_map_put(&ginfo, (uint64_t)cls, (uint64_t)g);
	xl_map_put(&ginfo, (uint64_t)g->hmeta, (uint64_t)g);
	xl_bind_handle(a, cls);
	xl_bind_handle(meta, g->hmeta);
	// guest view of the hierarchy
	*(uint32_t *)GP(a + 4) = suph;
	*(uint32_t *)GP(meta + 4) = supmeta;
	Class root = cls;
	while (class_getSuperclass(root))
		root = class_getSuperclass(root);
	*(uint32_t *)GP(meta) = xl_hobj((id)object_getClass((id)root));
	add_method_lists(cls, 0, a);
	add_method_lists(cls, 1, meta);
	add_protocols(cls, *(uint32_t *)GP(a + 36));
	if (sup && !xl_is_guest_class(sup)) {
		class_addMethod(g->hmeta, @selector(allocWithZone:), (IMP)xl_allocWithZone, "@@:^v");
		class_addMethod(cls, @selector(setValue:forUndefinedKey:), (IMP)xl_setValueForUndefinedKey, "v@:@@");
		class_addMethod(cls, @selector(valueForUndefinedKey:), (IMP)xl_valueForUndefinedKey, "@@:@");
	}
	objc_registerClassPair(cls);
	if (xl_verbose > 2)
		xl_log("class %s : %s", g->name, sup ? class_getName(sup) : "-");
}

// ---- constant strings ----------------------------------------------------------------------
// Constant strings ignore retain/release on i386 and guest code relies on it
// (it may release a literal): the host strings are made immortal the way CFSTR
// does, or else kept with a reference count release can never use up.
extern CFStringRef __CFStringMakeConstantString(const char *);

static CFStringRef immortal(CFStringRef cs)
{
	if (!cs)
		return cs;
	char buf[1024];
	if (CFStringGetCString(cs, buf, sizeof buf, kCFStringEncodingUTF8)) {
		bool ascii = true;
		for (const char *p = buf; *p; p++)
			if ((uint8_t)*p >= 0x80)
				ascii = false;
		if (ascii && (CFIndex)strlen(buf) == CFStringGetLength(cs)) {
			CFStringRef k = __CFStringMakeConstantString(buf);
			CFRelease(cs);
			return k;
		}
	}
	for (int i = 0; i < 1 << 16; i++)
		CFRetain(cs);
	return cs;
}

static void cfstrings(XLImage *im)
{
	uint32_t s = *im->slide;
	for (const XLSection *sec = im->sections; sec->seg; sec++) {
		if (strcmp(sec->name, "__cfstring"))
			continue;
		for (uint32_t o = 0; o + 16 <= sec->size; o += 16) {
			uint32_t e = sec->addr + s + o;
			uint32_t flags = *(uint32_t *)GP(e + 4), str = *(uint32_t *)GP(e + 8), len = *(uint32_t *)GP(e + 12);
			CFStringRef cs;
			if (flags & 0x10)   // UTF-16
				cs = CFStringCreateWithCharacters(NULL, GP(str), len);
			else {
				cs = CFStringCreateWithBytes(NULL, GP(str), len, kCFStringEncodingUTF8, false);
				if (!cs)
					cs = CFStringCreateWithBytes(NULL, GP(str), len, kCFStringEncodingMacRoman, false);
			}
			// shared support folders under /Library need admin rights now: use the user's Library
			if (cs && CFStringHasPrefix(cs, CFSTR("/Library/Application Support"))) {
				NSString *home = [NSHomeDirectory() stringByAppendingString:(NSString *)cs];
				CFRelease(cs);
				cs = (CFStringRef)[home copy];
			}
			xl_bind_handle(e, immortal(cs));
		}
	}
}

// ---- image scan ----------------------------------------------------------------------------------
static const XLSection *section(XLImage *im, const char *seg, const char *name)
{
	for (const XLSection *s = im->sections; s->seg; s++)
		if (!strcmp(s->seg, seg) && !strcmp(s->name, name))
			return s;
	return NULL;
}

// ---- class posing (gone from the modern runtime) -------------------------------------------
// The posing class's methods are installed into the target; a copy of the
// target's original methods becomes the posing class's guest superclass so
// that its super calls still reach the originals.
void xl_msgcache_flush(void);

static void copy_methods(Class from, Class to)
{
	unsigned n = 0;
	Method *ms = class_copyMethodList(from, &n);
	for (unsigned i = 0; i < n; i++)
		class_addMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
	free(ms);
}

static void replace_methods(Class from, Class to)
{
	unsigned n = 0;
	Method *ms = class_copyMethodList(from, &n);
	for (unsigned i = 0; i < n; i++)
		class_replaceMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
	free(ms);
}

static void xl_poseAsClass(id self, SEL _cmd, Class target)
{
	Class p = (Class)self;
	GClass *g = (GClass *)xl_map_get(&ginfo, (uint64_t)p);
	if (!g || !target || getenv("XL_NO_POSING"))
		return;
	if (target == [NSAutoreleasePool class])
		return;      // pools are runtime internals now
	// the toolbar's private views were rewritten since: the skinned toolbar
	// classes call methods that are gone, so the native toolbar stays
	static const char *const keep[] = {"NSToolbarView", "NSToolbarItemViewer", "NSToolbarButton"};
	for (unsigned i = 0; i < sizeof keep / sizeof *keep; i++)
		if (!strcmp(class_getName(target), keep[i]) && !getenv("XL_POSE_TOOLBAR")) {
			if (xl_verbose > 0)
				xl_log("%s does not pose as %s", class_getName(p), keep[i]);
			return;
		}
	char nm[256];
	snprintf(nm, sizeof nm, "XLOriginal_%s", class_getName(target));
	Class orig = objc_getClass(nm);
	if (!orig) {
		orig = objc_allocateClassPair(class_getSuperclass(target), nm, 0);
		copy_methods(target, orig);
		copy_methods(object_getClass((id)target), object_getClass((id)orig));
		objc_registerClassPair(orig);
	}
	*(uint32_t *)GP(g->addr + 4) = xl_hobj((id)orig);
	*(uint32_t *)GP(*(uint32_t *)GP(g->addr) + 4) = xl_hobj((id)object_getClass((id)orig));
	replace_methods(p, target);
	replace_methods(object_getClass((id)p), object_getClass((id)target));
	xl_msgcache_flush();
	if (xl_verbose > 0)
		xl_log("%s poses as %s", class_getName(p), class_getName(target));
}

typedef struct { uint32_t addr; XLImage *img; } GCat;

void xl_objc_init(void)
{
	GCat *cats = NULL;
	int ncats = 0, capcats = 0;
	class_replaceMethod(object_getClass((id)[NSObject class]), sel_registerName("poseAsClass:"), (IMP)xl_poseAsClass, "v@:#");
	// selectors first: every reference gets the canonical address
	for (XLImage *im = xl_images; im; im = im->next) {
		uint32_t s = *im->slide;
		const XLSection *sec = section(im, "__OBJC", "__message_refs");
		if (sec)
			for (uint32_t o = 0; o < sec->size; o += 4) {
				uint32_t *slot = GP(sec->addr + s + o);
				if (*slot)
					*slot = canon_sel(*slot);
			}
		cfstrings(im);
		const XLSection *mi = section(im, "__OBJC", "__module_info");
		if (!mi)
			continue;
		for (uint32_t o = 0; o + 16 <= mi->size; o += 16) {
			uint32_t st = *(uint32_t *)GP(mi->addr + s + o + 12);
			if (!st)
				continue;
			uint16_t ncls = *(uint16_t *)GP(st + 8), ncat = *(uint16_t *)GP(st + 10);
			for (int i = 0; i < ncls; i++) {
				uint32_t ca = *(uint32_t *)GP(st + 12 + 4 * i);
				if (ngclasses == capgclasses) {
					capgclasses = capgclasses ? capgclasses * 2 : 256;
					gclasses = realloc(gclasses, capgclasses * sizeof *gclasses);
				}
				GClass *g = &gclasses[ngclasses++];
				memset(g, 0, sizeof *g);
				g->addr = ca;
				g->name = GP(*(uint32_t *)GP(ca + 8));
				g->img = im;
				xl_map_put(&class_by_name, namehash(g->name), ngclasses);
			}
			for (int i = 0; i < ncat; i++) {
				if (ncats == capcats) {
					capcats = capcats ? capcats * 2 : 64;
					cats = realloc(cats, capcats * sizeof *cats);
				}
				cats[ncats].addr = *(uint32_t *)GP(st + 12 + 4 * (ncls + i));
				cats[ncats].img = im;
				ncats++;
			}
		}
	}
	// protocols declared in the images
	for (XLImage *im = xl_images; im; im = im->next) {
		const XLSection *sec = section(im, "__OBJC", "__protocol");
		if (sec)
			for (uint32_t o = 0; o + 20 <= sec->size; o += 20)
				protocol_for(sec->addr + *im->slide + o);
	}
	// class references, before any guest code can run: building a class looks up
	// methods, which sends +initialize
	for (XLImage *im = xl_images; im; im = im->next) {
		const XLSection *sec = section(im, "__OBJC", "__cls_refs");
		if (!sec)
			continue;
		for (uint32_t o = 0; o < sec->size; o += 4) {
			uint32_t *slot = GP(sec->addr + *im->slide + o);
			if (!*slot)
				continue;
			const char *cn = GP(*slot);
			GClass *g = gclass_named(cn);
			if (g)
				*slot = g->addr;
			else {
				Class c = objc_getClass(cn);
				if (!c)
					c = native_class(cn);
				*slot = xl_hobj((id)c);
			}
			if (xl_verbose > 1)
				xl_log("cls_ref %s %08x -> %08x", cn, sec->addr + *im->slide + o, *slot);
		}
	}
	for (int i = 0; i < ngclasses; i++)
		build_class(&gclasses[i]);
	for (int i = 0; i < ncats; i++) {
		uint32_t ca = cats[i].addr;
		const char *cn = GP(*(uint32_t *)GP(ca + 4));
		GClass *g = gclass_named(cn);
		Class cls = g ? g->host : objc_getClass(cn);
		if (!cls) {
			xl_log("category %s on missing class %s", (char *)GP(*(uint32_t *)GP(ca)), cn);
			continue;
		}
		add_methods(cls, 0, *(uint32_t *)GP(ca + 8), 1);
		add_methods(cls, 1, *(uint32_t *)GP(ca + 12), 1);
		add_protocols(cls, *(uint32_t *)GP(ca + 16));
	}
	// +load, classes before categories
	SEL load = @selector(load);
	for (int i = 0; i < ngclasses; i++) {
		uint32_t meta = *(uint32_t *)GP(gclasses[i].addr);
		uint32_t ml = *(uint32_t *)GP(meta + 28);
		if (!ml || (*(uint32_t *)GP(meta + 16) & 0x100))
			continue;
		int cnt = *(int32_t *)GP(ml + 4);
		for (int k = 0; k < cnt; k++)
			if (xl_hsel(*(uint32_t *)GP(ml + 8 + 12 * k)) == load) {
				uint32_t args[2] = {gclasses[i].addr, xl_gsel(load)};
				xl_guest_call(*(uint32_t *)GP(ml + 8 + 12 * k + 8), 2, args);
			}
	}
	for (int i = 0; i < ncats; i++) {
		uint32_t ml = *(uint32_t *)GP(cats[i].addr + 12);
		if (!ml)
			continue;
		const char *cn = GP(*(uint32_t *)GP(cats[i].addr + 4));
		GClass *g = gclass_named(cn);
		Class cls = g ? g->host : objc_getClass(cn);
		int cnt = *(int32_t *)GP(ml + 4);
		for (int k = 0; k < cnt; k++)
			if (xl_hsel(*(uint32_t *)GP(ml + 8 + 12 * k)) == load) {
				uint32_t args[2] = {xl_hobj((id)cls), xl_gsel(load)};
				xl_guest_call(*(uint32_t *)GP(ml + 8 + 12 * k + 8), 2, args);
			}
	}
	if (xl_verbose > 0)
		xl_log("%d classes, %d categories", ngclasses, ncats);
	free(cats);
	hook_outlets();
	extern void xl_appkit_hooks(void);
	xl_appkit_hooks();
}
