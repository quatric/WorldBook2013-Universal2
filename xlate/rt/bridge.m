// Guest -> host calls: C functions and Objective-C messages.
#import <Foundation/Foundation.h>
#import <AppKit/NSBitmapImageRep.h>
#import <objc/message.h>
#include "rt.h"
#include <ffi/ffi.h>
#include <dlfcn.h>

typedef struct XLBridge XLBridge;
typedef void (*XLCallFn)(XLCPU *c, XLBridge *b);
struct XLBridge {
	XLCallFn call;
	const char *name;
	void *fn;
	XLShim shim;
	uint32_t guest;
	int n;               // types incl. return
	XLType *t[32];
	ffi_cif cif;
	ffi_type *ft[32];
	int variadic;
	int valist;          // the guest passes a va_list where the host function takes "..."
	int objret;          // returned pointers are objects
};

extern void xl_exc_from_host(XLCPU *c, NSException *e);   // exc.m
int xl_exc_pending(XLCPU *c);
void xl_exc_deliver(XLCPU *c);

static inline void fpush(XLCPU *c, double v)
{
	c->top = (c->top - 1) & 7;
	c->st[c->top] = v;
}

// ---- function pointers -------------------------------------------------------------------
__thread const char *cb_ctx;   // "function.argindex" while converting arguments
static XLMap cb_cache;                // guest fn ^ sig hash -> closure

typedef struct { const char *ctx, *sig; } CBSig;
static const CBSig cbsigs[] = {
	{"_qsort.3", "i|*|*"},
	{"_bsearch.4", "i|*|*"},
	{"_CFArrayApplyFunction.2", "v|@|*"},
	{"sortUsingFunction:context:.0", "l|@|@|*"},
	{"sortedArrayUsingFunction:context:.0", "l|@|@|*"},
	{"sortedArrayUsingFunction:context:hint:.0", "l|@|@|*"},
	{"_CFRunLoopTimerCreate.6", "v|p|*"},
	{"_CFReadStreamSetClient.2", "v|p|L|*"},
	{"_CFWriteStreamSetClient.2", "v|p|L|*"},
	{"_CGDataProviderCreateWithData.3", "v|*|*|L"},
	{"_SCDynamicStoreCreate.2", "v|p|@|*"},
	{"_CFSocketCreate.5", "v|p|L|@|*|*"},
	{"CFRunLoopSourceContext.2", "*|*"},
	{"CFRunLoopSourceContext.3", "v|*"},
	{"CFRunLoopSourceContext.4", "@|*"},
	{"CFRunLoopSourceContext.5", "C|*|*"},
	{"CFRunLoopSourceContext.6", "L|*"},
	{"CFRunLoopSourceContext.7", "v|*|p|@"},
	{"CFRunLoopSourceContext.8", "v|*|p|@"},
	{"CFRunLoopSourceContext.9", "v|*"},
	{"CFRunLoopTimerContext.2", "*|*"},
	{"CFRunLoopTimerContext.3", "v|*"},
	{"CFRunLoopTimerContext.4", "@|*"},
	{"CFRunLoopObserverContext.2", "*|*"},
	{"CFRunLoopObserverContext.3", "v|*"},
	{"CFRunLoopObserverContext.4", "@|*"},
	{"CFStreamClientContext.2", "*|*"},
	{"CFStreamClientContext.3", "v|*"},
	{"CFStreamClientContext.4", "@|*"},
	{"CFSocketContext.2", "*|*"},
	{"CFSocketContext.3", "v|*"},
	{"CFSocketContext.4", "@|*"},
	{"SCDynamicStoreContext.2", "*|*"},
	{"SCDynamicStoreContext.3", "v|*"},
	{"SCDynamicStoreContext.4", "@|*"},
	{"_CFRunLoopObserverCreate.4", "v|p|L|*"},
	{0}
};

void *xl_fnptr_g2h(uint32_t g, XLType *t)
{
	(void)t;
	if (!g)
		return NULL;
	const char *tn = xl_thunk_name(g);
	if (tn) {
		void *p = dlsym(RTLD_DEFAULT, tn + 1);
		if (p)
			return p;
	}
	const char *sig = NULL;
	if (cb_ctx)
		for (const CBSig *s = cbsigs; s->ctx; s++)
			if (!strcmp(s->ctx, cb_ctx)) {
				sig = s->sig;
				break;
			}
	if (!sig) {
		xl_log("function pointer %08x (%s) passed as %s: no known signature", g, xl_name_at(g), cb_ctx ? cb_ctx : "?");
		return NULL;
	}
	uint64_t key = g ^ ((uint64_t)(uintptr_t)sig << 20);
	void *p = (void *)xl_map_get(&cb_cache, key);
	if (!p) {
		p = xl_closure_for(g, sig);
		xl_map_put(&cb_cache, key, (uint64_t)p);
	}
	return p;
}

uint32_t xl_fnptr_h2g(void *p)
{
	if (!p)
		return 0;
	uint32_t g = xl_guest_imp_of((IMP)p);
	if (g)
		return g;
	Dl_info di;
	if (dladdr(p, &di) && di.dli_sname) {
		char nm[256];
		snprintf(nm, sizeof nm, "_%s", di.dli_sname);
		return xl_thunk_for(nm);
	}
	xl_log("host function pointer %p has no guest address", p);
	return 0;
}

// ---- argument conversion -------------------------------------------------------------------
typedef struct {
	int n;
	XLType *t[48];
	uint32_t g[48];
	void *h[48];
	int count[48];
} Temps;

typedef struct {
	void *vals[64];
	ffi_type *ft[64];
	uint8_t store[64][32];
	uint8_t *big[64];
	Temps tmp;
} Args;

static void *slot(Args *A, int i, XLType *t)
{
	if (t->hsize <= 32)
		return A->store[i];
	A->big[i] = calloc(1, t->hsize);
	return A->big[i];
}

static void args_free(Args *A, int n)
{
	for (int i = 0; i < n; i++)
		if (A->big[i]) {
			free(A->big[i]);
			A->big[i] = NULL;
		}
	for (int i = 0; i < A->tmp.n; i++)
		free(A->tmp.h[i]);
	A->tmp.n = 0;
}

// convert one guest argument at g into host storage; returns guest bytes used
static uint32_t conv_arg(Args *A, int i, XLType *t, uint32_t g, int count)
{
	void *h = slot(A, i, t);
	A->vals[i] = h;
	A->ft[i] = t->ffi;
	if (t->kind == 'P') {
		uint32_t p = *(uint32_t *)GP(g);
		if (!p) {
			*(void **)h = NULL;
		} else {
			XLType *s = t->sub;
			int cnt = count > 0 ? count : 1;
			void *tmp = calloc(cnt, s->hsize ? s->hsize : 8);
			for (int k = 0; k < cnt; k++) {
				if (s->kind == '@' && count <= 0)
					continue;     // out parameter: start nil
				xl_g2h(s, p + k * s->gsize, (uint8_t *)tmp + k * s->hsize);
			}
			*(void **)h = tmp;
			Temps *T = &A->tmp;
			T->t[T->n] = s;
			T->g[T->n] = p;
			T->h[T->n] = tmp;
			T->count[T->n] = cnt;
			T->n++;
		}
	} else {
		xl_g2h(t, g, h);
	}
	return (t->gsize + 3) & ~3u;
}

static void copy_out(Args *A)
{
	Temps *T = &A->tmp;
	for (int i = 0; i < T->n; i++) {
		XLType *s = T->t[i];
		for (int k = 0; k < T->count[i]; k++)
			xl_h2g(s, (uint8_t *)T->h[i] + k * s->hsize, T->g[i] + k * s->gsize);
	}
}

static int guest_mem_ret(XLType *r)
{
	return r->kind == '{' && !(r->gsize == 1 || r->gsize == 2 || r->gsize == 4 || r->gsize == 8);
}

