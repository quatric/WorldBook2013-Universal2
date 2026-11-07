// The guest window, the translated image, dispatch of indirect calls, imports
// and calls from the host into guest code.
#import <Foundation/Foundation.h>
#include "ppcrt.h"
#include <sys/mman.h>
#include <stdarg.h>
#include <mach/mach_time.h>
#include <execinfo.h>

uint8_t *XG;
PPC *ppc_cpu;
static PPC cpu0;
int ppc_verbose, ppc_trace_on;
char ppc_app_path[1024], ppc_app_dir[1024];

void ppc_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "[ppc] ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

// ---- functions ----------------------------------------------------------

static const PPCFunc *find_func(uint32_t a)
{
	size_t lo = 0, hi = ppc_nfuncs;
	while (lo < hi) {
		size_t m = (lo + hi) / 2;
		if (ppc_funcs[m].addr < a)
			lo = m + 1;
		else
			hi = m;
	}
	return lo < ppc_nfuncs && ppc_funcs[lo].addr == a ? &ppc_funcs[lo] : NULL;
}

const char *ppc_func_name(uint32_t addr)
{
	// the function containing addr
	size_t lo = 0, hi = ppc_nfuncs;
	while (lo < hi) {
		size_t m = (lo + hi) / 2;
		if (ppc_funcs[m].addr <= addr)
			lo = m + 1;
		else
			hi = m;
	}
	if (!lo)
		return "?";
	return ppc_funcs[lo - 1].name[0] ? ppc_funcs[lo - 1].name : "(anon)";
}

// ---- imports -------------------------------------------------------------

static Shim *import_fns;
static const char **shim_names;
static Shim *shim_fns;
static int nshims, capshims;

void ppc_register_shims(const char *const *names, const Shim *fns, int n)
{
	if (nshims + n > capshims) {
		capshims = (nshims + n) * 2;
		shim_names = realloc(shim_names, capshims * sizeof *shim_names);
		shim_fns = realloc(shim_fns, capshims * sizeof *shim_fns);
	}
	for (int i = 0; i < n; i++) {
		shim_names[nshims] = names[i];
		shim_fns[nshims] = fns[i];
		nshims++;
	}
}

void ppc_register(const ShimDef *d, int n)
{
	for (int i = 0; i < n; i++)
		ppc_register_shims(&d[i].name, &d[i].fn, 1);
}

static uint8_t *missing_logged;

static void missing(PPC *c, size_t i)
{
	if (!missing_logged[i] || ppc_verbose > 1) {
		missing_logged[i] = 1;
		ppc_log("unimplemented import %s (r3 %08x r4 %08x r5 %08x) from %s", ppc_import_names[i], c->r[3], c->r[4],
			c->r[5], ppc_func_name(LD32(c->r[1] + 8)));
	}
	c->r[3] = 0;
}

// ---- host procedures handed to the guest ----------------------------------

static Shim host_procs[1024];
static int nhost;

uint32_t ppc_host_tvec(Shim fn)
{
	for (int i = 0; i < nhost; i++)
		if (host_procs[i] == fn)
			return IMPORT_TV - 8 * 1024 + 8 * i;
	host_procs[nhost] = fn;
	uint32_t tv = IMPORT_TV - 8 * 1024 + 8 * nhost;
	ST32(tv, HOSTCB_CODE + 4 * nhost);
	ST32(tv + 4, 0);
	nhost++;
	return tv;
}

// ---- dispatch -----------------------------------------------------------

static int depth;
static int trace_calls;

void ppc_call(PPC *c, uint32_t code)
{
	if (code >= IMPORT_CODE) {
		size_t i = (code - IMPORT_CODE) / 4;
		if (i < ppc_nimports) {
			if (trace_calls)
				ppc_log("%*s-> %s(%08x, %08x, %08x, %08x)", depth, "", ppc_import_names[i], c->r[3], c->r[4], c->r[5], c->r[6]);
			if (import_fns[i])
				import_fns[i](c);
			else
				missing(c, i);
			if (trace_calls > 1)
				ppc_log("%*s<- %s = %08x", depth, "", ppc_import_names[i], c->r[3]);
			return;
		}
	} else if (code >= HOSTCB_CODE && code < HOSTCB_CODE + 4 * 1024) {
		host_procs[(code - HOSTCB_CODE) / 4](c);
		return;
	}
	const PPCFunc *f = find_func(code);
	if (!f) {
		ppc_log("call to %08x: no translated function there (from %s, lr %08x)", code, ppc_func_name(c->lr - 4), c->lr);
		ppc_backtrace(c);
		abort();
	}
	f->fn(c);
}

void ppc_trace_fn(PPC *c, uint32_t addr)
{
	(void)c;
	const PPCFunc *f = find_func(addr);
	ppc_log("fn %08x %s r3=%08x r4=%08x", addr, f && f->name[0] ? f->name : "", c->r[3], c->r[4]);
}

