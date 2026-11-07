// Guest C++ exceptions.
//
// An exception object lives in the guest heap behind a header (below). A
// throw becomes a host Objective-C exception (XLCxxThrow) that unwinds the
// host frames of the translated code; xl_try_* at protected call sites
// catch it, choose the clause the original personality routine would, and
// resume the translated function at its landing pad.
#import <Foundation/Foundation.h>
#include "rt.h"

#define HDR 32
#define MAGIC 0x58434c58u   // "XLCX"
typedef struct {
	uint32_t ti, dtor;
	int32_t handlers;
	uint32_t adjusted, next, rethrown, magic, pad;
} GExc;
#define EXC(h) ((GExc *)GP(h))
#define U32(a) (*(uint32_t *)GP(a))

static __thread uint32_t caught;   // innermost caught exception (header)

@interface XLCxxThrow : NSObject {
@public
	uint32_t ue;
}
@end

static const char *ti_name(uint32_t ti)
{
	if (!ti || !U32(ti + 4))
		return "?";
	const char *n = (const char *)GP(U32(ti + 4));
	return *n == '*' ? n + 1 : n;
}

@implementation XLCxxThrow
- (NSString *)description
{
	return [NSString stringWithFormat:@"guest C++ exception %s", ti_name(EXC(ue)->ti)];
}
@end

static void throw_host(uint32_t ue) __attribute__((noreturn));
static void throw_host(uint32_t ue)
{
	XLCxxThrow *t = [[XLCxxThrow alloc] init];
	t->ue = ue;
	@throw [t autorelease];
}

// ---- typeinfo matching ---------------------------------------------------------
static uint32_t vt_si, vt_vmi;

static void init_vtables(void)
{
	if (vt_si)
		return;
	vt_si = xl_data_symbol("__ZTVN10__cxxabiv120__si_class_type_infoE") + 8;
	vt_vmi = xl_data_symbol("__ZTVN10__cxxabiv121__vmi_class_type_infoE") + 8;
}

static int same_type(uint32_t a, uint32_t b)
{
	return a == b || !strcmp(ti_name(a), ti_name(b));
}

// is `want` the thrown type `have` or a public base of it; *obj is adjusted to that base
static int can_catch(uint32_t have, uint32_t want, uint32_t *obj, int depth)
{
	if (!have || depth > 32)
		return 0;
	if (same_type(have, want))
		return 1;
	uint32_t vt = U32(have);
	if (vt == vt_si)
		return can_catch(U32(have + 8), want, obj, depth + 1);
	if (vt == vt_vmi) {
		uint32_t n = U32(have + 12);
		for (uint32_t i = 0; i < n && i < 64; i++) {
			uint32_t base = U32(have + 16 + 8 * i);
			int32_t of = (int32_t)U32(have + 20 + 8 * i);
			if (!(of & 2))
				continue;          // not public
			uint32_t o = *obj;
			if (of & 1) {
				// virtual base: the offset to it is stored in the vtable
				uint32_t vtab = U32(o);
				o += (int32_t)U32(vtab + (of >> 8));
			} else
				o += of >> 8;
			if (can_catch(base, want, &o, depth + 1)) {
				*obj = o;
				return 1;
			}
		}
	}
	return 0;
}

// the clause this site takes for exception ue, or -1 to keep unwinding
static int select_clause(uint32_t ue, const XLEH *eh, uint32_t slide, int32_t *sel)
{
	GExc *h = EXC(ue);
	init_vtables();
	for (int i = 0; i < eh->n; i++) {
		const XLEHClause *cl = &eh->cl[i];
		if (cl->kind == 2)
			continue;   // exception specification
		uint32_t obj = ue + HDR;
		if (cl->kind == 1 && !cl->addr) {
			h->adjusted = obj;   // catch (...)
			*sel = cl->filter;
			return 1;
		}
		uint32_t want = cl->kind == 1 ? U32(cl->addr + slide) : cl->addr + slide;
		if (!want || can_catch(h->ti, want, &obj, 0)) {
			h->adjusted = obj;
			*sel = cl->filter;
			return 1;
		}
	}
	if (eh->cleanup) {
		*sel = 0;
		return 1;
	}
	return 0;
}