static void set_ret(XLCPU *c, XLType *t, void *rv, uint32_t sret, int objret)
{
	switch (t->kind) {
	case 'v': break;
	case 'c': c->r[EAX] = (uint32_t)(int32_t)(int8_t)*(ffi_sarg *)rv; break;
	case 'C': case 'B': c->r[EAX] = (uint8_t)*(ffi_arg *)rv; break;
	case 's': c->r[EAX] = (uint32_t)(int32_t)(int16_t)*(ffi_sarg *)rv; break;
	case 'S': c->r[EAX] = (uint16_t)*(ffi_arg *)rv; break;
	case 'i': case 'I': c->r[EAX] = (uint32_t)*(ffi_arg *)rv; break;
	case 'l': case 'L': c->r[EAX] = xl_long_out(*(uint64_t *)rv); break;
	case 'q': case 'Q': {
		uint64_t v = *(uint64_t *)rv;
		c->r[EAX] = (uint32_t)v;
		c->r[EDX] = (uint32_t)(v >> 32);
		break;
	}
	case 'f': fpush(c, *(float *)rv); break;
	case 'd': case 'F': fpush(c, *(double *)rv); break;
	case '@': c->r[EAX] = objret ? xl_hobj(*(id *)rv) : xl_h(*(void **)rv); break;
	case 'p': case 'h': c->r[EAX] = xl_h(*(void **)rv); break;
	case ':': c->r[EAX] = *(SEL *)rv ? xl_gsel(*(SEL *)rv) : 0; break;
	case '*': case 'P': c->r[EAX] = xl_hptr_out(*(void **)rv); break;
	case '^': c->r[EAX] = xl_fnptr_h2g(*(void **)rv); break;
	case '{':
		if (sret) {
			xl_h2g(t, rv, sret);
			c->r[EAX] = sret;
		} else {
			uint32_t tmp = c->r[ESP] - 256;
			memset(GP(tmp), 0, 8);
			xl_h2g(t, rv, tmp);
			c->r[EAX] = *(uint32_t *)GP(tmp);
			c->r[EDX] = *(uint32_t *)GP(tmp + 4);
		}
		break;
	}
}

// ---- formats ------------------------------------------------------------------------------
static ffi_type *ft_for(char k)
{
	switch (k) {
	case 'i': return &ffi_type_sint32;
	case 'l': return &ffi_type_sint64;
	case 'd': return &ffi_type_double;
	default: return &ffi_type_pointer;
	}
}

// walk a printf/scanf style format; appends host arguments from the guest
// varargs at *gva. For scanf, rewrites l/z integer modifiers in fmtout.
static int fmt_args(const char *f, uint32_t *gva, Args *A, int base, int max, int scan, char *fmtout, size_t outn)
{
	int n = base;
	size_t o = 0;
#define PUT(ch) ((fmtout && o + 1 < outn) ? (void)(fmtout[o++] = (ch)) : (void)0)
	while (*f) {
		if (*f != '%') {
			PUT(*f);
			f++;
			continue;
		}
		PUT(*f);
		f++;
		if (*f == '%') {
			PUT(*f);
			f++;
			continue;
		}
		// position flags width precision
		while (*f && strchr("-+ #0'", *f))
			PUT(*f), f++;
		if (scan && *f == '*') {
			PUT(*f), f++;
			while (*f >= '0' && *f <= '9')
				PUT(*f), f++;
			int lm = 0;
			while (*f && strchr("hlLqjzt", *f))
				PUT(*f), f++, lm++;
			if (*f == '[') {
				while (*f && *f != ']')
					PUT(*f), f++;
			}
			if (*f)
				PUT(*f), f++;
			continue;
		}
		if (*f == '*') {
			PUT(*f), f++;
			if (n < max) {
				int32_t v = *(int32_t *)GP(*gva);
				*gva += 4;
				*(int32_t *)A->store[n] = v;
				A->vals[n] = A->store[n];
				A->ft[n] = &ffi_type_sint32;
				n++;
			}
		}
		while ((*f >= '0' && *f <= '9') || *f == '$')
			PUT(*f), f++;
		if (*f == '.') {
			PUT(*f), f++;
			if (*f == '*') {
				PUT(*f), f++;
				if (n < max) {
					int32_t v = *(int32_t *)GP(*gva);
					*gva += 4;
					*(int32_t *)A->store[n] = v;
					A->vals[n] = A->store[n];
					A->ft[n] = &ffi_type_sint32;
					n++;
				}
			}
			while (*f >= '0' && *f <= '9')
				PUT(*f), f++;
		}
		int ll = 0, l = 0, L = 0;
		while (*f && strchr("hlLqjzt", *f)) {
			if (*f == 'l') {
				if (f[1] == 'l') {
					ll = 1;
					if (!scan || 1)
						PUT('l'), PUT('l');
					f += 2;
					continue;
				}
				l = 1;
				if (!scan)
					PUT('l');
			} else if (*f == 'q' || *f == 'j') {
				ll = 1;
				PUT(*f);
			} else if (*f == 'z' || *f == 't') {
				l = 1;
				if (!scan)
					PUT(*f);
			} else if (*f == 'L') {
				L = 1;
				PUT(*f);
			} else {
				PUT(*f);
			}
			f++;
		}
		char conv = *f;
		if (!conv)
			break;
		PUT(conv);
		f++;
		if (conv == '[') {
			while (*f && *f != ']')
				PUT(*f), f++;
			if (*f)
				PUT(*f), f++;
		}
		if (n >= max)
			continue;
		uint32_t g = *gva;
		if (scan) {
			uint32_t p = *(uint32_t *)GP(g);
			*gva += 4;
			*(void **)A->store[n] = p ? GP(p) : NULL;
			A->vals[n] = A->store[n];
			A->ft[n] = &ffi_type_pointer;
			n++;
			continue;
		}
		switch (conv) {
		case 'd': case 'i': case 'o': case 'u': case 'x': case 'X': case 'c': case 'C': case 'D': case 'U': case 'O':
			if (ll) {
				memcpy(A->store[n], GP(g), 8);
				*gva += 8;
				A->ft[n] = &ffi_type_sint64;
			} else if (l) {
				int64_t v = (conv == 'd' || conv == 'i' || conv == 'D') ? (int64_t)*(int32_t *)GP(g) : (int64_t)*(uint32_t *)GP(g);
				*(int64_t *)A->store[n] = v;
				*gva += 4;
				A->ft[n] = &ffi_type_sint64;
			} else {
				*(int32_t *)A->store[n] = *(int32_t *)GP(g);
				*gva += 4;
				A->ft[n] = &ffi_type_sint32;
			}
			break;
		case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A':
			if (L) {
				*gva += 16;
#if defined(__x86_64__)
				// the host format still says L, and long double is the x87 type here
				long double v = xl_ld80(g);
				memcpy(A->store[n], &v, sizeof v);
				A->ft[n] = &ffi_type_longdouble;
				break;
#else
				// the host format still says L: long double is double on arm64
				*(double *)A->store[n] = xl_ld80(g);
#endif
			} else {
				memcpy(A->store[n], GP(g), 8);
				*gva += 8;
			}
			A->ft[n] = &ffi_type_double;
			break;
		case 's': case 'S': case 'n': {
			uint32_t p = *(uint32_t *)GP(g);
			*(void **)A->store[n] = p ? GP(p) : NULL;
			*gva += 4;
			A->ft[n] = &ffi_type_pointer;
			break;
		}
		case '@': {
			uint32_t p = *(uint32_t *)GP(g);
			*(void **)A->store[n] = xl_p(p);
			*gva += 4;
			A->ft[n] = &ffi_type_pointer;
			break;
		}
		case 'p': default: {
			uint32_t p = *(uint32_t *)GP(g);
			*(uintptr_t *)A->store[n] = p;
			*gva += 4;
			A->ft[n] = &ffi_type_pointer;
			break;
		}
		}
		A->vals[n] = A->store[n];
		n++;
	}
	if (fmtout && outn)
		fmtout[o < outn ? o : outn - 1] = 0;
#undef PUT
	(void)ft_for;
	return n;
}

