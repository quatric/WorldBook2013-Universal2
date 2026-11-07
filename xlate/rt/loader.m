// Loads the translated images into the guest window and dispatches calls.
#import <Foundation/Foundation.h>
#include "rt.h"
#include <pthread.h>
#include <math.h>

XLImage *xl_images;
static XLImage *pending;

void xl_register_image(XLImage *im)
{
	im->next = pending;
	pending = im;
}

XLImage *xl_image_named(const char *id)
{
	for (XLImage *im = xl_images; im; im = im->next)
		if (!strcmp(im->name, id))
			return im;
	return NULL;
}

// ---- dispatch ---------------------------------------------------------------------
typedef struct Target { XLFn fn; XLImport *imp; XLFunc *f; } Target;
static XLMap dispatch;      // guest address -> Target *
static XLMap export_map;    // name hash chain is overkill: names -> address via sorted tables
static XLMap export_cache;  // const char * -> address

uint32_t xl_lookup_export(const char *name)
{
	for (XLImage *im = xl_images; im; im = im->next) {
		size_t lo = 0, hi = im->nexports;
		while (lo < hi) {
			size_t mid = (lo + hi) / 2;
			int r = strcmp(im->exports[mid].name, name);
			if (!r)
				return im->exports[mid].addr + *im->slide;
			if (r < 0)
				lo = mid + 1;
			else
				hi = mid;
		}
	}
	return 0;
}

uint32_t xl_export_addr(const char *name)
{
	uint32_t a = (uint32_t)xl_map_get(&export_cache, (uint64_t)name);
	if (a)
		return a;
	a = xl_lookup_export(name);
	if (!a) {
		a = xl_thunk_for(name);
		if (!a)
			xl_die("unresolved export %s", name);
	}
	xl_map_put(&export_cache, (uint64_t)name, a);
	return a;
}

XLFn xl_fn_at(uint32_t addr)
{
	Target *t = (Target *)xl_map_get(&dispatch, addr);
	return t ? t->fn : NULL;
}

const char *xl_name_at(uint32_t addr)
{
	static __thread char bufs[4][256];
	static __thread int which;
	char *buf = bufs[which++ & 3];
	XLImage *best = NULL;
	XLFunc *bf = NULL;
	for (XLImage *im = xl_images; im; im = im->next) {
		uint32_t s = *im->slide;
		if (addr < im->lo + s || addr >= im->lo + s + im->size)
			continue;
		best = im;
		size_t lo = 0, hi = im->nfuncs;
		while (lo < hi) {
			size_t mid = (lo + hi) / 2;
			if (im->funcs[mid].addr + s <= addr)
				lo = mid + 1;
			else
				hi = mid;
		}
		if (lo)
			bf = &im->funcs[lo - 1];
	}
	if (!best) {
		snprintf(buf, 256, "?");
		return buf;
	}
	if (bf)
		snprintf(buf, 256, "%s:%s+%x", best->name, bf->name && *bf->name ? bf->name : "?", addr - bf->addr - *best->slide);
	else
		snprintf(buf, 256, "%s:+%x", best->name, addr - *best->slide);
	return buf;
}

// ---- thunks: guest addresses for host functions -------------------------------------
static XLImport thunk_imps[(XL_THUNK_HI - XL_THUNK_LO) / 16];
static int nthunks;
static XLMap thunk_by_name;   // hashed name -> index + 1
static os_unfair_lock thunk_lock = OS_UNFAIR_LOCK_INIT;

static uint64_t strhash(const char *s)
{
	uint64_t h = 1469598103934665603ULL;
	while (*s)
		h = (h ^ (uint8_t)*s++) * 1099511628211ULL;
	return h | 1;
}

uint32_t xl_thunk_for(const char *name)
{
	uint64_t k = strhash(name);
	os_unfair_lock_lock(&thunk_lock);
	for (int i = 0; i < nthunks; i++)
		if (!strcmp(thunk_imps[i].name, name)) {
			os_unfair_lock_unlock(&thunk_lock);
			return XL_THUNK_LO + 16 * i;
		}
	int i = nthunks++;
	thunk_imps[i].name = strdup(name);
	os_unfair_lock_unlock(&thunk_lock);
	(void)k;
	return XL_THUNK_LO + 16 * i;
}

static XLImport *thunk_import(uint32_t a)
{
	if (a < XL_THUNK_LO || a >= XL_THUNK_HI || (a & 15))
		return NULL;
	int i = (a - XL_THUNK_LO) / 16;
	return i < nthunks ? &thunk_imps[i] : NULL;
}

