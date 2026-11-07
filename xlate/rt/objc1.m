// Objective-C 1 metadata of the translated images, registered with the
// modern runtime; handles for objects; closures for translated methods.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#include "rt.h"
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
	if (!((uintptr_t)o & (1UL << 63))) {
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

// the SDK signature for a selector, preferring entries declared on cls or its protocols
const XLMethodType *xl_sdk_method(SEL sel, Class cls, int meta)
{
	const char *nm = sel_getName(sel);
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
	case 'p': case 'h': case 'P': k = "^v"; break;
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
	for (int i = 1; i < m->n; i++) {
		xl_h2g(m->t[i], args[i - 1], o);
		o += (m->t[i]->gsize + 3) & ~3u;
	}
	if (xl_verbose > 3)
		xl_log("-> %s", xl_name_at(m->guest));
	XLResult res;
	xl_guest_run(c, m->guest, sp, &res);
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
		IMP fn = make_closure(imp, t, n);
		Class target = meta ? object_getClass((id)cls) : cls;
		if (replace)
			class_replaceMethod(target, sel, fn, enc);
		else if (!class_addMethod(target, sel, fn, enc))
			class_replaceMethod(target, sel, fn, enc);
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
	if (!cls)
		xl_die("cannot create class %s", g->name);
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
	if (sup && !xl_is_guest_class(sup))
		class_addMethod(g->hmeta, @selector(allocWithZone:), (IMP)xl_allocWithZone, "@@:^v");
	objc_registerClassPair(cls);
	if (xl_verbose > 2)
		xl_log("class %s : %s", g->name, sup ? class_getName(sup) : "-");
}

// ---- constant strings ----------------------------------------------------------------------
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
			xl_bind_handle(e, cs);
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
	// class references
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
		}
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
}