// variadic tail: format string at index fi (object or C string), or nil-terminated objects
static int var_args(XLType **t, int nfix, uint32_t gva, Args *A, int objs, int fi, int scan, char *fmtbuf, size_t fmtn)
{
	if (objs) {
		int n = nfix;
		for (;;) {
			uint32_t h = *(uint32_t *)GP(gva);
			gva += 4;
			*(void **)A->store[n] = xl_p(h);
			A->vals[n] = A->store[n];
			A->ft[n] = &ffi_type_pointer;
			n++;
			if (!h || n >= 63)
				break;
		}
		return n;
	}
	if (fi < 0)
		return nfix;
	const char *f;
	if (t[fi + 1]->kind == '@') {
		id s = *(id *)A->vals[fi];
		f = s ? [(NSString *)s UTF8String] : "";
	} else {
		f = *(const char **)A->vals[fi];
		if (!f)
			f = "";
	}
	int n = fmt_args(f, &gva, A, nfix, 63, scan, scan ? fmtbuf : NULL, fmtn);
	if (scan)
		*(const char **)A->vals[fi] = fmtbuf;
	return n;
}

// ---- C function bridges ---------------------------------------------------------------------
static void call_shim(XLCPU *c, XLBridge *b)
{
	b->shim(c);
}

static void call_guest(XLCPU *c, XLBridge *b)
{
	xl_call(c, b->guest);
}

static void call_missing(XLCPU *c, XLBridge *b)
{
	static XLMap seen;
	if (!xl_map_get(&seen, (uint64_t)b)) {
		xl_map_put(&seen, (uint64_t)b, 1);
		uint32_t ret = *(uint32_t *)GP(c->r[ESP]);
		xl_log("missing function %s called (from %s)", b->name, xl_name_at(ret));
	}
	c->r[EAX] = 0;
	c->r[EDX] = 0;
	if (b->n && (b->t[0]->kind == 'f' || b->t[0]->kind == 'd' || b->t[0]->kind == 'F'))
		fpush(c, 0);
	c->r[ESP] += 4;
}

static int is_scanf(const char *nm)
{
	return strstr(nm, "scanf") != NULL;
}

static void call_ffi(XLCPU *c, XLBridge *b)
{
	Args A;
	A.tmp.n = 0;
	memset(A.big, 0, sizeof A.big);
	uint32_t g = c->r[ESP] + 4;
	XLType *rt = b->t[0];
	uint32_t sret = 0;
	int mem = guest_mem_ret(rt);
	if (mem) {
		sret = *(uint32_t *)GP(g);
		g += 4;
	}
	int nfix = b->n - 1;
	char ctx[96];
	for (int i = 0; i < nfix; i++) {
		if (b->t[i + 1]->kind == '^') {
			snprintf(ctx, sizeof ctx, "%s.%d", b->name, i);
			cb_ctx = ctx;
		}
		g += conv_arg(&A, i, b->t[i + 1], g, 0);
		cb_ctx = NULL;
	}
	int n = nfix;
	char fmtbuf[1024];
	ffi_cif vcif, *cif = &b->cif;
	if (b->variadic) {
		int fi = -1;
		for (int i = nfix - 1; i >= 0; i--)
			if (b->t[i + 1]->kind == '@' || b->t[i + 1]->kind == '*') {
				fi = i;
				break;
			}
		if (!strcmp(b->name, "_open") || !strcmp(b->name, "_fcntl")) {
			*(int32_t *)A.store[n] = *(int32_t *)GP(g);
			A.vals[n] = A.store[n];
			A.ft[n] = &ffi_type_sint32;
			n++;
		} else {
			uint32_t gva = b->valist ? *(uint32_t *)GP(g) : g;
			n = var_args(b->t, nfix, gva, &A, 0, fi, is_scanf(b->name), fmtbuf, sizeof fmtbuf);
		}
		if (ffi_prep_cif_var(&vcif, FFI_DEFAULT_ABI, nfix, n, rt->ffi, A.ft) != FFI_OK)
			xl_die("ffi_prep_cif_var failed for %s", b->name);
		cif = &vcif;
	}
	uint8_t rv[256] __attribute__((aligned(16)));
	memset(rv, 0, 16);
	if (xl_verbose > 4) {
		uint32_t *ga = (uint32_t *)GP(c->r[ESP] + 4);
		xl_log("ccall %s %08x %08x %08x %08x", b->name, ga[0], ga[1], ga[2], ga[3]);
	}
	ffi_call(cif, FFI_FN(b->fn), rv, A.vals);
	copy_out(&A);
	set_ret(c, rt, rv, sret, b->objret);
	args_free(&A, n);
	c->r[ESP] += mem ? 8 : 4;
}

// signatures that differ from the SDK headers' view: CF containers hold objects, FILE is opaque
typedef struct { const char *name, *sig; } SigOverride;
static const SigOverride overrides[] = {
	{"_CFArrayAppendValue", "v|@|@"},
	{"_CFArrayGetValueAtIndex", "@|@|l"},
	{"_CFDictionaryGetValue", "@|@|@"},
	{"_CFDictionarySetValue", "v|@|@|@"},
	{"_CFDictionaryContainsKey", "C|@|@"},
	{"_CFDictionaryGetValueIfPresent", "C|@|@|P@"},
	{"_CFSetContainsValue", "C|@|@"},
	{"_CFRetain", "@|@"},
	{"_CFRelease", "v|@"},
	{"_CFEqual", "C|@|@"},
	{"_CFHash", "L|@"},
	{"_CFGetTypeID", "L|@"},
	{"_CFPreferencesCopyAppValue", "@|@|@"},
	{"_CFPreferencesCopyValue", "@|@|@|@|@"},
	{"_CFPreferencesSetAppValue", "v|@|@|@"},
	{"_CFPreferencesSetValue", "v|@|@|@|@|@"},
	{"_CFReadStreamCopyProperty", "@|@|@"},
	{"_CFReadStreamSetProperty", "C|@|@|@"},
	{"_SCDynamicStoreCopyValue", "@|@|@"},
	{"_CFBundleGetValueForInfoDictionaryKey", "@|@|@"},
	{"_IORegistryEntryCreateCFProperty", "@|I|@|@|I"},
	{"_CFPropertyListCreateFromXMLData", "@|@|@|L|P@"},
	{"_CFPropertyListCreateXMLData", "@|@|@"},
	{0}
};