void ppc_backtrace(PPC *c)
{
	uint32_t sp = c->r[1];
	ppc_log("  at lr %08x %s", c->lr, ppc_func_name(c->lr - 4));
	for (int i = 0; i < 40 && sp >= STACK_TOP - STACK_SIZE && sp < STACK_TOP; i++) {
		uint32_t next = LD32(sp);
		if (next <= sp || next >= STACK_TOP)
			break;
		uint32_t lr = LD32(next + 8);
		ppc_log("  frame %08x lr %08x %s", next, lr, ppc_func_name(lr - 4));
		sp = next;
	}
}

static void host_backtrace(void)
{
	void *b[64];
	int n = backtrace(b, 64);
	backtrace_symbols_fd(b, n, 2);
}

void ppc_trap(PPC *c, uint32_t addr)
{
	ppc_log("trap at %08x in %s", addr, ppc_func_name(addr));
	ppc_backtrace(c);
	host_backtrace();
	abort();
}

void ppc_unimpl(PPC *c, uint32_t addr, uint32_t w)
{
	ppc_log("unimplemented instruction %08x at %08x in %s", w, addr, ppc_func_name(addr));
	ppc_backtrace(c);
	abort();
}

uint32_t ppc_timebase(int spr)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	// a 25 MHz time base (the 4-cycle bus clock of a 100 MHz bus)
	uint64_t ns = mach_absolute_time() * tb.numer / tb.denom;
	uint64_t t = ns / 40;
	return spr == 269 ? (uint32_t)(t >> 32) : (uint32_t)t;
}

// ---- calls into the guest ---------------------------------------------------

uint32_t ppc_callback(uint32_t tvec, int n, const uint32_t *args)
{
	PPC *c = ppc_cpu;
	PPC save = *c;
	uint32_t code = LD32(tvec), toc = LD32(tvec + 4);
	uint32_t frame = 24 + 4 * (n > 8 ? n : 8) + 64;
	uint32_t sp = (c->r[1] - frame - 64) & ~15u;
	ST32(sp, c->r[1]);   // back chain
	for (int i = 0; i < n; i++) {
		if (i < 8)
			c->r[3 + i] = args[i];
		ST32(sp + 24 + 4 * i, args[i]);
	}
	c->r[1] = sp;
	c->r[2] = toc;
	c->lr = 0;
	depth += 2;
	ppc_call(c, code);
	depth -= 2;
	uint32_t r = c->r[3];
	double f1 = c->f[1].d;
	*c = save;
	c->f[1].d = f1;   // a floating-point result, for the callers that want it
	return r;
}

uint32_t ppc_cb0(uint32_t t) { return ppc_callback(t, 0, NULL); }
uint32_t ppc_cb1(uint32_t t, uint32_t a) { return ppc_callback(t, 1, &a); }
uint32_t ppc_cb2(uint32_t t, uint32_t a, uint32_t b) { uint32_t v[] = {a, b}; return ppc_callback(t, 2, v); }
uint32_t ppc_cb3(uint32_t t, uint32_t a, uint32_t b, uint32_t c) { uint32_t v[] = {a, b, c}; return ppc_callback(t, 3, v); }
uint32_t ppc_cb4(uint32_t t, uint32_t a, uint32_t b, uint32_t c, uint32_t d)
{
	uint32_t v[] = {a, b, c, d};
	return ppc_callback(t, 4, v);
}
uint32_t ppc_cb5(uint32_t t, uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e)
{
	uint32_t v[] = {a, b, c, d, e};
	return ppc_callback(t, 5, v);
}

// ---- tokens -----------------------------------------------------------------

typedef struct { uint32_t addr, tag; void *obj; } Tok;
static Tok *toks;
static size_t ntoks, captoks;

uint32_t tok_new(void *obj, uint32_t size, uint32_t tag)
{
	uint32_t a = gcalloc(size < 16 ? 16 : size);
	if (ntoks == captoks) {
		captoks = captoks ? captoks * 2 : 256;
		toks = realloc(toks, captoks * sizeof *toks);
	}
	// keep sorted by address
	size_t i = ntoks;
	while (i > 0 && toks[i - 1].addr > a) {
		toks[i] = toks[i - 1];
		i--;
	}
	toks[i] = (Tok){a, tag, obj};
	ntoks++;
	return a;
}

static Tok *tok_find(uint32_t t)
{
	size_t lo = 0, hi = ntoks;
	while (lo < hi) {
		size_t m = (lo + hi) / 2;
		if (toks[m].addr < t)
			lo = m + 1;
		else
			hi = m;
	}
	return lo < ntoks && toks[lo].addr == t ? &toks[lo] : NULL;
}

void *tok_get(uint32_t t, uint32_t tag)
{
	Tok *k = tok_find(t);
	return k && (!tag || k->tag == tag) ? k->obj : NULL;
}

