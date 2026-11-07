// Objective-C 1 exceptions (setjmp based) and host exceptions reaching guest code.
#import <Foundation/Foundation.h>
#include "rt.h"

struct XLTry {
	uint32_t data;       // guest localExceptionData: jmp_buf (72 bytes), then pointers[4]
	struct XLTry *next;
};

#define EXC_SLOT(d) ((d) + 72)

static void try_push(XLCPU *c, uint32_t d)
{
	struct XLTry *t = malloc(sizeof *t);
	t->data = d;
	t->next = c->tries;
	c->tries = t;
}

static uint32_t try_pop(XLCPU *c)
{
	struct XLTry *t = c->tries;
	if (!t)
		return 0;
	c->tries = t->next;
	uint32_t d = t->data;
	free(t);
	return d;
}

void xl_sh_objc_exception_try_enter(XLCPU *c)
{
	try_push(c, xl_arg(c, 0));
	xl_ret(c, 0);
}

void xl_sh_objc_exception_try_exit(XLCPU *c)
{
	uint32_t d = xl_arg(c, 0);
	while (c->tries) {
		uint32_t x = try_pop(c);
		if (x == d)
			break;
	}
	xl_ret(c, 0);
}

void xl_sh_objc_exception_extract(XLCPU *c)
{
	xl_ret(c, *(uint32_t *)GP(EXC_SLOT(xl_arg(c, 0))));
}

void xl_sh_objc_exception_match(XLCPU *c)
{
	Class cls = (Class)xl_p(xl_arg(c, 0));
	id e = (id)xl_p(xl_arg(c, 1));
	xl_ret(c, cls && e && [e isKindOfClass:cls]);
}

static void throw_guest(XLCPU *c, uint32_t h) __attribute__((noreturn));
static void throw_guest(XLCPU *c, uint32_t h)
{
	uint32_t d = try_pop(c);
	*(uint32_t *)GP(EXC_SLOT(d)) = h;
	xl_longjmp(c, d, 1);
	abort();
}

void xl_sh_objc_exception_throw(XLCPU *c)
{
	uint32_t h = xl_arg(c, 0);
	id e = (id)xl_p(h);
	if (xl_verbose > 0)
		xl_log("guest throws %s: %s", e ? class_getName(object_getClass(e)) : "nil",
			[e isKindOfClass:[NSException class]] ? [[(NSException *)e reason] UTF8String] : "");
	if (c->tries)
		throw_guest(c, h);
	c->r[ESP] += 4;
	@throw e;
}

void xl_exc_from_host(XLCPU *c, NSException *e)
{
	[e autorelease];
	if (xl_verbose >= 0)
		xl_log("host exception %s: %s%s", [[e name] UTF8String], [[e reason] UTF8String],
			c->tries ? " (to guest handler)" : "");
	if (c->tries)
		throw_guest(c, xl_hobj(e));
	@throw e;
}
