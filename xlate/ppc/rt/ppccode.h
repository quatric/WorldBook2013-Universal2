// Included by generated code (xlate/ppc/liftppc.py).
#ifndef PPCCODE_H
#define PPCCODE_H
#include "ppc.h"
#include <math.h>

#define R(n) c->r[n]
#define FD(n) c->f[n].d
#define FU(n) c->f[n].u
#define PTRACE(a) do { if (__builtin_expect(ppc_trace_on, 0)) ppc_trace_fn(c, a); } while (0)

static inline uint32_t ROTL(uint32_t v, uint32_t n) { n &= 31; return n ? (v << n) | (v >> (32 - n)) : v; }

// condition register: bit 0 is the most significant
#define CRB(i) ((c->cr >> (31 - (i))) & 1)
#define SETCRB(i, v) do { uint32_t _m = 0x80000000u >> (i); c->cr = (v) ? (c->cr | _m) : (c->cr & ~_m); } while (0)
#define CRF(f) ((c->cr >> (28 - 4 * (f))) & 15)
#define SETCRF(f, v) do { int _s = 28 - 4 * (f); c->cr = (c->cr & ~(15u << _s)) | ((uint32_t)(v) << _s); } while (0)
#define CMPS(f, a, b) do { int32_t _a = (int32_t)(a), _b = (int32_t)(b); \
	SETCRF(f, (_a < _b ? 8 : _a > _b ? 4 : 2) | c->so); } while (0)
#define CMPU(f, a, b) do { uint32_t _a = (a), _b = (b); \
	SETCRF(f, (_a < _b ? 8 : _a > _b ? 4 : 2) | c->so); } while (0)
#define CR0(v) CMPS(0, v, 0)

static inline uint32_t XER_GET(PPC *c) { return (c->so << 31) | (c->ov << 30) | (c->ca << 29) | (c->xer_bc & 0x7f); }
static inline void XER_SET(PPC *c, uint32_t v) { c->so = v >> 31; c->ov = (v >> 30) & 1; c->ca = (v >> 29) & 1; c->xer_bc = v & 0x7f; }

static inline uint32_t DIVW(uint32_t a, uint32_t b)
{
	if (!b || (a == 0x80000000u && b == 0xffffffffu))
		return 0;
	return (uint32_t)((int32_t)a / (int32_t)b);
}

static inline uint32_t SRAW(PPC *c, uint32_t v, uint32_t n)
{
	int32_t s = (int32_t)v;
	if (n > 31) {
		c->ca = s < 0;
		return s < 0 ? 0xffffffffu : 0;
	}
	if (!n) {
		c->ca = 0;
		return v;
	}
	c->ca = s < 0 && (v & ((1u << n) - 1));
	return (uint32_t)(s >> n);
}

static inline int TW(int to, uint32_t a, uint32_t b)
{
	int32_t sa = (int32_t)a, sb = (int32_t)b;
	return ((to & 16) && sa < sb) || ((to & 8) && sa > sb) || ((to & 4) && a == b) ||
		((to & 2) && a < b) || ((to & 1) && a > b);
}

static inline uint32_t FCMP(double a, double b)
{
	if (a != a || b != b)
		return 1;
	return a < b ? 8 : a > b ? 4 : 2;
}

static inline int32_t FCTIW(PPC *c, double v, int mode)
{
	(void)c;
	if (v != v)
		return (int32_t)0x80000000;
	double r;
	switch (mode) {
	case 0: r = nearbyint(v); break;   // the host rounds to nearest even by default
	case 1: r = trunc(v); break;
	case 2: r = ceil(v); break;
	default: r = floor(v); break;
	}
	if (r >= 2147483647.0)
		return 0x7fffffff;
	if (r <= -2147483648.0)
		return (int32_t)0x80000000;
	return (int32_t)r;
}

#define FPSCR_CR1(c) (((c)->fpscr >> 28) & 15)

static inline void LSWI(PPC *c, uint32_t ea, int rd, int n)
{
	int r = rd - 1, i = 0;
	while (n > 0) {
		if (!i) {
			r = (r + 1) & 31;
			c->r[r] = 0;
		}
		c->r[r] |= LD8(ea) << (24 - 8 * i);
		ea++;
		n--;
		i = (i + 1) & 3;
	}
}

static inline void STSWI(PPC *c, uint32_t ea, int rs, int n)
{
	int r = rs - 1, i = 0;
	while (n > 0) {
		if (!i)
			r = (r + 1) & 31;
		ST8(ea, c->r[r] >> (24 - 8 * i));
		ea++;
		n--;
		i = (i + 1) & 3;
	}
}

#endif