void tok_free(uint32_t t)
{
	Tok *k = tok_find(t);
	if (!k)
		return;
	size_t i = k - toks;
	memmove(toks + i, toks + i + 1, (ntoks - i - 1) * sizeof *toks);
	ntoks--;
	gfree(t);
}

// ---- strings ------------------------------------------------------------------

void p2c(uint32_t p, char *out, size_t n)
{
	size_t l = p ? LD8(p) : 0;
	if (l >= n)
		l = n - 1;
	if (l)
		memcpy(out, G(p + 1), l);
	out[l] = 0;
}

void c2p(const char *s, uint32_t p)
{
	size_t l = strlen(s);
	if (l > 255)
		l = 255;
	ST8(p, l);
	memcpy(G(p + 1), s, l);
}

NSString *mac_ns(const void *b, size_t n)
{
	NSString *s = [[NSString alloc] initWithBytes:b length:n encoding:NSMacOSRomanStringEncoding];
	return s ? [s autorelease] : @"";
}

NSString *pstr_ns(uint32_t p)
{
	if (!p)
		return @"";
	return mac_ns(G(p + 1), LD8(p));
}

void ns_pstr(NSString *s, uint32_t p)
{
	NSData *d = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	size_t l = d.length > 255 ? 255 : d.length;
	ST8(p, l);
	memcpy(G(p + 1), d.bytes, l);
}

// ---- start --------------------------------------------------------------------

extern void toolbox_init(void);
extern void mem_init(void);

static void resolve_imports(void)
{
	import_fns = calloc(ppc_nimports, sizeof *import_fns);
	missing_logged = calloc(ppc_nimports, 1);
	for (size_t i = 0; i < ppc_nimports; i++) {
		ST32(IMPORT_TV + 8 * i, IMPORT_CODE + 4 * i);
		ST32(IMPORT_TV + 8 * i + 4, (uint32_t)i);
		for (int k = 0; k < nshims; k++)
			if (!strcmp(shim_names[k], ppc_import_names[i])) {
				import_fns[i] = shim_fns[k];
				break;
			}
	}
	if (ppc_verbose) {
		int n = 0;
		for (size_t i = 0; i < ppc_nimports; i++)
			n += import_fns[i] != NULL;
		ppc_log("%d of %zu imports implemented", n, ppc_nimports);
		for (size_t i = 0; i < ppc_nimports; i++)
			if (!import_fns[i])
				ppc_log("  missing: %s", ppc_import_names[i]);
	}
}

void ppc_start(const char *rsrc_path)
{
	const char *v = getenv("PPC_VERBOSE");
	ppc_verbose = v ? atoi(v) : 0;
	ppc_trace_on = getenv("PPC_TRACE") != NULL;
	v = getenv("PPC_CALLS");
	trace_calls = v ? atoi(v) : 0;
	XG = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
	if (XG == MAP_FAILED) {
		perror("guest window");
		exit(1);
	}
	memcpy(G(CODE_BASE), ppc_code_bin, ppc_code_size);
	memcpy(G(DATA_BASE), ppc_data_bin, ppc_data_size);
	snprintf(ppc_app_path, sizeof ppc_app_path, "%s", rsrc_path);
	ppc_cpu = &cpu0;
	mem_init();
	toolbox_init();
	resolve_imports();
	PPC *c = ppc_cpu;
	c->r[1] = STACK_TOP - 256;
	ST32(c->r[1], 0);
	uint32_t code = LD32(ppc_main_tv), toc = LD32(ppc_main_tv + 4);
	c->r[2] = toc;
	if (getenv("PPC_TEST_FMT")) {
		// format numbers with the program's own sprintf (a test of the floating point code)
		uint32_t fn = 0;
		for (size_t i = 0; i < ppc_nfuncs; i++)
			if (ppc_funcs[i].name && !strcmp(ppc_funcs[i].name, "sprintf"))
				fn = ppc_funcs[i].addr;
		double vals[] = {0, 1, 2.5, 3.75, -1.5, 100, 0.1, 6, 1234.5678};
		uint32_t buf = gcalloc(256), fmt = gstrdup(getenv("PPC_TEST_FMT"));
		for (size_t k = 0; k < sizeof vals / sizeof *vals; k++) {
			uint64_t u;
			memcpy(&u, &vals[k], 8);
			c->r[1] = STACK_TOP - 1024;
			c->r[2] = toc;
			c->r[3] = buf;
			c->r[4] = fmt;
			c->r[5] = (uint32_t)(u >> 32);
			c->r[6] = (uint32_t)u;
			c->f[1].d = vals[k];
			ppc_call(c, fn);
			ppc_log("sprintf(\"%s\", %g) = \"%s\"", getenv("PPC_TEST_FMT"), vals[k], (const char *)G(buf));
		}
		exit(0);
	}
	if (ppc_verbose)
		ppc_log("main %08x (%s) toc %08x", code, ppc_func_name(code), toc);
	ppc_call(c, code);
	ppc_log("main returned");
	exit(0);
}