static const char *c_sig(const char *name, int *variadic)
{
	*variadic = 0;
	for (const SigOverride *o = overrides; o->name; o++)
		if (!strcmp(o->name, name))
			return o->sig;
	size_t lo = 0, hi = xl_sdk_nfuncs;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		int r = strcmp(xl_sdk_funcs[mid].name, name);
		if (!r) {
			*variadic = xl_sdk_funcs[mid].variadic;
			return xl_sdk_funcs[mid].type;
		}
		if (r < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	return NULL;
}

static void fix_file_types(XLBridge *b)
{
	// FILE * and other pointers to defined system structs that are opaque to the guest
	for (int i = 0; i < b->n; i++) {
		XLType *t = b->t[i];
		if (t->kind == 'P' && t->sub->kind == '{' && t->sub->name &&
			(!strcmp(t->sub->name, "__sFILE") || !strncmp(t->sub->name, "_opaque_pthread", 15))) {
			static XLType *opaque;
			if (!opaque) {
				const char *s = "p";
				opaque = xl_type_parse(&s);
			}
			b->t[i] = opaque;
		}
	}
}

int xl_is_function(const char *name)
{
	int v;
	return xl_find_shim(name) != NULL || c_sig(name, &v) != NULL;
}

void *xl_resolve_import(const char *name)
{
	XLBridge *b = calloc(1, sizeof *b);
	b->name = name;
	XLShim sh = xl_find_shim(name);
	if (sh) {
		b->shim = sh;
		b->call = call_shim;
		return b;
	}
	uint32_t g = xl_lookup_export(name);
	if (g) {
		b->guest = g;
		b->call = call_guest;
		return b;
	}
	// va_list functions call their variadic forms: an i386 va_list points at
	// the arguments as they lie on the stack, which the variadic path reads
	static const char *const valist[][2] = {
		{"_CFStringAppendFormatAndArguments", "_CFStringAppendFormat"},
		{"_CFStringCreateWithFormatAndArguments", "_CFStringCreateWithFormat"},
		{"_vfprintf", "_fprintf"}, {"_vprintf", "_printf"}, {"_vsprintf", "_sprintf"},
		{"_vsnprintf", "_snprintf"}, {"_vasprintf", "_asprintf"}, {"_NSLogv", "_NSLog"},
		{"_vsyslog", "_syslog"},
	};
	const char *host = name;
	for (unsigned i = 0; i < sizeof valist / sizeof *valist; i++)
		if (!strcmp(name, valist[i][0])) {
			host = valist[i][1];
			b->valist = 1;
		}
	int variadic;
	const char *sig = c_sig(host, &variadic);
	void *fn = dlsym(RTLD_DEFAULT, host + 1);
	if (sig)
		b->n = xl_sig_split(sig, b->t, 32);
	if (!fn || !sig) {
		if (xl_verbose > 0 || !fn)
			xl_log("no host function for %s%s", name, fn ? " (no signature)" : "");
		b->call = call_missing;
		return b;
	}
	fix_file_types(b);
	b->fn = fn;
	b->variadic = variadic;
	b->objret = !strncmp(name, "_NS", 3) || !strncmp(name, "_CF", 3);
	for (int i = 0; i < b->n; i++)
		b->ft[i] = b->t[i]->ffi;
	if (!variadic && ffi_prep_cif(&b->cif, FFI_DEFAULT_ABI, b->n - 1, b->ft[0], b->ft + 1) != FFI_OK)
		xl_die("ffi_prep_cif failed for %s", name);
	b->call = call_ffi;
	return b;
}

int xl_gl_trace;
void xl_ccall(XLCPU *c, XLImport *imp)
{
	XLBridge *b = imp->impl;
	if (!b) {
		b = xl_resolve_import(imp->name);
		imp->impl = b;
	}
	if (xl_verbose > 5)
		xl_log("call %s", b->name);
	if (xl_gl_trace && !strncmp(b->name, "_gl", 3) && (xl_gl_trace == 1 || strstr(b->name, "Tex") || strstr(b->name, "Pixel") || strstr(b->name, "Delete"))) {
		// raw argument words, floats shown as such too (driver step gltrace)
		char buf[256];
		int o = snprintf(buf, sizeof buf, "GL %s", b->name + 1);
		for (int i = 0; i < 8 && o < 200; i++) {
			uint32_t w = xl_arg(c, i);
			float f;
			memcpy(&f, &w, 4);
			o += snprintf(buf + o, sizeof buf - o, " %x(%g)", w, f);
		}
		fprintf(stderr, "%s\n", buf);
		static uint32_t vp, vstride, tp, tstride;
		if (!strcmp(b->name, "_glVertexPointer")) {
			vp = xl_arg(c, 3);
			vstride = xl_arg(c, 2);
		} else if (!strcmp(b->name, "_glTexCoordPointer") && xl_arg(c, 3) != tp) {
			tp = xl_arg(c, 3);
			tstride = xl_arg(c, 2);
		} else if (!strcmp(b->name, "_glDrawRangeElementsEXT") && vp && xl_arg(c, 5)) {
			uint32_t *ix = (uint32_t *)GP(xl_arg(c, 5));
			uint32_t n = xl_arg(c, 3);
			float x0 = 1e30, x1 = -1e30, y0 = 1e30, y1 = -1e30, s0 = 1e30, s1 = -1e30, t0 = 1e30, t1 = -1e30;
			for (uint32_t i = 0; i < n; i++) {
				float *v = (float *)GP(vp + ix[i] * (vstride ? vstride : 8));
				float *t = (float *)GP(tp + ix[i] * (tstride ? tstride : 8));
				x0 = fminf(x0, v[0]); x1 = fmaxf(x1, v[0]); y0 = fminf(y0, v[1]); y1 = fmaxf(y1, v[1]);
				s0 = fminf(s0, t[0]); s1 = fmaxf(s1, t[0]); t0 = fminf(t0, t[1]); t1 = fmaxf(t1, t[1]);
			}
			fprintf(stderr, "GLBOX n=%u first=%u pos x %g..%g y %g..%g tex s %g..%g t %g..%g vstride %u tstride %u\n", n, ix[0], x0, x1, y0, y1, s0, s1, t0, t1, vstride, tstride);
		}
	}
	if (xl_gl_trace && (!strncmp(b->name, "_NSIntersection", 15) || !strcmp(b->name, "_NSInsetRect") || !strcmp(b->name, "_ceilf"))) {
		uint32_t a[10];
		for (int i = 0; i < 10; i++)
			a[i] = xl_arg(c, i);
		b->call(c, b);
		float f[10];
		memcpy(f, a, sizeof f);
		fprintf(stderr, "NSC %s args %x %x %x %x %x %x %x %x %x (%g %g %g %g %g %g %g %g) -> eax %x edx %x", b->name + 1, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], c->r[EAX], c->r[EDX]);
		if (strcmp(b->name, "_NSIntersectionRange") && strcmp(b->name, "_ceilf") && a[0]) {
			float *r = (float *)GP(a[0]);
			fprintf(stderr, " sret %g %g %g %g", r[0], r[1], r[2], r[3]);
		}
		fprintf(stderr, "\n");
		return;
	}
	b->call(c, b);
}

// ---- Objective-C messages ----------------------------------------------------------------------
typedef struct MsgSig {
	Class cls;
	SEL sel;
	IMP imp;
	uint32_t guest;
	int n;
	XLType *t[32];
	ffi_type *ft[32];
	ffi_cif cif;
	int variadic, objs, fmt;
	int counts[32];      // array arguments: index of the count argument + 1, -2 for a range length, -3 for [self count]
	int planes;          // initWithBitmapDataPlanes:...: 1, 2 with the bitmapFormat: argument
	void (*special)(XLCPU *c, struct MsgSig *m, id self, uint32_t a0);
} MsgSig;

static XLMap msgcache;

void xl_msgcache_flush(void)
{
	os_unfair_lock_lock(&msgcache.lock);
	if (msgcache.cap) {
		memset(msgcache.keys, 0, msgcache.cap * 8);
		memset(msgcache.vals, 0, msgcache.cap * 8);
		msgcache.n = 0;
	}
	os_unfair_lock_unlock(&msgcache.lock);
}

static XLType *T(const char *s)
{
	return xl_type_parse(&s);
}

// host encoding -> bridge type for methods the SDK table does not know
XLType *xl_from_host_enc(const char *e);
static XLType *from_host_enc(const char *e) { return xl_from_host_enc(e); }
XLType *xl_from_host_enc(const char *e)
{
	while (*e && strchr("rnNoORV", *e))
		e++;
	switch (*e) {
	case 'c': return T("c");
	case 'C': return T("C");
	case 'B': return T("B");
	case 's': return T("s");
	case 'S': return T("S");
	case 'i': return T("i");
	case 'I': return T("I");
	case 'q': return T("l");
	case 'Q': return T("L");
	case 'l': return T("i");
	case 'L': return T("I");
	case 'f': return T("f");
	case 'd': return T("d");
	case 'v': return T("v");
	case '@': case '#': return T("@");
	case ':': return T(":");
	case '*': return T("*");
	case '^':
		// out-parameters whose width differs on the guest are converted both ways
		if (e[1] == '@')
			return T("P@");
		if (e[1] == 'q')
			return T("Pl");
		if (e[1] == 'Q')
			return T("PL");
		if (e[1] == 'd')
			return T("PF");        // CGFloat *
		if (!strncmp(e + 1, "{CGPoint", 8))
			return T("P{CGPoint}");
		if (!strncmp(e + 1, "{CGRect", 7))
			return T("P{CGRect}");
		if (!strncmp(e + 1, "{CGSize", 7))
			return T("P{CGSize}");
		if (!strncmp(e + 1, "{_NSRange", 9))
			return T("P{_NSRange}");
		return T("*");
	case '{': {
		if (!strncmp(e, "{CGRect", 7))
			return T("{CGRect}");
		if (!strncmp(e, "{CGPoint", 8))
			return T("{CGPoint}");
		if (!strncmp(e, "{CGSize", 7))
			return T("{CGSize}");
		if (!strncmp(e, "{_NSRange", 9))
			return T("{_NSRange}");
		if (!strncmp(e, "{CGAffineTransform", 18))
			return T("{CGAffineTransform}");
		char nm[64];
		const char *s = e + 1;
		size_t k = 0;
		while (*s && *s != '=' && *s != '}' && k < 63)
			nm[k++] = *s++;
		nm[k] = 0;
		char buf[80];
		snprintf(buf, sizeof buf, "{%s}", nm);
		return T(buf);
	}
	default: return T("I");
	}
}

