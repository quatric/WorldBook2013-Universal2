// Translated PowerPC (CFM) applications: CPU state and guest memory.
// Guest memory is a 4 GB window at XG and big-endian, as on the original.
#ifndef PPC_H
#define PPC_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef union { double d; uint64_t u; } FPR;

typedef struct PPC {
	uint32_t r[32];
	FPR f[32];
	uint32_t cr, lr, ctr, ca, so, ov, xer_bc, fpscr;
	uint32_t resume_pc;     // a catch block to enter (set by ppc_resume)
} PPC;

// C++ exceptions: functions with catch blocks keep a host frame a throw can
// longjmp back to. sp is the guest stack pointer on entry, which the catching
// frame's back chain holds.
#include <setjmp.h>
typedef struct PPCResume {
	struct PPCResume *prev;
	uint32_t func, sp;
	jmp_buf jb;
} PPCResume;
extern PPCResume *ppc_resume_top;
static inline void ppc_resume_push(PPCResume *r, uint32_t func, uint32_t sp)
{
	r->prev = ppc_resume_top;
	r->func = func;
	r->sp = sp;
	ppc_resume_top = r;
}
static inline void ppc_resume_pop(PPCResume *r) { ppc_resume_top = r->prev; }
void ppc_resume(PPC *c, uint32_t pc) __attribute__((noreturn));
void ppc_bad_resume(PPC *c, uint32_t pc) __attribute__((noreturn));

typedef void (*PPCFn)(PPC *);
typedef struct { uint32_t addr; PPCFn fn; const char *name; } PPCFunc;

extern uint8_t *XG;
#define G(a) ((void *)(XG + (uint32_t)(a)))
static inline uint32_t GA(const void *p) { return (uint32_t)((const uint8_t *)p - XG); }

typedef uint64_t u64u __attribute__((aligned(1), may_alias));
typedef uint32_t u32u __attribute__((aligned(1), may_alias));
typedef uint16_t u16u __attribute__((aligned(1), may_alias));
typedef uint8_t u8u __attribute__((may_alias));

static inline uint32_t LD32(uint32_t a) { return __builtin_bswap32(*(const u32u *)G(a)); }
static inline uint32_t LD16(uint32_t a) { return __builtin_bswap16(*(const u16u *)G(a)); }
static inline uint32_t LD8(uint32_t a) { return *(const u8u *)G(a); }
static inline uint64_t LD64(uint32_t a) { return __builtin_bswap64(*(const u64u *)G(a)); }
static inline void ST32(uint32_t a, uint32_t v) { *(u32u *)G(a) = __builtin_bswap32(v); }
static inline void ST16(uint32_t a, uint32_t v) { *(u16u *)G(a) = __builtin_bswap16((uint16_t)v); }
static inline void ST8(uint32_t a, uint32_t v) { *(u8u *)G(a) = (uint8_t)v; }
static inline void ST64(uint32_t a, uint64_t v) { *(u64u *)G(a) = __builtin_bswap64(v); }
static inline float LDF(uint32_t a) { uint32_t w = LD32(a); float f; memcpy(&f, &w, 4); return f; }
static inline void STF(uint32_t a, float f) { uint32_t w; memcpy(&w, &f, 4); ST32(a, w); }
static inline double LDD(uint32_t a) { uint64_t w = LD64(a); double d; memcpy(&d, &w, 8); return d; }
static inline void STD(uint32_t a, double d) { uint64_t w; memcpy(&w, &d, 8); ST64(a, w); }

void ppc_call(PPC *c, uint32_t code);
void ppc_trap(PPC *c, uint32_t addr) __attribute__((noreturn));
void ppc_unimpl(PPC *c, uint32_t addr, uint32_t w) __attribute__((noreturn));
uint32_t ppc_timebase(int spr);
extern int ppc_trace_on;
void ppc_trace_fn(PPC *c, uint32_t addr);

#endif
