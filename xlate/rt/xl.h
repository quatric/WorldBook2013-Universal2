// Runtime for translated i386 images running in a 32-bit guest window
// (see docs/design.md and xlate/lift32.py).
#ifndef XL_H
#define XL_H
#include <stdint.h>
#include <stddef.h>
#include <setjmp.h>

typedef union {
	uint64_t q[2];
	uint32_t d[4];
	uint16_t w[8];
	uint8_t b[16];
	double f64[2];
	float f32[4];
} XMM;

enum { EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI };

typedef struct XLCPU {
	uint32_t r[8];
	XMM x[8];
	double st[8];        // x87 registers, st(i) = st[(top + i) & 7]
	int top;
	uint16_t fcw;        // x87 control word (rounding mode)
	uint16_t fcc;        // x87 condition bits from fcom (C0 C2 C3 in 0x100 0x400 0x4000)
	uint32_t stack_lo, stack_hi;   // guest stack of this thread
	void *exc;
	struct XLTry *tries;           // Objective-C 1 try blocks (innermost first)
} XLCPU;

extern uint8_t *XG;              // base of the guest window
#define GP(a) ((void *)(XG + (uint32_t)(a)))
static inline uint32_t GA(const void *p) { return (uint32_t)((const uint8_t *)p - XG); }

typedef void (*XLFn)(XLCPU *);

struct XLImage;
typedef struct XLFunc {
	XLFn fn;
	uint32_t addr;       // original address
	const char *name;
	void *closure;       // native entry, made on demand
	struct XLImage *img;
} XLFunc;

typedef struct XLImport {
	const char *name;
	void *impl;          // resolved bridge (XLBridge *)
} XLImport;

typedef struct XLBind { uint32_t addr; const char *sym; int32_t addend; } XLBind;
typedef struct XLExport { const char *name; uint32_t addr; } XLExport;
typedef struct XLSection { const char *seg, *name; uint32_t addr, size, flags; } XLSection;

typedef struct XLImage {
	const char *name, *install;
	uint32_t lo, size;
	const unsigned char *blob;
	const uint32_t *rebases; size_t nrebases;
	const XLBind *binds; size_t nbinds;
	const XLBind *stubs; size_t nstubs;
	const XLExport *exports; size_t nexports;
	XLFunc *funcs; size_t nfuncs;
	XLImport *imports; size_t nimports;
	const XLSection *sections;
	const char **dylibs;
	uint32_t *slide;
	uint32_t entry, init;
	// filled in at load
	uint32_t base;       // guest address the image is loaded at
	int loaded;
	struct XLImage *next;
} XLImage;

typedef struct XLJmp {
	uint32_t guest_buf;
	uint32_t regs[8];    // guest registers at the setjmp call (esp with the return address)
	int val;
	sigjmp_buf host;
} XLJmp;

enum { XL_MSG_NORMAL, XL_MSG_STRET, XL_MSG_FPRET, XL_MSG_SUPER, XL_MSG_SUPER_STRET };

void xl_register_image(XLImage *im);
XLCPU *xl_cpu(void);
void xl_call(XLCPU *c, uint32_t target);
void xl_jump(XLCPU *c, uint32_t target);
void xl_ccall(XLCPU *c, XLImport *imp);
void xl_msgsend(XLCPU *c, int kind);
uint32_t xl_export_addr(const char *name);
XLJmp *xl_setjmp(XLCPU *c, int sig);
void xl_longjmp_landed(XLCPU *c, XLJmp *j);
void xl_trap(XLCPU *c, uint32_t addr) __attribute__((noreturn));
void xl_badjump(XLCPU *c, uint32_t target) __attribute__((noreturn));
void xl_unsupported(XLCPU *c, uint32_t addr, const char *what);
double xl_fround(XLCPU *c, double v);
double xl_ld80(uint32_t a);
void xl_st80(uint32_t a, double v);

// function-entry trace (XL_TRACE=1 in the environment)
extern int xl_trace_on;
void xl_trace_fn(XLCPU *c, uint32_t addr);
#define XL_TRACE(a) do { if (__builtin_expect(xl_trace_on, 0)) xl_trace_fn(c, a); } while (0)

// C++ exceptions: calls inside a protected range of the original go through
// xl_try_*, which return 1 when the call threw and this site handles it
// (eax = exception, edx = selector, registers as at the call)
typedef struct { int32_t filter; uint32_t addr; int kind; } XLEHClause;   // kind 0: typeinfo, 1: slot, 2: spec
typedef struct XLEH { int n, cleanup; const XLEHClause *cl; } XLEH;
int xl_try_fn(XLCPU *c, XLFn fn, const XLEH *eh, uint32_t slide);
int xl_try_call(XLCPU *c, uint32_t target, const XLEH *eh, uint32_t slide);
int xl_try_ccall(XLCPU *c, XLImport *imp, const XLEH *eh, uint32_t slide);
int xl_try_msgsend(XLCPU *c, int kind, const XLEH *eh, uint32_t slide);

#endif
