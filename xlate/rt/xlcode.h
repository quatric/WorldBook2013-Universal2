// Included by generated code: registers, guest memory, flags, x87.
#ifndef XLCODE_H
#define XLCODE_H
#include "xl.h"
#include <string.h>
#include <math.h>

typedef uint64_t u64u __attribute__((aligned(1), may_alias));
typedef uint32_t u32u __attribute__((aligned(1), may_alias));
typedef uint16_t u16u __attribute__((aligned(1), may_alias));
typedef uint8_t u8u __attribute__((may_alias));

#define G(a) GP(a)
#define LD64(a) (*(const u64u *)G(a))
#define LD32(a) (*(const u32u *)G(a))
#define LD16(a) ((uint32_t)*(const u16u *)G(a))
#define LD8(a) ((uint32_t)*(const u8u *)G(a))
#define ST64(a, v) (*(u64u *)G(a) = (uint64_t)(v))
#define ST32(a, v) (*(u32u *)G(a) = (uint32_t)(v))
#define ST16(a, v) (*(u16u *)G(a) = (uint16_t)(v))
#define ST8(a, v) (*(u8u *)G(a) = (uint8_t)(v))
static inline XMM LDX(uint32_t a) { XMM x; memcpy(&x, G(a), 16); return x; }
#define STX(a, v) do { XMM _v = (v); memcpy(G(a), &_v, 16); } while (0)
static inline double BITS2D(uint64_t v) { double d; memcpy(&d, &v, 8); return d; }
static inline float BITS2F(uint64_t v) { uint32_t w = (uint32_t)v; float f; memcpy(&f, &w, 4); return f; }

#define A(x) ((uint32_t)((x) + S))

#define REGS \
	uint32_t r0 = c->r[0], r1 = c->r[1], r2 = c->r[2], r3 = c->r[3], r4 = c->r[4], r5 = c->r[5], r6 = c->r[6], r7 = c->r[7]; \
	uint64_t fa = 0, fb = 0, fr = 0, fcf = 0; int fop = 0; \
	(void)fa; (void)fb; (void)fr; (void)fcf; (void)fop
#define SO do { c->r[0] = r0; c->r[1] = r1; c->r[2] = r2; c->r[3] = r3; c->r[4] = r4; c->r[5] = r5; c->r[6] = r6; c->r[7] = r7; } while (0)
#define SI do { r0 = c->r[0]; r1 = c->r[1]; r2 = c->r[2]; r3 = c->r[3]; r4 = c->r[4]; r5 = c->r[5]; r6 = c->r[6]; r7 = c->r[7]; } while (0)

// ---- x87 ------------------------------------------------------------------
#define FST(i) (c->st[(c->top + (i)) & 7])
#define FPUSH(v) do { double _v = (v); c->top = (c->top - 1) & 7; c->st[c->top] = _v; } while (0)
#define FPOP do { c->top = (c->top + 1) & 7; } while (0)
static inline uint16_t xl_fcom(double a, double b)
{
	if (a != a || b != b)
		return 0x4500;
	if (a < b)
		return 0x0100;
	if (a == b)
		return 0x4000;
	return 0;
}
static inline uint32_t xl_fsw(XLCPU *c) { return (uint32_t)c->fcc | ((uint32_t)(c->top & 7) << 11); }

// ---- lazy condition flags ------------------------------------------------
// fop = kind << 8 | operand bits; FOP_DIRECT keeps the flag bits in fr
// (CF 0x1, PF 0x4, ZF 0x40, SF 0x80, OF 0x800).
enum { K_DIRECT, K_ADD, K_SUB, K_LOGIC, K_INC, K_DEC, K_SHL, K_SHR, K_SAR, K_ROL, K_ROR };
#define FOPS(K) FOP_##K##8 = (K_##K << 8) | 8, FOP_##K##16 = (K_##K << 8) | 16, FOP_##K##32 = (K_##K << 8) | 32
enum { FOP_DIRECT = 0, FOPS(ADD), FOPS(SUB), FOPS(LOGIC), FOPS(INC), FOPS(DEC), FOPS(SHL), FOPS(SHR), FOPS(SAR), FOPS(ROL), FOPS(ROR) };

static inline uint64_t xl_mask(int sz) { return sz == 64 ? ~0ULL : ((1ULL << sz) - 1); }
static inline int xl_msb(int sz, uint64_t v) { return (int)((v >> (sz - 1)) & 1); }