const char *xl_thunk_name(uint32_t a)
{
	XLImport *imp = thunk_import(a);
	return imp ? imp->name : NULL;
}

// ---- calls ----------------------------------------------------------------------------
void xl_call(XLCPU *c, uint32_t target)
{
	Target *t = (Target *)xl_map_get(&dispatch, target);
	if (t) {
		if (t->fn)
			t->fn(c);
		else
			xl_ccall(c, t->imp);
		return;
	}
	XLImport *imp = thunk_import(target);
	if (imp) {
		xl_ccall(c, imp);
		return;
	}
	xl_badjump(c, target);
}

void xl_jump(XLCPU *c, uint32_t target)
{
	xl_call(c, target);
}

void xl_backtrace(XLCPU *c)
{
	uint32_t ebp = c->r[EBP];
	xl_log("  at %s", xl_name_at(*(uint32_t *)GP(c->r[ESP])));
	for (int i = 0; i < 24 && ebp >= c->stack_lo && ebp < c->stack_hi; i++) {
		uint32_t ret = *(uint32_t *)GP(ebp + 4);
		xl_log("  from %08x %s", ret, xl_name_at(ret));
		uint32_t next = *(uint32_t *)GP(ebp);
		if (next <= ebp)
			break;
		ebp = next;
	}
}

void xl_trap(XLCPU *c, uint32_t addr)
{
	xl_die("trap at %08x (%s) esp=%08x", addr, xl_name_at(addr), c->r[ESP]);
}

void xl_badjump(XLCPU *c, uint32_t target)
{
	uint32_t ret = *(uint32_t *)GP(c->r[ESP]);
	xl_log("eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x", c->r[0], c->r[1], c->r[2],
		c->r[3], c->r[4], c->r[5], c->r[6], c->r[7]);
	xl_backtrace(c);
	xl_die("jump to untranslated address %08x (%s), return address %08x (%s)", target, xl_name_at(target), ret,
		xl_name_at(ret));
}

void xl_unsupported(XLCPU *c, uint32_t addr, const char *what)
{
	xl_log("unsupported instruction at %08x (%s): %s", addr, xl_name_at(addr), what);
}

double xl_fround(XLCPU *c, double v)
{
	switch ((c->fcw >> 10) & 3) {
	case 0: return nearbyint(v);
	case 1: return floor(v);
	case 2: return ceil(v);
	default: return trunc(v);
	}
}

double xl_ld80(uint32_t a)
{
	uint8_t *p = GP(a);
	uint64_t m;
	uint16_t se;
	memcpy(&m, p, 8);
	memcpy(&se, p + 8, 2);
	int e = se & 0x7fff;
	double s = (se & 0x8000) ? -1.0 : 1.0;
	if (!e && !m)
		return s * 0.0;
	if (e == 0x7fff)
		return (m << 1) ? NAN : s * INFINITY;
	return s * ldexp((double)m, e - 16383 - 63);
}

void xl_st80(uint32_t a, double v)
{
	uint8_t *p = GP(a);
	uint64_t m = 0;
	uint16_t se = signbit(v) ? 0x8000 : 0;
	if (isnan(v)) {
		se |= 0x7fff;
		m = 0xc000000000000000ULL;
	} else if (isinf(v)) {
		se |= 0x7fff;
		m = 0x8000000000000000ULL;
	} else if (v != 0) {
		int e;
		double f = frexp(fabs(v), &e);     // f in [0.5, 1)
		m = (uint64_t)ldexp(f, 64);
		se |= (uint16_t)(e - 1 + 16383);
	}
	memcpy(p, &m, 8);
	memcpy(p + 8, &se, 2);
}

// ---- per-thread CPU -------------------------------------------------------------------
static pthread_key_t cpu_key;
static uint32_t stack_used;     // bitmap of stack slots
static os_unfair_lock stack_lock = OS_UNFAIR_LOCK_INIT;

static void cpu_free(void *p)
{
	XLCPU *c = p;
	int slot = (int)((c->stack_lo - XL_STACK_LO) / XL_STACK_SIZE);
	os_unfair_lock_lock(&stack_lock);
	stack_used &= ~(1u << slot);
	os_unfair_lock_unlock(&stack_lock);
	free(c);
}

