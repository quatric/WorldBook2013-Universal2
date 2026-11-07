// Guest/host layouts of the bridge type language and value conversion.
#import <Foundation/Foundation.h>
#include "rt.h"
#include <ffi/ffi.h>

static XLMap struct_cache;    // name hash -> XLType *
static os_unfair_lock type_lock = OS_UNFAIR_LOCK_INIT;

static XLType *mk(char kind, int gs, int ga, int hs, int ha, ffi_type *f)
{
	XLType *t = calloc(1, sizeof *t);
	t->kind = kind;
	t->gsize = gs;
	t->galign = ga;
	t->hsize = hs;
	t->halign = ha;
	t->ffi = f;
	return t;
}

static XLType *prim(char k)
{
	static XLType *cache[128];
	if (cache[(int)k])
		return cache[(int)k];
	XLType *t;
	switch (k) {
	case 'v': t = mk('v', 0, 1, 0, 1, &ffi_type_void); break;
	case 'c': t = mk('c', 1, 1, 1, 1, &ffi_type_sint8); break;
	case 'C': t = mk('C', 1, 1, 1, 1, &ffi_type_uint8); break;
	case 'B': t = mk('B', 1, 1, 1, 1, &ffi_type_uint8); break;
	case 's': t = mk('s', 2, 2, 2, 2, &ffi_type_sint16); break;
	case 'S': t = mk('S', 2, 2, 2, 2, &ffi_type_uint16); break;
	case 'i': t = mk('i', 4, 4, 4, 4, &ffi_type_sint32); break;
	case 'I': case '?': t = mk('I', 4, 4, 4, 4, &ffi_type_uint32); break;
	case 'l': t = mk('l', 4, 4, 8, 8, &ffi_type_sint64); break;
	case 'L': t = mk('L', 4, 4, 8, 8, &ffi_type_uint64); break;
	case 'q': t = mk('q', 8, 4, 8, 8, &ffi_type_sint64); break;
	case 'Q': t = mk('Q', 8, 4, 8, 8, &ffi_type_uint64); break;
	case 'f': t = mk('f', 4, 4, 4, 4, &ffi_type_float); break;
	case 'd': t = mk('d', 8, 4, 8, 8, &ffi_type_double); break;
	case 'F': t = mk('F', 4, 4, 8, 8, &ffi_type_double); break;
	case '@': case 'p': case ':': case '*': case '^': case 'h':
		t = mk(k, 4, 4, 8, 8, &ffi_type_pointer); break;
	default:
		xl_die("bad type letter %c", k);
	}
	cache[(int)k] = t;
	return t;
}

// lay out a struct from its fields (guest: i386 alignment, host: natural)
static void layout(XLType *t, XLType **f, int n)
{
	t->nfields = n;
	t->fields = malloc((n ? n : 1) * sizeof *t->fields);
	t->goff = malloc((n ? n : 1) * 4);
	t->hoff = malloc((n ? n : 1) * 4);
	uint32_t go = 0, ho = 0, ga = 1, ha = 1;
	ffi_type *ft = calloc(1, sizeof *ft);
	ft->type = FFI_TYPE_STRUCT;
	ft->elements = calloc(n + 1, sizeof(ffi_type *));
	for (int i = 0; i < n; i++) {
		XLType *x = f[i];
		t->fields[i] = x;
		go = (go + x->galign - 1) & ~(x->galign - 1);
		ho = (ho + x->halign - 1) & ~(x->halign - 1);
		t->goff[i] = go;
		t->hoff[i] = ho;
		go += x->gsize;
		ho += x->hsize;
		if (x->galign > ga)
			ga = x->galign;
		if (x->halign > ha)
			ha = x->halign;
		ft->elements[i] = x->ffi;
	}
	t->gsize = (go + ga - 1) & ~(ga - 1);
	t->galign = ga;
	t->hsize = (ho + ha - 1) & ~(ha - 1);
	t->halign = ha;
	t->ffi = ft;
}

XLType *xl_type_fields(const char *name, XLType **f, int n)
{
	XLType *t = mk('{', 0, 1, 0, 1, NULL);
	t->name = strdup(name ? name : "?");
	layout(t, f, n);
	return t;
}

XLType *xl_type_struct(const char *name)
{
	uint64_t key = 1469598103934665603ULL;
	for (const char *s = name; *s; s++)
		key = (key ^ (uint8_t)*s) * 1099511628211ULL;
	key |= 1;
	XLType *t = (XLType *)xl_map_get(&struct_cache, key);
	if (t)
		return t;
	size_t lo = 0, hi = xl_sdk_nstructs;
	const char *fields = NULL;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		int r = strcmp(xl_sdk_structs[mid].name, name);
		if (!r) {
			fields = xl_sdk_structs[mid].fields;
			break;
		}
		if (r < 0)
			lo = mid + 1;
		else
			hi = mid;
	}
	if (!fields)
		return NULL;
	// registered before the fields so self-referencing pointers terminate
	t = mk('{', 0, 1, 0, 1, NULL);
	t->name = strdup(name);
	xl_map_put(&struct_cache, key, (uint64_t)t);
	XLType *f[64];
	int n = 0;
	const char *s = fields;
	while (*s && n < 64) {
		f[n++] = xl_type_parse(&s);
		if (*s == '|')
			s++;
	}
	layout(t, f, n);
	return t;
}