static void spec_methodForSelector(XLCPU *c, MsgSig *m, id self, uint32_t a0);
static void spec_bytes(XLCPU *c, MsgSig *m, id self, uint32_t a0);
static void spec_fastenum(XLCPU *c, MsgSig *m, id self, uint32_t a0);
static void spec_perform(XLCPU *c, MsgSig *m, id self, uint32_t a0);

static void array_counts(MsgSig *m)
{
	const char *s = sel_getName(m->sel);
	if (!strcmp(s, "getObjects:range:")) {
		m->counts[3] = -2;
		return;
	}
	if (!strcmp(s, "getObjects:") || !strcmp(s, "getObjects:andKeys:")) {
		// as many elements as the receiver holds
		for (int i = 3; i < m->n; i++)
			if (m->t[i]->kind == 'P')
				m->counts[i] = -3;
		return;
	}
	if (strstr(s, "count:")) {
		// the count is the last integer argument; every P@ before it is an array
		int ci = -1;
		for (int i = m->n - 1; i >= 3; i--)
			if (strchr("lLiI", m->t[i]->kind)) {
				ci = i;
				break;
			}
		if (ci > 0)
			for (int i = 3; i < ci; i++)
				if (m->t[i]->kind == 'P')
					m->counts[i] = ci + 1;
	}
}

static MsgSig *msg_sig(Class cls, SEL sel, IMP imp, int meta, int nargs_hint)
{
	MsgSig *m = calloc(1, sizeof *m);
	m->cls = cls;
	m->sel = sel;
	m->imp = imp;
	int variadic = 0;
	int n = xl_method_sig(sel, cls, meta, NULL, m->t, 32, &variadic);
	if (n < 0) {
		Method me = class_getInstanceMethod(cls, sel);
		const char *enc = me ? method_getTypeEncoding(me) : NULL;
		if (enc) {
			char buf[256];
			method_getReturnType(me, buf, sizeof buf);
			m->t[0] = from_host_enc(buf);
			n = (int)method_getNumberOfArguments(me) + 1;
			if (n > 32)
				n = 32;
			for (int i = 1; i < n; i++) {
				method_getArgumentType(me, i - 1, buf, sizeof buf);
				m->t[i] = from_host_enc(buf);
			}
		} else {
			// unknown method (forwarded): objects in, object out
			n = 3 + nargs_hint;
			m->t[0] = T("@");
			m->t[1] = T("@");
			m->t[2] = T(":");
			for (int i = 3; i < n; i++)
				m->t[i] = T("@");
		}
	}
	m->n = n;
	m->variadic = variadic;
	if (variadic) {
		const char *s = sel_getName(sel);
		if (strcasestr(s, "format"))
			m->fmt = 1;
		else
			m->objs = 1;
	}
	array_counts(m);
	if (!strncmp(sel_getName(sel), "initWithBitmapDataPlanes:", 25))
		m->planes = strstr(sel_getName(sel), "bitmapFormat:") ? 2 : 1;
	for (int i = 0; i < n; i++)
		m->ft[i] = m->t[i]->ffi;
	if (!variadic && ffi_prep_cif(&m->cif, FFI_DEFAULT_ABI, n - 1, m->ft[0], m->ft + 1) != FFI_OK)
		xl_die("ffi_prep_cif failed for %s", sel_getName(sel));
	const char *s = sel_getName(sel);
	if (!strcmp(s, "methodForSelector:") || !strcmp(s, "instanceMethodForSelector:"))
		m->special = spec_methodForSelector;
	else if (!strcmp(s, "bytes") || !strcmp(s, "mutableBytes"))
		m->special = spec_bytes;
	else if (!strcmp(s, "countByEnumeratingWithState:objects:count:"))
		m->special = spec_fastenum;
	else if (!strcmp(s, "performSelector:") || !strcmp(s, "performSelector:withObject:")
		|| !strcmp(s, "performSelector:withObject:withObject:"))
		m->special = spec_perform;
	return m;
}

static void msg_nil(XLCPU *c, int kind)
{
	c->r[EAX] = 0;
	c->r[EDX] = 0;
	if (kind == XL_MSG_FPRET)
		fpush(c, 0);
	c->r[ESP] += (kind == XL_MSG_STRET || kind == XL_MSG_SUPER_STRET) ? 8 : 4;
}

// NSBitmapImageRep with planes == NULL keeps its pixels in host memory, which
// the guest cannot reach through bitmapData: give it planes in the window
@interface XLGuestPlanes : NSObject {
@public
	uint32_t buf[5];
	uint32_t size;
}
@end
@implementation XLGuestPlanes
- (void)dealloc
{
	for (int i = 0; i < 5; i++)
		if (buf[i])
			xl_free(buf[i]);
	[super dealloc];
}
@end

// host memory shared with the guest (xl_remap) while an object holds it
@interface XLRemapOwner : NSObject {
@public
	uint32_t g;
	size_t n;
	const void *hp;     // the host buffer it shows
	int kind;           // 0 data, 1 bitmap
}
@end
@implementation XLRemapOwner
- (void)dealloc
{
	extern size_t xl_live[2];
	xl_live[kind] -= n;
	xl_unmap(g, n);
	[super dealloc];
}
@end

// Reps whose pixels the host allocated (decoded images): -bitmapData hands out
// the rep's own buffer mapped into the window, so guest writes (pixel edits,
// channel copies between images) reach the rep. RGB without alpha is decoded
// into 32-bit pixels now;
// the 2013 AppKit packed it in 24 bits, which the guest's pixel loops assume,
// so such reps are shown packed: bitsPerPixel, bytesPerRow and a copy (refreshed on
// every call; guest writes to it do not reach the rep) agree.
static int padded_rgb(NSBitmapImageRep *rep)
{
	return [rep samplesPerPixel] == 3 && [rep bitsPerPixel] == 32 && [rep bitsPerSample] == 8 && ![rep isPlanar]
		&& !xl_in_window([rep bitmapData]);
}