XLCPU *xl_cpu(void)
{
	XLCPU *c = pthread_getspecific(cpu_key);
	if (c)
		return c;
	c = calloc(1, sizeof *c);
	os_unfair_lock_lock(&stack_lock);
	int slot = 0;
	while (slot < 32 && (stack_used & (1u << slot)))
		slot++;
	if (slot == 32)
		xl_die("too many guest threads");
	stack_used |= 1u << slot;
	os_unfair_lock_unlock(&stack_lock);
	c->stack_lo = XL_STACK_LO + slot * XL_STACK_SIZE;
	c->stack_hi = c->stack_lo + XL_STACK_SIZE;
	c->r[ESP] = c->stack_hi - 64;
	c->fcw = 0x37f;
	c->top = 0;
	pthread_setspecific(cpu_key, c);
	return c;
}

static void cpu_key_init(void)
{
	pthread_key_create(&cpu_key, cpu_free);
}

// call a guest function with host-built arguments: the caller fills the
// argument block returned by xl_guest_frame, then xl_guest_run calls.
uint32_t xl_guest_frame(XLCPU *c, uint32_t nbytes)
{
	uint32_t sp = c->r[ESP] - 64;
	return (sp - nbytes) & ~15u;
}

void xl_guest_run(XLCPU *c, uint32_t fn, uint32_t sp, XLResult *res)
{
	uint32_t save[8];
	memcpy(save, c->r, sizeof save);
	int top = c->top;
	struct XLTry *tries = c->tries;
	sp -= 4;
	*(uint32_t *)GP(sp) = 0;
	c->r[ESP] = sp;
	@try {
		xl_call(c, fn);
	} @catch (id e) {
		// a host exception unwinding through: the guest frames are gone
		memcpy(c->r, save, sizeof save);
		c->top = top;
		c->tries = tries;
		@throw;
	}
	if (res) {
		res->eax = c->r[EAX];
		res->edx = c->r[EDX];
		res->st0 = c->top != top ? c->st[c->top & 7] : 0;
	}
	memcpy(c->r, save, sizeof save);
	c->top = top;
}

static void guest_invoke(uint32_t fn, int n, const uint32_t *args, XLResult *res)
{
	XLCPU *c = xl_cpu();
	uint32_t sp = xl_guest_frame(c, 4 * n);
	for (int i = 0; i < n; i++)
		*(uint32_t *)GP(sp + 4 * i) = args[i];
	xl_guest_run(c, fn, sp, res);
}

uint32_t xl_guest_call(uint32_t fn, int n, const uint32_t *args)
{
	XLResult r;
	guest_invoke(fn, n, args, &r);
	return r.eax;
}

uint64_t xl_guest_call64(uint32_t fn, int n, const uint32_t *args)
{
	XLResult r;
	guest_invoke(fn, n, args, &r);
	return r.eax | (uint64_t)r.edx << 32;
}

double xl_guest_callf(uint32_t fn, int n, const uint32_t *args)
{
	XLResult r;
	guest_invoke(fn, n, args, &r);
	return r.st0;
}

// ---- setjmp / longjmp -------------------------------------------------------------------
static XLMap jmps;   // guest jmp_buf -> XLJmp *

XLJmp *xl_setjmp(XLCPU *c, int sig)
{
	uint32_t buf = xl_arg(c, 0);
	XLJmp *j = (XLJmp *)xl_map_get(&jmps, buf);
	if (!j) {
		j = calloc(1, sizeof *j);
		j->guest_buf = buf;
		xl_map_put(&jmps, buf, (uint64_t)j);
	}
	memcpy(j->regs, c->r, sizeof j->regs);
	j->val = 0;
	c->r[EAX] = 0;
	// keep a marker in the guest buffer so guest code copying jmp_bufs still finds us
	*(uint32_t *)GP(buf) = 0x584c4a4d;
	(void)sig;
	return j;
}

void xl_longjmp_landed(XLCPU *c, XLJmp *j)
{
	memcpy(c->r, j->regs, sizeof j->regs);
	c->r[EAX] = j->val ? (uint32_t)j->val : 1;
}

void xl_longjmp(XLCPU *c, uint32_t buf, int val)
{
	XLJmp *j = (XLJmp *)xl_map_get(&jmps, buf);
	if (!j)
		xl_die("longjmp to unknown buffer %08x", buf);
	j->val = val;
	siglongjmp(j->host, 1);
}

// ---- loading ------------------------------------------------------------------------------
uint32_t xl_data_symbol(const char *name);   // data.m
int xl_is_function(const char *name);       // bridge.m

static int depends_on(XLImage *a, XLImage *b)
{
	for (const char **d = a->dylibs; *d; d++)
		if (b->install[0] && !strcmp(*d, b->install))
			return 1;
	return 0;
}