static inline int xl_cf(int op, uint64_t a, uint64_t b, uint64_t r, uint64_t cf)
{
	int sz = op & 0xff;
	switch (op >> 8) {
	case K_DIRECT: return (int)(r & 1);
	case K_ADD: return r < (a & xl_mask(sz));
	case K_SUB: return (a & xl_mask(sz)) < (b & xl_mask(sz));
	case K_LOGIC: return 0;
	case K_INC: case K_DEC: return (int)cf;
	case K_SHL: return (int)((a >> (sz - b)) & 1);
	case K_SHR: return (int)((a >> (b - 1)) & 1);
	case K_SAR: return (int)(((int64_t)(a << (64 - sz)) >> (64 - sz + b - 1)) & 1);
	case K_ROL: return (int)(r & 1);
	case K_ROR: return xl_msb(sz, r);
	}
	return 0;
}

static inline int xl_zf(int op, uint64_t r) { return (op >> 8) == K_DIRECT ? (int)((r >> 6) & 1) : r == 0; }
static inline int xl_sf(int op, uint64_t r) { return (op >> 8) == K_DIRECT ? (int)((r >> 7) & 1) : xl_msb(op & 0xff, r); }
static inline int xl_pf(int op, uint64_t r) { return (op >> 8) == K_DIRECT ? (int)((r >> 2) & 1) : !__builtin_parity((unsigned)(r & 0xff)); }

static inline int xl_of(int op, uint64_t a, uint64_t b, uint64_t r, uint64_t cf)
{
	int sz = op & 0xff;
	switch (op >> 8) {
	case K_DIRECT: return (int)((r >> 11) & 1);
	case K_ADD: return xl_msb(sz, (a ^ r) & (b ^ r));
	case K_SUB: return xl_msb(sz, (a ^ b) & (a ^ r));
	case K_LOGIC: return 0;
	case K_INC: return r == (1ULL << (sz - 1));
	case K_DEC: return r == (1ULL << (sz - 1)) - 1;
	case K_SHL: return xl_msb(sz, r) ^ xl_cf(op, a, b, r, cf);
	case K_SHR: return b == 1 ? xl_msb(sz, a) : 0;
	case K_SAR: return 0;
	case K_ROL: return xl_msb(sz, r) ^ (int)(r & 1);
	case K_ROR: return xl_msb(sz, r) ^ (int)((r >> (sz - 2)) & 1);
	}
	return 0;
}

static inline uint64_t xl_flags_all(int op, uint64_t a, uint64_t b, uint64_t r, uint64_t cf)
{
	if ((op >> 8) == K_DIRECT)
		return r;
	return (uint64_t)xl_cf(op, a, b, r, cf) | ((uint64_t)xl_pf(op, r) << 2) | ((uint64_t)xl_zf(op, r) << 6) |
		((uint64_t)xl_sf(op, r) << 7) | ((uint64_t)xl_of(op, a, b, r, cf) << 11);
}

static inline uint64_t xl_flags_bits(int sz, uint64_t r, int cf, int of)
{
	return (uint64_t)cf | ((uint64_t)!__builtin_parity((unsigned)(r & 0xff)) << 2) | ((uint64_t)(r == 0) << 6) |
		((uint64_t)xl_msb(sz, r) << 7) | ((uint64_t)of << 11);
}

static inline uint64_t xl_flags_adc(int sz, uint64_t a, uint64_t b, uint64_t cf, uint64_t r)
{
	uint64_t m = xl_mask(sz);
	a &= m; b &= m;
	int c = r < a || (cf && r == a);
	return xl_flags_bits(sz, r, c, xl_msb(sz, ~(a ^ b) & (a ^ r)));
}

static inline uint64_t xl_flags_sbb(int sz, uint64_t a, uint64_t b, uint64_t cf, uint64_t r)
{
	uint64_t m = xl_mask(sz);
	a &= m; b &= m;
	int c = a < b || (cf && a == b);
	return xl_flags_bits(sz, r, c, xl_msb(sz, (a ^ b) & (a ^ r)));
}

static inline uint64_t xl_ucom(double a, double b)
{
	if (a != a || b != b)
		return 0x45;
	if (a < b)
		return 0x1;
	if (a == b)
		return 0x40;
	return 0;
}

#define COND_B xl_cf(fop, fa, fb, fr, fcf)
#define COND_E xl_zf(fop, fr)
#define COND_S xl_sf(fop, fr)
#define COND_P xl_pf(fop, fr)
#define COND_O xl_of(fop, fa, fb, fr, fcf)
#define COND_BE (COND_B || COND_E)
#define COND_L (COND_S != COND_O)
#define COND_LE (COND_E || COND_L)

static inline uint32_t xl_cvtt32(double v)
{
	if (v != v || v >= 2147483648.0 || v <= -2147483649.0)
		return 0x80000000u;
	return (uint32_t)(int32_t)v;
}

#endif