size_t xl_live[2];
static void *bitmap_copy(NSBitmapImageRep *rep, const void *hp)
{
	int pack = padded_rgb(rep);
	NSInteger w = [rep pixelsWide], h = [rep pixelsHigh], sbpr = [rep bytesPerRow];
	NSInteger n = pack ? w * 3 * h : [rep bytesPerPlane];
	if (n <= 0 || n > 0x10000000)
		return NULL;
	if (!pack && ![rep isPlanar]) {
		static char shared_key;
		XLRemapOwner *own = objc_getAssociatedObject(rep, &shared_key);
		if (own && own->hp == hp && own->n == (size_t)n)
			return GP(own->g);
		uint32_t g = xl_remap(hp, (size_t)n);
		if (g) {
			own = [XLRemapOwner new];
			own->g = g;
			own->n = (size_t)n;
			own->hp = hp;
			own->kind = 1;
			xl_live[1] += own->n;
			objc_setAssociatedObject(rep, &shared_key, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[own release];
			return GP(g);
		}
	}
	XLGuestPlanes *gp = objc_getAssociatedObject(rep, &bitmap_copy);
	if (!gp || gp->size != (uint32_t)n) {
		gp = [[XLGuestPlanes new] autorelease];
		gp->buf[0] = xl_malloc((uint32_t)n);
		gp->size = (uint32_t)n;
		objc_setAssociatedObject(rep, &bitmap_copy, gp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	uint8_t *d = GP(gp->buf[0]);
	if (pack) {
		const uint8_t *src = hp;
		int skip_first = ([rep bitmapFormat] & NSBitmapFormatAlphaFirst) != 0;
		for (NSInteger y = 0; y < h; y++) {
			const uint8_t *r = src + y * sbpr + skip_first;
			uint8_t *o = d + y * w * 3;
			for (NSInteger x = 0; x < w; x++, r += 4, o += 3) {
				o[0] = r[0];
				o[1] = r[1];
				o[2] = r[2];
			}
		}
	} else
		memcpy(d, hp, (size_t)n);
	return d;
}

static XLGuestPlanes *guest_planes(MsgSig *m, uint32_t a0, unsigned char **hp, long *obpr, long *obpp)
{
	uint32_t *g = (uint32_t *)GP(a0 + 8);   // planes w h bps spp alpha planar csname [format] bpr bpp
	if (g[0])
		return nil;
	int32_t w = (int32_t)g[1], h = (int32_t)g[2], bps = (int32_t)g[3], spp = (int32_t)g[4];
	int planar = (uint8_t)g[6];
	int k = m->planes == 2 ? 9 : 8;
	int32_t bpr = (int32_t)g[k], bpp = (int32_t)g[k + 1];
	if (w <= 0 || h <= 0 || bps <= 0 || spp <= 0)
		return nil;
	if (!bpp)
		bpp = planar ? bps : bps * spp;
	if (!bpr)
		bpr = (w * bpp + 7) / 8;
	*obpr = bpr;    // tightly packed rows, as the old AppKit made them: callers upload without a row length
	*obpp = bpp;
	int np = planar ? spp : 1;
	if (np > 5)
		return nil;
	XLGuestPlanes *gp = [XLGuestPlanes new];
	for (int i = 0; i < np; i++) {
		gp->buf[i] = xl_calloc((uint32_t)bpr * (uint32_t)h);
		hp[i] = GP(gp->buf[i]);
	}
	return gp;
}

// NSTextAlignment: i386 and x86_64 have right 1, center 2; arm64 has center 1,
// right 2. The guest's values are swapped on the way in and out of messages
// that take or return an alignment.
#if defined(__arm64__)
// 1: the first argument is an alignment, 2: the return value is, 0: neither
static int align_sel(SEL s)
{
	if (s == @selector(setAlignment:) || s == @selector(setAlignment:range:) || s == @selector(setTextAlignment:)
		|| s == @selector(setTitleAlignment:) || s == @selector(initWithTextAlignment:location:options:))
		return 1;
	if (s == @selector(alignment) || s == @selector(textAlignment) || s == @selector(titleAlignment))
		return 2;
	return 0;
}

static inline long swap_align(long a) { return a == 1 ? 2 : a == 2 ? 1 : a; }
#endif

static void msg_host(XLCPU *c, MsgSig *m, id self, uint32_t a0, int stret)
{
	Args A;
	A.tmp.n = 0;
	memset(A.big, 0, sizeof A.big);
	XLType *rt = m->t[0];
	uint32_t sret = stret || guest_mem_ret(rt) ? *(uint32_t *)GP(c->r[ESP] + 4) : 0;
	A.vals[0] = A.store[0];
	*(id *)A.store[0] = self;
	A.ft[0] = &ffi_type_pointer;
	A.vals[1] = A.store[1];
	*(SEL *)A.store[1] = m->sel;
	A.ft[1] = &ffi_type_pointer;
	uint32_t g = a0 + 8;
	uint32_t argaddr[32];
	for (int i = 3; i < m->n; i++) {
		argaddr[i] = g;
		int cnt = 0;
		if (m->counts[i] == -2)
			cnt = (int)*(uint32_t *)GP(g + 8);     // range length after the pointer
		else if (m->counts[i] == -3)
			cnt = (int)[(NSArray *)self count];
		else if (m->counts[i] > 0) {
			uint32_t ga = g;
			for (int k = i; k < m->counts[i] - 1; k++)
				ga += (m->t[k]->gsize + 3) & ~3u;
			cnt = (int)*(int32_t *)GP(ga);
			if (cnt < 0)
				cnt = 0;
		}
		if (m->t[i]->kind == '^') {
			cb_ctx = sel_getName(m->sel);
			char ctx[160];
			snprintf(ctx, sizeof ctx, "%s.%d", sel_getName(m->sel), i - 3);
			cb_ctx = ctx;
			g += conv_arg(&A, i - 1, m->t[i], g, cnt);
			cb_ctx = NULL;
		} else {
			g += conv_arg(&A, i - 1, m->t[i], g, cnt);
		}
	}
	int n = m->n - 1;
	ffi_cif vcif, *cif = &m->cif;
	if (m->variadic) {
		int fi = -1;
		if (m->fmt)
			for (int i = m->n - 1; i >= 3; i--)
				if (m->t[i]->kind == '@') {
					fi = i - 1;
					break;
				}
		n = var_args(m->t, m->n - 1, g, &A, m->objs, fi, 0, NULL, 0);
		if (ffi_prep_cif_var(&vcif, FFI_DEFAULT_ABI, m->n - 1, n, rt->ffi, A.ft) != FFI_OK)
			xl_die("ffi_prep_cif_var failed for %s", sel_getName(m->sel));
		cif = &vcif;
	}
	static const char *logsel = (const char *)1;
	if (logsel == (const char *)1)
		logsel = getenv("XL_LOGSEL");
	int logit = xl_verbose > 5 || (logsel && strstr(sel_getName(m->sel), logsel));
	if (logit && xl_verbose <= 5) {
		char ks[40] = {0};
		for (int i = 0; i < m->n && i < 39; i++)
			ks[i] = m->t[i]->kind;
		xl_log("msg [%s %s] self %p types %s thread %s", class_getName(object_getClass(self)), sel_getName(m->sel), self, ks,
			[NSThread isMainThread] ? "main" : [[NSString stringWithFormat:@"%p", [NSThread currentThread]] UTF8String]);
	}
	if (logit)
		for (int i = 3; i < m->n && i - 1 < n; i++)
			if (m->t[i]->kind == '@') {
				id o = *(id *)A.vals[i - 1];
				if ([o isKindOfClass:[NSString class]])
					xl_log("    arg %d: \"%s\"", i - 3, [(NSString *)o UTF8String]);
				else if ([o isKindOfClass:[NSURLResponse class]])
					xl_log("    arg %d: %s mime %s len %lld enc %s policy %lu", i - 3, [[o description] UTF8String], [[(NSURLResponse *)o MIMEType] UTF8String],
						[(NSURLResponse *)o expectedContentLength], [[(NSURLResponse *)o textEncodingName] UTF8String],
						m->n > 5 ? (unsigned long)*(unsigned long *)A.vals[4] : 99);
				else if ([o isKindOfClass:[NSData class]]) {
					const unsigned char *d = [(NSData *)o bytes];
					xl_log("    arg %d: NSData %lu bytes %02x%02x%02x%02x%02x%02x%02x%02x", i - 3, (unsigned long)[(NSData *)o length],
						d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]);
					if (getenv("XL_DUMPDATA")) {
						NSString *f = [NSString stringWithFormat:@"%s/dump_%lu.bin", getenv("XL_DUMPDATA"), (unsigned long)[(NSData *)o length]];
						[(NSData *)o writeToFile:f atomically:NO];
					}
				}
				else
					xl_log("    arg %d: %s %p", i - 3, o ? class_getName(object_getClass(o)) : "nil", o);
			}
	unsigned char *hplanes[5] = {0};
	long gbpr = 0, gbpp = 0;
	XLGuestPlanes *gplanes = m->planes ? guest_planes(m, a0, hplanes, &gbpr, &gbpp) : nil;
	if (gplanes) {
		int k = m->planes == 2 ? 9 : 8;
		*(unsigned char ***)A.vals[2] = hplanes;
		*(long *)A.vals[2 + k] = gbpr;
		*(long *)A.vals[3 + k] = gbpp;
	}
	// tracking rect and tool tip tags are pointer-sized: the guest holds handles
	int tagret = m->sel == @selector(addTrackingRect:owner:userData:assumeInside:) ||
		m->sel == @selector(addToolTipRect:owner:userData:);
	if ((m->sel == @selector(removeTrackingRect:) || m->sel == @selector(removeToolTip:)) && m->n > 3) {
		uint32_t t = *(uint32_t *)GP(a0 + 8);
		*(long *)A.vals[2] = t ? (long)xl_p(t) : 0;
	}
#if defined(__arm64__)
	int align = align_sel(m->sel);
	if (align == 1 && m->n > 3 && strchr("lLqQ", m->t[3]->kind))
		*(long *)A.vals[2] = swap_align(*(long *)A.vals[2]);
#endif
	uint8_t rv[256] __attribute__((aligned(16)));
	memset(rv, 0, 16);
	NSException *exc = nil;
	// windows may only be used on the main thread now (the 2013 frameworks keep a
	// hidden window per thread): messages to them run there
	static Class window_class;
	if (!window_class)
		window_class = NSClassFromString(@"NSWindow");
	if (![NSThread isMainThread] && [self isKindOfClass:window_class]) {
		__block NSException *mexc = nil;
		uint8_t *rvp = rv;
		void **vals = A.vals;
		dispatch_sync(dispatch_get_main_queue(), ^{
			@try {
				ffi_call(cif, FFI_FN(m->imp), rvp, vals);
			} @catch (NSException *e) {
				mexc = [e retain];
			}
		});
		exc = mexc;
	} else
	@try {
		ffi_call(cif, FFI_FN(m->imp), rv, A.vals);
	} @catch (NSException *e) {
		exc = [e retain];
	}
	if (exc) {
		if (xl_verbose > 0) {
			uint32_t *ga = (uint32_t *)GP(a0);
			xl_log("  raised by -[%s %s] args %08x %08x %08x %08x from %s", class_getName(object_getClass(self)),
				sel_getName(m->sel), ga[2], ga[3], ga[4], ga[5], xl_name_at(*(uint32_t *)GP(c->r[ESP])));
		}
		args_free(&A, n);
		c->r[ESP] += sret ? 8 : 4;
		xl_exc_from_host(c, exc);    // longjmps into a guest handler or rethrows
		return;
	}
	if (gplanes) {
		id r = *(id *)rv;
		if (r)
			objc_setAssociatedObject(r, &guest_planes, gplanes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[gplanes release];
	}
	if (rt->kind == '*' && *(void **)rv && !xl_in_window(*(void **)rv) && m->sel == @selector(bitmapData)
		&& [self isKindOfClass:[NSBitmapImageRep class]])
		*(void **)rv = bitmap_copy(self, *(void **)rv);
	else if ((m->sel == @selector(bitsPerPixel) || m->sel == @selector(bytesPerRow) || m->sel == @selector(bytesPerPlane))
		&& [self isKindOfClass:[NSBitmapImageRep class]] && padded_rgb(self)) {
		NSInteger w = [self pixelsWide];
		*(NSInteger *)rv = m->sel == @selector(bitsPerPixel) ? 24 : m->sel == @selector(bytesPerRow) ? w * 3
			: w * 3 * [self pixelsHigh];
	}
	copy_out(&A);
#if defined(__arm64__)
	if (align == 2 && strchr("lLqQ", rt->kind))
		*(long *)rv = swap_align(*(long *)rv);
#endif
	set_ret(c, rt, rv, sret, 1);
	if (tagret)
		c->r[EAX] = *(long *)rv ? xl_h((void *)*(long *)rv) : 0;
	if (logit)
		for (int i = 3; i < m->n; i++)
			if (m->t[i]->kind == 'P') {
				uint32_t p = *(uint32_t *)GP(a0 + 4 * (i - 1));
				xl_log("    arg %d: P%c %08x -> %08x %08x", i - 3, m->t[i]->sub->kind, p, p ? *(uint32_t *)GP(p) : 0,
					p ? *(uint32_t *)GP(p + 4) : 0);
			}
	if (logit)
		xl_log("    -> eax %08x", c->r[EAX]);
	args_free(&A, n);
	c->r[ESP] += sret ? 8 : 4;
}

void xl_msgsend(XLCPU *c, int kind)
{
	int stret = kind == XL_MSG_STRET || kind == XL_MSG_SUPER_STRET;
	int super = kind == XL_MSG_SUPER || kind == XL_MSG_SUPER_STRET;
	uint32_t a0 = c->r[ESP] + 4 + (stret ? 4 : 0);
	uint32_t selfh, clsh = 0;
	if (super) {
		uint32_t sup = *(uint32_t *)GP(a0);
		selfh = *(uint32_t *)GP(sup);
		clsh = *(uint32_t *)GP(sup + 4);
	} else {
		selfh = *(uint32_t *)GP(a0);
	}
	uint32_t gs = *(uint32_t *)GP(a0 + 4);
	if (!selfh) {
		msg_nil(c, kind);
		return;
	}
	id self = (id)xl_p(selfh);
	xl_bytes_flush(self);
	if (!self) {
		uint32_t ret = *(uint32_t *)GP(c->r[ESP]);
		(void)ret;
		xl_log("message %s to bad handle %08x (cell word %08x %08x) from %s", gs ? (char *)GP(gs) : "?", selfh,
			*(uint32_t *)GP(selfh - 8), *(uint32_t *)GP(selfh - 4), xl_name_at(*(uint32_t *)GP(c->r[EBP] + 4)));
		msg_nil(c, kind);
		return;
	}
	SEL sel = xl_hsel(gs);
	Class cls = super ? (Class)xl_p(clsh) : object_getClass(self);
	if (xl_verbose > 4)
		xl_log("msg %c[%s %s]", super ? 'S' : ' ', class_getName(cls), sel_getName(sel));
	uint64_t key = ((uint64_t)(uintptr_t)cls * 31) ^ (uint64_t)(uintptr_t)sel;
	MsgSig *m = (MsgSig *)xl_map_get(&msgcache, key);
	if (!m || m->cls != cls || m->sel != sel) {
		IMP imp = class_getMethodImplementation(cls, sel);
		uint32_t g = xl_guest_imp_of(imp);
		if (g) {
			m = calloc(1, sizeof *m);
			m->cls = cls;
			m->sel = sel;
			m->imp = imp;
			m->guest = g;
		} else {
			int nargs = 0;
			for (const char *s = sel_getName(sel); *s; s++)
				nargs += *s == ':';
			m = msg_sig(cls, sel, imp, class_isMetaClass(cls), nargs);
		}
		xl_map_put(&msgcache, key, (uint64_t)m);
	}
	if (m->guest) {
		if (super)
			*(uint32_t *)GP(a0) = selfh;
		xl_call(c, m->guest);
		return;
	}
	if (m->special) {
		m->special(c, m, self, a0);
		return;
	}
	msg_host(c, m, self, a0, stret);
}

// ---- special messages -----------------------------------------------------------------------------
static void spec_methodForSelector(XLCPU *c, MsgSig *m, id self, uint32_t a0)
{
	SEL s = xl_hsel(*(uint32_t *)GP(a0 + 8));
	IMP imp = !strcmp(sel_getName(m->sel), "methodForSelector:")
		? class_getMethodImplementation(object_getClass(self), s)
		: class_getMethodImplementation((Class)self, s);
	uint32_t g = xl_guest_imp_of(imp);
	c->r[EAX] = g ? g : xl_thunk_for("_objc_msgSend");
	c->r[ESP] += 4;
}

// -performSelector:withObject: of a translated method: the method is called
// with the guest's own words, as on i386, where the "objects" are often
// integers in disguise (an index, a flag) that are no object handles
// A host method is called the same way, its arguments converted by its own
// signature (a BOOL or an integer passed as an object stays one).
static void spec_perform(XLCPU *c, MsgSig *m, id self, uint32_t a0)
{
	uint32_t gs = *(uint32_t *)GP(a0 + 8);
	SEL s = gs ? xl_hsel(gs) : NULL;
	Class cls = object_getClass(self);
	IMP imp = s && [self respondsToSelector:s] ? class_getMethodImplementation(cls, s) : NULL;
	uint32_t g = imp ? xl_guest_imp_of(imp) : 0;
	MsgSig *t = NULL;
	if (imp && !g) {
		uint64_t key = ((uint64_t)(uintptr_t)cls * 31) ^ (uint64_t)(uintptr_t)s;
		t = (MsgSig *)xl_map_get(&msgcache, key);
		if (!t || t->cls != cls || t->sel != s) {
			int nargs = 0;
			for (const char *p = sel_getName(s); *p; p++)
				nargs += *p == ':';
			t = msg_sig(cls, s, imp, class_isMetaClass(cls), nargs);
			xl_map_put(&msgcache, key, (uint64_t)t);
		}
		Method me = class_getInstanceMethod(cls, s);
		const char *rt = me ? method_getTypeEncoding(me) : NULL;
		if (t->special || !rt || strchr("{df", *rt))   // returns nothing performSelector: could pass on
			t = NULL;
	}
	if (!g && !t) {
		msg_host(c, m, self, a0, 0);
		return;
	}
	int n = 0;
	for (const char *p = sel_getName(m->sel); *p; p++)
		n += *p == ':';
	// self, performSelector:..., sel, objects -> self, sel, objects (the callee owns its arguments)
	for (int i = 0; i < n; i++)
		*(uint32_t *)GP(a0 + 4 + 4 * i) = *(uint32_t *)GP(a0 + 8 + 4 * i);
	if (g)
		xl_call(c, g);
	else
		msg_host(c, t, self, a0, 0);
}

static char bytes_key;


// A short buffer (less than a page of the window) is a copy in the guest heap kept
// with the object and synced both ways on every -bytes / -mutableBytes: what the
// guest wrote into it since the last call reaches a mutable object's buffer, what
// the host changed reaches the copy (the host wins when both did).
// Guest writes into a mutable object's copy also reach its buffer when the
// object next goes to the host (xl_bytes_flush): zlib's uncompress into
// -mutableBytes, then the data handed to WebKit (Surf The Ages' pages).
@interface XLBytesCopy : NSObject {
@public
	uint32_t g;
	size_t n;
	const void *hp;
	uint8_t *snap;      // contents at the last sync
	id owner;           // the mutable object (not retained), when tracked
}
@end

static XLMap mutable_copies;   // mutable object -> its XLBytesCopy
int xl_bytes_pending;          // how many there are

@implementation XLBytesCopy
- (void)dealloc
{
	if (owner) {
		xl_map_del(&mutable_copies, (uint64_t)(uintptr_t)owner);
		__atomic_sub_fetch(&xl_bytes_pending, 1, __ATOMIC_RELAXED);
	}
	xl_free(g);
	free(snap);
	[super dealloc];
}
@end

void xl_bytes_flush_slow(id o)
{
	XLBytesCopy *cp = (XLBytesCopy *)(uintptr_t)xl_map_get(&mutable_copies, (uint64_t)(uintptr_t)o);
	if (!cp)
		return;
	uint8_t *gb = GP(cp->g);
	if (!memcmp(gb, cp->snap, cp->n))
		return;
	if ([(NSMutableData *)o length] != cp->n || [(NSMutableData *)o mutableBytes] != cp->hp)
		return;     // the host moved or resized the buffer: the copy is stale
	memcpy((void *)cp->hp, gb, cp->n);
	memcpy(cp->snap, gb, cp->n);
}

static uint32_t bytes_copy(id self, const void *p, NSUInteger len)
{
	static char copy_key;
	XLBytesCopy *cp = objc_getAssociatedObject(self, &copy_key);
	if (cp && cp->hp == p && cp->n == len) {
		uint8_t *gb = GP(cp->g);
		int host = memcmp(p, cp->snap, len) != 0, guest = memcmp(gb, cp->snap, len) != 0;
		if (host) {
			memcpy(gb, p, len);
			memcpy(cp->snap, p, len);
		} else if (guest && [self isKindOfClass:[NSMutableData class]]) {
			memcpy((void *)p, gb, len);
			memcpy(cp->snap, gb, len);
		}
		return cp->g;
	}
	cp = [XLBytesCopy new];
	cp->g = xl_malloc((uint32_t)len + 1);
	cp->n = len;
	cp->hp = p;
	cp->snap = malloc(len + 1);
	memcpy(GP(cp->g), p, len);
	memcpy(cp->snap, p, len);
	objc_setAssociatedObject(self, &copy_key, cp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if ([self isKindOfClass:[NSMutableData class]]) {
		XLBytesCopy *old = (XLBytesCopy *)(uintptr_t)xl_map_get(&mutable_copies, (uint64_t)(uintptr_t)self);
		if (old)
			old->owner = nil;   // replaced: released below by the association
		else
			__atomic_add_fetch(&xl_bytes_pending, 1, __ATOMIC_RELAXED);
		cp->owner = self;
		xl_map_put(&mutable_copies, (uint64_t)(uintptr_t)self, (uint64_t)(uintptr_t)cp);
	}
	[cp release];
	return cp->g;
}

static void spec_bytes(XLCPU *c, MsgSig *m, id self, uint32_t a0)
{
	(void)a0;
	const void *p = ((const void *(*)(id, SEL))m->imp)(self, m->sel);
	NSUInteger len = [(NSData *)self length];
	uint32_t g = 0;
	if (p && len < vm_page_size)
		g = bytes_copy(self, p, len);
	else if (p) {
		// longer buffers are shared with the guest
		XLRemapOwner *own = objc_getAssociatedObject(self, &bytes_key);
		if (own && own->n == len && own->hp == p)
			g = own->g;     // the host buffer did not move
		if (!g) {
			g = xl_remap(p, len);
			if (!g) {
				// the window's shared area is full: a synced copy in the heap instead
				static int told;
				if (!told++)
					xl_log("bytes: shared area full (%zu MB of data, %zu MB of bitmaps); copying instead",
						xl_live[0] >> 20, xl_live[1] >> 20);
				g = bytes_copy(self, p, len);
			} else {
				own = [XLRemapOwner new];
				own->g = g;
				own->n = len;
				own->hp = p;
				xl_live[0] += own->n;
				objc_setAssociatedObject(self, &bytes_key, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
				[own release];
			}
		}
	}
	c->r[EAX] = g;
	c->r[ESP] += 4;
}

// NSFastEnumerationState (guest): state, itemsPtr, mutationsPtr, extra[5]
static void spec_fastenum(XLCPU *c, MsgSig *m, id self, uint32_t a0)
{
	uint32_t gst = *(uint32_t *)GP(a0 + 8), gobjs = *(uint32_t *)GP(a0 + 12);
	uint32_t len = *(uint32_t *)GP(a0 + 16);
	NSFastEnumerationState st;
	memset(&st, 0, sizeof st);
	st.state = *(uint32_t *)GP(gst);
	// keep the host state's extra words in the guest extra area via a side table
	static XLMap extra;
	unsigned long *saved = (unsigned long *)xl_map_get(&extra, gst);
	if (st.state && saved) {
		memcpy(st.extra, saved, sizeof st.extra);
		st.mutationsPtr = (unsigned long *)saved[5];
	}
	id buf[64];
	if (len > 64)
		len = 64;
	NSUInteger n = ((NSUInteger (*)(id, SEL, NSFastEnumerationState *, id *, NSUInteger))m->imp)(self, m->sel, &st, buf, len);
	if (!saved) {
		saved = calloc(6, sizeof(unsigned long));
		xl_map_put(&extra, gst, (uint64_t)saved);
	}
	memcpy(saved, st.extra, sizeof st.extra);
	saved[5] = (unsigned long)st.mutationsPtr;
	*(uint32_t *)GP(gst) = (uint32_t)st.state;
	for (NSUInteger i = 0; i < n; i++)
		*(uint32_t *)GP(gobjs + 4 * i) = xl_hobj(st.itemsPtr[i]);
	*(uint32_t *)GP(gst + 4) = gobjs;
	// mutations: point at a guest word that mirrors the host value
	*(uint32_t *)GP(gst + 8) = gst + 12;
	*(uint32_t *)GP(gst + 12) = st.mutationsPtr ? (uint32_t)*st.mutationsPtr : 0;
	c->r[EAX] = (uint32_t)n;
	c->r[ESP] += 4;
}