XLType *xl_type_parse(const char **ps)
{
	const char *s = *ps;
	XLType *t;
	if (*s == 'P') {
		s++;
		XLType *sub = xl_type_parse(&s);
		t = mk('P', 4, 4, 8, 8, &ffi_type_pointer);
		t->sub = sub;
	} else if (*s == '{') {
		const char *e = strchr(s, '}');
		char name[128];
		size_t n = (size_t)(e - s - 1);
		if (n >= sizeof name)
			n = sizeof name - 1;
		memcpy(name, s + 1, n);
		name[n] = 0;
		t = xl_type_struct(name);
		if (!t) {
			xl_log("unknown struct %s", name);
			t = prim('I');
		}
		s = e + 1;
	} else {
		t = prim(*s);
		s++;
	}
	*ps = s;
	return t;
}

// sig: "ret|arg|arg"; methods start with '-' or '+'
int xl_sig_split(const char *sig, XLType **out, int max)
{
	const char *s = sig;
	if (*s == '-' || *s == '+')
		s++;
	int n = 0;
	while (*s && n < max) {
		out[n++] = xl_type_parse(&s);
		if (*s == '|')
			s++;
		else
			break;
	}
	return n;
}

// ---- conversion ------------------------------------------------------------------------
uint32_t xl_hobj(id o);
uint32_t xl_hptr_out(const void *p);
void *xl_fnptr_g2h(uint32_t g, XLType *t);
uint32_t xl_fnptr_h2g(void *p);

void xl_g2h(XLType *t, uint32_t g, void *h)
{
	uint8_t *src = GP(g);
	switch (t->kind) {
	case 'c': case 'C': case 'B': *(uint8_t *)h = *src; break;
	case 's': case 'S': memcpy(h, src, 2); break;
	case 'i': case 'I': case 'f': memcpy(h, src, 4); break;
	case 'l': { uint32_t v; memcpy(&v, src, 4); *(int64_t *)h = xl_slong_in(v); break; }
	case 'L': { uint32_t v; memcpy(&v, src, 4); *(uint64_t *)h = xl_ulong_in(v); break; }
	case 'q': case 'Q': case 'd': memcpy(h, src, 8); break;
	case 'F': { float v; memcpy(&v, src, 4); *(double *)h = v; break; }
	case '@': case 'p': case 'h': { uint32_t v; memcpy(&v, src, 4); *(void **)h = xl_p(v); break; }
	case ':': { uint32_t v; memcpy(&v, src, 4); *(SEL *)h = v ? xl_hsel(v) : NULL; break; }
	case '*': { uint32_t v; memcpy(&v, src, 4); *(void **)h = v ? GP(v) : NULL; break; }
	case '^': { uint32_t v; memcpy(&v, src, 4); *(void **)h = xl_fnptr_g2h(v, t); break; }
	case 'P': { uint32_t v; memcpy(&v, src, 4); *(void **)h = v ? GP(v) : NULL; break; }
	case '{':
		for (int i = 0; i < t->nfields; i++) {
			if (t->fields[i]->kind == '^') {
				extern __thread const char *cb_ctx;
				static __thread char ctx[96];
				const char *save = cb_ctx;
				snprintf(ctx, sizeof ctx, "%s.%d", t->name, i);
				cb_ctx = ctx;
				xl_g2h(t->fields[i], g + t->goff[i], (uint8_t *)h + t->hoff[i]);
				cb_ctx = save;
			} else
				xl_g2h(t->fields[i], g + t->goff[i], (uint8_t *)h + t->hoff[i]);
		}
		break;
	}
}

void xl_h2g(XLType *t, const void *h, uint32_t g)
{
	uint8_t *dst = GP(g);
	switch (t->kind) {
	case 'c': case 'C': case 'B': *dst = *(const uint8_t *)h; break;
	case 's': case 'S': memcpy(dst, h, 2); break;
	case 'i': case 'I': case 'f': memcpy(dst, h, 4); break;
	case 'l': case 'L': { uint32_t v = xl_long_out(*(const uint64_t *)h); memcpy(dst, &v, 4); break; }
	case 'q': case 'Q': case 'd': memcpy(dst, h, 8); break;
	case 'F': { float v = (float)*(const double *)h; memcpy(dst, &v, 4); break; }
	case '@': { uint32_t v = xl_hobj(*(id const *)h); memcpy(dst, &v, 4); break; }
	case 'p': case 'h': { uint32_t v = xl_h(*(void *const *)h); memcpy(dst, &v, 4); break; }
	case ':': { SEL s = *(SEL const *)h; uint32_t v = s ? xl_gsel(s) : 0; memcpy(dst, &v, 4); break; }
	case '*': case 'P': { uint32_t v = xl_hptr_out(*(void *const *)h); memcpy(dst, &v, 4); break; }
	case '^': { uint32_t v = xl_fnptr_h2g(*(void *const *)h); memcpy(dst, &v, 4); break; }
	case '{':
		for (int i = 0; i < t->nfields; i++)
			xl_h2g(t->fields[i], (const uint8_t *)h + t->hoff[i], g + t->goff[i]);
		break;
	}
}

// host byte pointer handed to the guest
uint32_t xl_hptr_out(const void *p)
{
	if (!p)
		return 0;
	if (xl_in_window(p))
		return GA(p);
	if (xl_verbose > 1)
		xl_log("host pointer %p copied into the window as a string", p);
	return xl_strdup(p);
}