static void apply_binds(XLImage *im)
{
	uint32_t s = *im->slide;
	for (size_t i = 0; i < im->nbinds; i++) {
		const XLBind *b = &im->binds[i];
		uint32_t v = 0;
		if (!strncmp(b->sym, ".objc_class_name_", 17))
			continue;
		v = xl_lookup_export(b->sym);
		if (!v)
			v = xl_is_function(b->sym) ? xl_thunk_for(b->sym) : xl_data_symbol(b->sym);
		*(uint32_t *)GP(b->addr + s) = v + (uint32_t)b->addend;
	}
}

void xl_load_images(void)
{
	cpu_key_init();
	xl_window_init();
	// order: dependencies first (frameworks before the executable)
	XLImage *list[64];
	int n = 0;
	for (XLImage *im = pending; im; im = im->next)
		list[n++] = im;
	XLImage *ordered[64];
	int no = 0, done[64] = {0};
	while (no < n) {
		int progress = 0;
		for (int i = 0; i < n; i++) {
			if (done[i])
				continue;
			int ready = 1;
			for (int j = 0; j < n; j++)
				if (!done[j] && j != i && depends_on(list[i], list[j]))
					ready = 0;
			if (ready) {
				ordered[no++] = list[i];
				done[i] = 1;
				progress = 1;
			}
		}
		if (!progress)
			for (int i = 0; i < n; i++)
				if (!done[i]) {
					ordered[no++] = list[i];
					done[i] = 1;
					break;
				}
	}
	uint32_t next_base = XL_REBASE_LO;
	xl_images = NULL;
	XLImage **tail = &xl_images;
	for (int i = 0; i < no; i++) {
		XLImage *im = ordered[i];
		im->next = NULL;
		*tail = im;
		tail = &im->next;
		if (im->lo == 0) {
			im->base = next_base;
			next_base = (next_base + im->size + 0xffff) & ~0xffffu;
		} else {
			im->base = im->lo;
		}
		*im->slide = im->base - im->lo;
		memcpy(GP(im->base), im->blob, im->size);
		uint32_t s = *im->slide;
		for (size_t k = 0; k < im->nrebases; k++)
			*(uint32_t *)GP(im->rebases[k] + s) += s;
		for (size_t k = 0; k < im->nfuncs; k++) {
			Target *t = calloc(1, sizeof *t);
			t->fn = im->funcs[k].fn;
			t->f = &im->funcs[k];
			im->funcs[k].img = im;
			xl_map_put(&dispatch, im->funcs[k].addr + s, (uint64_t)t);
		}
		if (xl_verbose > 0)
			xl_log("image %s at %08x (%u functions)", im->name, im->base, (unsigned)im->nfuncs);
	}
	// binds and stubs need every image placed
	for (XLImage *im = xl_images; im; im = im->next) {
		apply_binds(im);
		uint32_t s = *im->slide;
		for (size_t k = 0; k < im->nstubs; k++) {
			const XLBind *b = &im->stubs[k];
			uint32_t a = b->addr + s;
			if (xl_map_get(&dispatch, a))
				continue;
			Target *t = calloc(1, sizeof *t);
			uint32_t g = xl_lookup_export(b->sym);
			if (g && xl_fn_at(g)) {
				t->fn = xl_fn_at(g);
			} else {
				t->imp = calloc(1, sizeof(XLImport));
				t->imp->name = b->sym;
			}
			xl_map_put(&dispatch, a, (uint64_t)t);
		}
		im->loaded = 1;
	}
}

static void run_section_ptrs(XLImage *im, int type)
{
	uint32_t s = *im->slide;
	for (const XLSection *sec = im->sections; sec->seg; sec++) {
		if ((sec->flags & 0xff) != (uint32_t)type)
			continue;
		for (uint32_t k = 0; k < sec->size / 4; k++) {
			uint32_t fn = *(uint32_t *)GP(sec->addr + s + 4 * k);
			if (xl_verbose > 1)
				xl_log("initializer %08x %s", fn, xl_name_at(fn));
			uint32_t args[4] = {0, 0, 0, 0};
			xl_guest_call(fn, 4, args);
		}
	}
}

void xl_run_initializers(void)
{
	for (XLImage *im = xl_images; im; im = im->next) {
		if (im->init) {
			uint32_t args[4] = {0, 0, 0, 0};
			xl_guest_call(im->init + *im->slide, 4, args);
		}
		run_section_ptrs(im, 9);   // S_MOD_INIT_FUNC_POINTERS
	}
}
