// Internal interfaces of the translation runtime (not included by generated code).
#ifndef RT_H
#define RT_H
#include "xl.h"
#include "sdkdb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <os/lock.h>
#include <objc/runtime.h>

// ---- guest address map ----------------------------------------------------
#define XL_REBASE_LO  0x10000000u   // frameworks linked at 0
#define XL_STACK_LO   0x18000000u   // thread stacks
#define XL_STACK_HI   0x20000000u
#define XL_HEAP_LO    0x20000000u   // malloc, cells, shadows
#define XL_HEAP_HI    0x80000000u
#define XL_REMAP_LO   0x80000000u   // host buffers mapped into the window
#define XL_REMAP_HI   0xbf000000u
#define XL_THUNK_LO   0xbff00000u   // fake addresses standing for host functions
#define XL_THUNK_HI   0xc0000000u
#define XL_STACK_SIZE (2u << 20)

extern int xl_verbose;
void xl_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void xl_die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));

// ---- small hash map (u64 -> u64), thread safe --------------------------------
typedef struct XLMap {
	uint64_t *keys, *vals;
	size_t cap, n;
	os_unfair_lock lock;
} XLMap;
uint64_t xl_map_get(XLMap *m, uint64_t k);   // 0 if absent
void xl_map_put(XLMap *m, uint64_t k, uint64_t v);
void xl_map_del(XLMap *m, uint64_t k);

// ---- window and heap -------------------------------------------------------
void xl_window_init(void);
uint32_t xl_malloc(uint32_t n);
uint32_t xl_calloc(uint32_t n);
void xl_free(uint32_t p);
uint32_t xl_realloc(uint32_t p, uint32_t n);
uint32_t xl_msize(uint32_t p);
uint32_t xl_strdup(const char *s);            // copy a host string into the window
uint32_t xl_remap(const void *p, size_t n);   // share host pages with the guest
void xl_unmap(uint32_t g, size_t n);
static inline int xl_in_window(const void *p) { return (const uint8_t *)p >= XG && (const uint8_t *)p < XG + 0x100000000ull; }

// ---- handles -----------------------------------------------------------------
// A handle h stands for a host pointer; for handles in the heap the host
// pointer sits at h - 8 (cells and shadows), others are in a table.
uint32_t xl_h(const void *p);         // any host pointer (no class checks)
uint32_t xl_hobj(id o);               // object: translated instances get their shadow
void *xl_p(uint32_t h);               // handle to host pointer
void *xl_p_quiet(uint32_t h);
#define XL_ID(h) ((id)xl_p(h))
void xl_bind_handle(uint32_t h, const void *p);   // static handle (class struct, cfstring, ...)
uint32_t xl_cell(const void *p, uint32_t size);  // fresh cell of size bytes for p

// ---- images ------------------------------------------------------------------
extern XLImage *xl_images;
void xl_load_images(void);
XLImage *xl_image_named(const char *id);
uint32_t xl_lookup_export(const char *name);   // 0 if no guest image exports it
XLFn xl_fn_at(uint32_t addr);
const char *xl_name_at(uint32_t addr);         // nearest function name for logs
void xl_run_initializers(void);

// ---- calls -------------------------------------------------------------------
static inline uint32_t xl_arg(XLCPU *c, int i) { return *(uint32_t *)GP(c->r[ESP] + 4 + 4 * i); }
static inline void xl_ret(XLCPU *c, uint32_t eax) { c->r[EAX] = eax; c->r[ESP] += 4; }
uint32_t xl_thunk_for(const char *name);       // guest address of a host function
void *xl_host_fn(uint32_t g);                  // host function for a guest code address (closure)
typedef struct { uint32_t eax, edx; double st0; } XLResult;
uint32_t xl_guest_frame(XLCPU *c, uint32_t nbytes);
void xl_guest_run(XLCPU *c, uint32_t fn, uint32_t sp, XLResult *res);
void xl_longjmp(XLCPU *c, uint32_t buf, int val);
void xl_backtrace(XLCPU *c);
const char *xl_thunk_name(uint32_t a);
// call a guest function from host code: args are 32-bit words pushed right to left
uint32_t xl_guest_call(uint32_t fn, int n, const uint32_t *args);
uint64_t xl_guest_call64(uint32_t fn, int n, const uint32_t *args);
double xl_guest_callf(uint32_t fn, int n, const uint32_t *args);

typedef void (*XLShim)(XLCPU *c);
XLShim xl_find_shim(const char *name);
void *xl_resolve_import(const char *name);     // XLBridge for an imported function

// NSInteger/long values: NSNotFound is NSIntegerMax on both sides
static inline uint32_t xl_long_out(uint64_t v) { return v == 0x7fffffffffffffffull ? 0x7fffffffu : (uint32_t)v; }
static inline int64_t xl_slong_in(uint32_t v) { return v == 0x7fffffffu ? 0x7fffffffffffffffll : (int64_t)(int32_t)v; }
static inline uint64_t xl_ulong_in(uint32_t v) { return v == 0x7fffffffu ? 0x7fffffffffffffffull : (uint64_t)v; }

// ---- types ---------------------------------------------------------------------
typedef struct XLType XLType;
struct XLType {
	char kind;           // letters of the type language; '{' struct, 'P' pointer
	uint32_t gsize, galign;  // guest
	uint32_t hsize, halign;  // host
	XLType *sub;         // P: pointee
	int nfields;         // {: fields
	XLType **fields;
	uint32_t *goff, *hoff;
	const char *name;
	void *ffi;
};
XLType *xl_type_parse(const char **s);
XLType *xl_type_struct(const char *name);       // NULL if unknown
XLType *xl_type_fields(const char *name, XLType **f, int n);
int xl_sig_split(const char *sig, XLType **out, int max);   // [0] = return

// value conversion between guest memory and host memory
void xl_g2h(XLType *t, uint32_t g, void *h);
void xl_h2g(XLType *t, const void *h, uint32_t g);
uint32_t xl_hptr_out(const void *p);
void *xl_fnptr_g2h(uint32_t g, XLType *t);
uint32_t xl_fnptr_h2g(void *p);

// ---- objective-c -----------------------------------------------------------------
void xl_objc_init(void);
uint32_t xl_gsel(SEL s);
SEL xl_hsel(uint32_t g);
Class xl_hclass(uint32_t h);
bool xl_is_guest_class(Class c);
uint32_t xl_guest_imp_of(IMP imp);             // guest address if the method is translated
const XLMethodType *xl_sdk_method(SEL sel, Class cls, int meta);
int xl_method_sig(SEL sel, Class cls, int meta, const char *guest_enc, XLType **t, int max, int *variadic);
void *xl_closure_for(uint32_t guest, const char *sig);
void xl_exc_init(void);
uint32_t xl_data_symbol(const char *name);

#endif

// a guest category replaced a host method (appkit.m keeps the ones it needs)
void xl_host_method_replaced(Class cls, SEL sel, IMP orig, IMP guest);

// bridge type for a host type encoding (bridge.m)
XLType *xl_from_host_enc(const char *e);