#define XL_TRY(call) \
	uint32_t sp = c->r[ESP], ebx = c->r[EBX], ebp = c->r[EBP], esi = c->r[ESI], edi = c->r[EDI]; \
	int top = c->top; \
	struct XLTry *tries = c->tries; \
	@try { \
		call; \
	} @catch (XLCxxThrow *t) { \
		int32_t sel; \
		if (!select_clause(t->ue, eh, slide, &sel)) \
			@throw; \
		if (xl_verbose > 0) \
			xl_log("C++ exception %s lands (selector %d)", ti_name(EXC(t->ue)->ti), sel); \
		c->r[EAX] = t->ue; \
		c->r[EDX] = (uint32_t)sel; \
		c->r[ESP] = sp + 4; \
		c->r[EBX] = ebx; c->r[EBP] = ebp; c->r[ESI] = esi; c->r[EDI] = edi; \
		c->top = top; \
		c->tries = tries; \
		return 1; \
	} \
	return 0;

int xl_try_fn(XLCPU *c, XLFn fn, const XLEH *eh, uint32_t slide) { XL_TRY(fn(c)) }
int xl_try_call(XLCPU *c, uint32_t target, const XLEH *eh, uint32_t slide) { XL_TRY(xl_call(c, target)) }
int xl_try_ccall(XLCPU *c, XLImport *imp, const XLEH *eh, uint32_t slide) { XL_TRY(xl_ccall(c, imp)) }
int xl_try_msgsend(XLCPU *c, int kind, const XLEH *eh, uint32_t slide) { XL_TRY(xl_msgsend(c, kind)) }

// ---- the C++ ABI ------------------------------------------------------------------
#define A(i) xl_arg(c, i)

void xl_sh_cxa_allocate_exception(XLCPU *c)
{
	uint32_t h = xl_calloc(A(0) + HDR);
	EXC(h)->magic = MAGIC;
	xl_ret(c, h + HDR);
}

void xl_sh_cxa_free_exception(XLCPU *c)
{
	xl_free(A(0) - HDR);
	xl_ret(c, 0);
}

void xl_sh_cxa_throw(XLCPU *c)
{
	uint32_t ue = A(0) - HDR;
	GExc *h = EXC(ue);
	h->ti = A(1);
	h->dtor = A(2);
	h->adjusted = A(0);
	h->handlers = 0;
	h->rethrown = 0;
	if (xl_verbose > 0)
		xl_log("guest throws C++ %s from %s", ti_name(h->ti), xl_name_at(U32(c->r[ESP])));
	throw_host(ue);
}

void xl_sh_cxa_begin_catch(XLCPU *c)
{
	uint32_t ue = A(0);
	if (!ue || EXC(ue)->magic != MAGIC) {
		xl_ret(c, ue);
		return;
	}
	GExc *h = EXC(ue);
	h->handlers++;
	h->rethrown = 0;
	if (caught != ue) {
		h->next = caught;
		caught = ue;
	}
	xl_ret(c, h->adjusted);
}

void xl_sh_cxa_get_exception_ptr(XLCPU *c)
{
	uint32_t ue = A(0);
	xl_ret(c, ue && EXC(ue)->magic == MAGIC ? EXC(ue)->adjusted : ue);
}

void xl_sh_cxa_end_catch(XLCPU *c)
{
	c->r[ESP] += 4;   // pop the return address first: the destructor runs on the guest stack
	uint32_t ue = caught;
	if (!ue)
		return;
	GExc *h = EXC(ue);
	if (--h->handlers > 0)
		return;
	caught = h->next;
	if (h->rethrown)
		return;
	if (h->dtor) {
		uint32_t obj = ue + HDR;
		xl_guest_call(h->dtor, 1, &obj);
	}
	h->magic = 0;
	xl_free(ue);
}

void xl_sh_cxa_rethrow(XLCPU *c)
{
	uint32_t ue = caught;
	if (!ue)
		xl_die("rethrow with no exception being handled (from %s)", xl_name_at(U32(c->r[ESP])));
	EXC(ue)->rethrown = 1;
	if (xl_verbose > 0)
		xl_log("guest rethrows C++ %s", ti_name(EXC(ue)->ti));
	throw_host(ue);
}

void xl_sh_unwind_resume(XLCPU *c)
{
	uint32_t ue = A(0);
	if (!ue || EXC(ue)->magic != MAGIC)
		xl_die("_Unwind_Resume with a foreign exception %x (from %s)", ue, xl_name_at(U32(c->r[ESP])));
	throw_host(ue);
}

void xl_sh_cxa_current_exception_type(XLCPU *c)
{
	xl_ret(c, caught ? EXC(caught)->ti : 0);
}

void xl_sh_uncaught_exception(XLCPU *c) { xl_ret(c, 0); }

void xl_sh_cxa_call_unexpected(XLCPU *c)
{
	uint32_t ue = A(0);
	xl_die("exception %s violates an exception specification (from %s)",
		ue && EXC(ue)->magic == MAGIC ? ti_name(EXC(ue)->ti) : "?", xl_name_at(U32(c->r[ESP])));
}
