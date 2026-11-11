// Imported functions implemented by the runtime instead of a plain bridge.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <CoreServices/CoreServices.h>
#import <Carbon/Carbon.h>
#include "rt.h"
#import <OpenGL/OpenGL.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <errno.h>
#include <time.h>

#define A(i) xl_arg(c, i)
static inline void ret64(XLCPU *c, uint64_t v)
{
	c->r[EAX] = (uint32_t)v;
	c->r[EDX] = (uint32_t)(v >> 32);
	c->r[ESP] += 4;
}
static inline uint64_t a64(XLCPU *c, int i) { return A(i) | (uint64_t)A(i + 1) << 32; }
#define U32(a) (*(uint32_t *)GP(a))

// ---- memory ------------------------------------------------------------------------------
static void sh_malloc(XLCPU *c) { xl_ret(c, xl_malloc(A(0))); }
static void sh_calloc(XLCPU *c) { xl_ret(c, xl_calloc(A(0) * A(1))); }
static void sh_realloc(XLCPU *c) { xl_ret(c, xl_realloc(A(0), A(1))); }
static void sh_free(XLCPU *c) { xl_free(A(0)); xl_ret(c, 0); }
static void sh_valloc(XLCPU *c)
{
	// page aligned: over-allocate (never freed back precisely; rare)
	uint32_t p = xl_malloc(A(0) + 4096);
	xl_ret(c, (p + 4095) & ~4095u);
}
static void sh_NewPtr(XLCPU *c) { xl_ret(c, xl_malloc(A(0))); }
static void sh_NewPtrClear(XLCPU *c) { xl_ret(c, xl_calloc(A(0))); }
static void sh_DisposePtr(XLCPU *c) { xl_free(A(0)); xl_ret(c, 0); }
static uint32_t new_handle(uint32_t n, int clear)
{
	uint32_t h = xl_calloc(8);
	U32(h) = clear ? xl_calloc(n) : xl_malloc(n);
	U32(h + 4) = n;
	return h;
}
static void sh_NewHandle(XLCPU *c) { xl_ret(c, new_handle(A(0), 0)); }
static void sh_NewHandleClear(XLCPU *c) { xl_ret(c, new_handle(A(0), 1)); }
static void sh_DisposeHandle(XLCPU *c)
{
	uint32_t h = A(0);
	if (h) {
		xl_free(U32(h));
		xl_free(h);
	}
	xl_ret(c, 0);
}
static void sh_GetHandleSize(XLCPU *c) { xl_ret(c, A(0) ? U32(A(0) + 4) : 0); }
static void sh_SetHandleSize(XLCPU *c)
{
	uint32_t h = A(0);
	U32(h) = xl_realloc(U32(h), A(1));
	U32(h + 4) = A(1);
	xl_ret(c, 0);
}
static void sh_nop(XLCPU *c) { xl_ret(c, 0); }
static void sh_PtrToHand(XLCPU *c)
{
	uint32_t h = new_handle(A(2), 0);
	memcpy(GP(U32(h)), GP(A(0)), A(2));
	U32(A(1)) = h;
	xl_ret(c, 0);
}
static void sh_BlockMove(XLCPU *c) { memmove(GP(A(1)), GP(A(0)), A(2)); xl_ret(c, 0); }

// ---- C++ runtime -------------------------------------------------------------------------------
static void sh_new(XLCPU *c) { xl_ret(c, xl_malloc(A(0))); }
static void sh_delete(XLCPU *c) { xl_free(A(0)); xl_ret(c, 0); }
static void sh_guard_acquire(XLCPU *c) { xl_ret(c, *(uint8_t *)GP(A(0)) == 0); }
static void sh_guard_release(XLCPU *c) { *(uint8_t *)GP(A(0)) = 1; xl_ret(c, 0); }
static void sh_cxa_atexit(XLCPU *c) { xl_ret(c, 0); }
static void sh_fatal(XLCPU *c)
{
	uint32_t ret = U32(c->r[ESP]);
	xl_die("fatal runtime call from %s", xl_name_at(ret));
}
static void sh_exception_what(XLCPU *c)
{
	static uint32_t s;
	if (!s)
		s = xl_strdup("std::exception");
	xl_ret(c, s);
}
static void sh_terminate(XLCPU *c) { (void)c; xl_die("std::terminate"); }

// libstdc++ (GCC 4.0) copy-on-write std::string: the object is a pointer to the
// characters, preceded by {length, capacity, refcount}
static void sh_string_ctor(XLCPU *c)
{
	uint32_t self = A(0), s = A(1), n = A(2);
	uint32_t rep = xl_malloc(12 + n + 1);
	U32(rep) = n;
	U32(rep + 4) = n;
	U32(rep + 8) = 0;
	memcpy(GP(rep + 12), GP(s), n);
	*(uint8_t *)GP(rep + 12 + n) = 0;
	U32(self) = rep + 12;
	xl_ret(c, self);
}
static void sh_string_dtor(XLCPU *c)
{
	uint32_t p = U32(A(0));
	if (p >= XL_HEAP_LO && p < XL_HEAP_HI) {
		int32_t *rc = (int32_t *)GP(p - 4);
		if (__atomic_fetch_sub(rc, 1, __ATOMIC_ACQ_REL) <= 0)
			xl_free(p - 12);
	}
	xl_ret(c, 0);
}
static void sh_string_c_str(XLCPU *c) { xl_ret(c, U32(A(0))); }

// red-black tree helpers on guest nodes {color, parent, left, right}
#define RB_COL(x) U32(x)
#define RB_PAR(x) U32((x) + 4)
#define RB_L(x) U32((x) + 8)
#define RB_R(x) U32((x) + 12)
enum { RED = 0, BLACK = 1 };

static uint32_t rb_inc(uint32_t x)
{
	if (RB_R(x)) {
		x = RB_R(x);
		while (RB_L(x))
			x = RB_L(x);
	} else {
		uint32_t y = RB_PAR(x);
		while (x == RB_R(y)) {
			x = y;
			y = RB_PAR(y);
		}
		if (RB_R(x) != y)
			x = y;
	}
	return x;
}

static uint32_t rb_dec(uint32_t x)
{
	if (RB_COL(x) == RED && RB_PAR(RB_PAR(x)) == x)
		x = RB_R(x);
	else if (RB_L(x)) {
		uint32_t y = RB_L(x);
		while (RB_R(y))
			y = RB_R(y);
		x = y;
	} else {
		uint32_t y = RB_PAR(x);
		while (x == RB_L(y)) {
			x = y;
			y = RB_PAR(y);
		}
		x = y;
	}
	return x;
}

static void rot_left(uint32_t x, uint32_t root)
{
	uint32_t y = RB_R(x);
	RB_R(x) = RB_L(y);
	if (RB_L(y))
		RB_PAR(RB_L(y)) = x;
	RB_PAR(y) = RB_PAR(x);
	if (x == U32(root))
		U32(root) = y;
	else if (x == RB_L(RB_PAR(x)))
		RB_L(RB_PAR(x)) = y;
	else
		RB_R(RB_PAR(x)) = y;
	RB_L(y) = x;
	RB_PAR(x) = y;
}

static void rot_right(uint32_t x, uint32_t root)
{
	uint32_t y = RB_L(x);
	RB_L(x) = RB_R(y);
	if (RB_R(y))
		RB_PAR(RB_R(y)) = x;
	RB_PAR(y) = RB_PAR(x);
	if (x == U32(root))
		U32(root) = y;
	else if (x == RB_R(RB_PAR(x)))
		RB_R(RB_PAR(x)) = y;
	else
		RB_L(RB_PAR(x)) = y;
	RB_R(y) = x;
	RB_PAR(x) = y;
}

static void sh_rb_increment(XLCPU *c) { xl_ret(c, rb_inc(A(0))); }
static void sh_rb_decrement(XLCPU *c) { xl_ret(c, rb_dec(A(0))); }

static void sh_rb_insert(XLCPU *c)
{
	int left = A(0) & 0xff;
	uint32_t x = A(1), p = A(2), hdr = A(3);
	uint32_t root = hdr + 4;   // header.parent is the root
	RB_PAR(x) = p;
	RB_L(x) = 0;
	RB_R(x) = 0;
	RB_COL(x) = RED;
	if (left) {
		RB_L(p) = x;
		if (p == hdr) {
			RB_PAR(hdr) = x;
			RB_R(hdr) = x;
		} else if (p == RB_L(hdr))
			RB_L(hdr) = x;
	} else {
		RB_R(p) = x;
		if (p == RB_R(hdr))
			RB_R(hdr) = x;
	}
	while (x != U32(root) && RB_COL(RB_PAR(x)) == RED) {
		uint32_t xpp = RB_PAR(RB_PAR(x));
		if (RB_PAR(x) == RB_L(xpp)) {
			uint32_t y = RB_R(xpp);
			if (y && RB_COL(y) == RED) {
				RB_COL(RB_PAR(x)) = BLACK;
				RB_COL(y) = BLACK;
				RB_COL(xpp) = RED;
				x = xpp;
			} else {
				if (x == RB_R(RB_PAR(x))) {
					x = RB_PAR(x);
					rot_left(x, root);
				}
				RB_COL(RB_PAR(x)) = BLACK;
				RB_COL(xpp) = RED;
				rot_right(xpp, root);
			}
		} else {
			uint32_t y = RB_L(xpp);
			if (y && RB_COL(y) == RED) {
				RB_COL(RB_PAR(x)) = BLACK;
				RB_COL(y) = BLACK;
				RB_COL(xpp) = RED;
				x = xpp;
			} else {
				if (x == RB_L(RB_PAR(x))) {
					x = RB_PAR(x);
					rot_right(x, root);
				}
				RB_COL(RB_PAR(x)) = BLACK;
				RB_COL(xpp) = RED;
				rot_left(xpp, root);
			}
		}
	}
	RB_COL(U32(root)) = BLACK;
	xl_ret(c, 0);
}

static void sh_rb_erase(XLCPU *c)
{
	uint32_t z = A(0), hdr = A(1);
	uint32_t root = hdr + 4, leftmost = hdr + 8, rightmost = hdr + 12;
	uint32_t y = z, x = 0, xp = 0;
	if (!RB_L(y))
		x = RB_R(y);
	else if (!RB_R(y))
		x = RB_L(y);
	else {
		y = RB_R(y);
		while (RB_L(y))
			y = RB_L(y);
		x = RB_R(y);
	}
	if (y != z) {
		RB_PAR(RB_L(z)) = y;
		RB_L(y) = RB_L(z);
		if (y != RB_R(z)) {
			xp = RB_PAR(y);
			if (x)
				RB_PAR(x) = RB_PAR(y);
			RB_L(RB_PAR(y)) = x;
			RB_R(y) = RB_R(z);
			RB_PAR(RB_R(z)) = y;
		} else
			xp = y;
		if (U32(root) == z)
			U32(root) = y;
		else if (RB_L(RB_PAR(z)) == z)
			RB_L(RB_PAR(z)) = y;
		else
			RB_R(RB_PAR(z)) = y;
		RB_PAR(y) = RB_PAR(z);
		uint32_t t = RB_COL(y);
		RB_COL(y) = RB_COL(z);
		RB_COL(z) = t;
		y = z;
	} else {
		xp = RB_PAR(y);
		if (x)
			RB_PAR(x) = RB_PAR(y);
		if (U32(root) == z)
			U32(root) = x;
		else if (RB_L(RB_PAR(z)) == z)
			RB_L(RB_PAR(z)) = x;
		else
			RB_R(RB_PAR(z)) = x;
		if (U32(leftmost) == z) {
			if (!RB_R(z))
				U32(leftmost) = RB_PAR(z);
			else {
				uint32_t m = x;
				while (RB_L(m))
					m = RB_L(m);
				U32(leftmost) = m;
			}
		}
		if (U32(rightmost) == z) {
			if (!RB_L(z))
				U32(rightmost) = RB_PAR(z);
			else {
				uint32_t m = x;
				while (RB_R(m))
					m = RB_R(m);
				U32(rightmost) = m;
			}
		}
	}
	if (RB_COL(y) != RED) {
		while (x != U32(root) && (!x || RB_COL(x) == BLACK)) {
			if (x == RB_L(xp)) {
				uint32_t w = RB_R(xp);
				if (RB_COL(w) == RED) {
					RB_COL(w) = BLACK;
					RB_COL(xp) = RED;
					rot_left(xp, root);
					w = RB_R(xp);
				}
				if ((!RB_L(w) || RB_COL(RB_L(w)) == BLACK) && (!RB_R(w) || RB_COL(RB_R(w)) == BLACK)) {
					RB_COL(w) = RED;
					x = xp;
					xp = RB_PAR(xp);
				} else {
					if (!RB_R(w) || RB_COL(RB_R(w)) == BLACK) {
						RB_COL(RB_L(w)) = BLACK;
						RB_COL(w) = RED;
						rot_right(w, root);
						w = RB_R(xp);
					}
					RB_COL(w) = RB_COL(xp);
					RB_COL(xp) = BLACK;
					if (RB_R(w))
						RB_COL(RB_R(w)) = BLACK;
					rot_left(xp, root);
					break;
				}
			} else {
				uint32_t w = RB_L(xp);
				if (RB_COL(w) == RED) {
					RB_COL(w) = BLACK;
					RB_COL(xp) = RED;
					rot_right(xp, root);
					w = RB_L(xp);
				}
				if ((!RB_R(w) || RB_COL(RB_R(w)) == BLACK) && (!RB_L(w) || RB_COL(RB_L(w)) == BLACK)) {
					RB_COL(w) = RED;
					x = xp;
					xp = RB_PAR(xp);
				} else {
					if (!RB_L(w) || RB_COL(RB_L(w)) == BLACK) {
						RB_COL(RB_R(w)) = BLACK;
						RB_COL(w) = RED;
						rot_left(w, root);
						w = RB_L(xp);
					}
					RB_COL(w) = RB_COL(xp);
					RB_COL(xp) = BLACK;
					if (RB_L(w))
						RB_COL(RB_L(w)) = BLACK;
					rot_right(xp, root);
					break;
				}
			}
		}
		if (x)
			RB_COL(x) = BLACK;
	}
	xl_ret(c, y);
}

// ---- libgcc 64-bit arithmetic --------------------------------------------------------------------
static void sh_divdi3(XLCPU *c) { int64_t b = (int64_t)a64(c, 2); ret64(c, b ? (uint64_t)((int64_t)a64(c, 0) / b) : 0); }
static void sh_moddi3(XLCPU *c) { int64_t b = (int64_t)a64(c, 2); ret64(c, b ? (uint64_t)((int64_t)a64(c, 0) % b) : 0); }
static void sh_udivdi3(XLCPU *c) { uint64_t b = a64(c, 2); ret64(c, b ? a64(c, 0) / b : 0); }
static void sh_umoddi3(XLCPU *c) { uint64_t b = a64(c, 2); ret64(c, b ? a64(c, 0) % b : 0); }
static void sh_fixunsdfdi(XLCPU *c)
{
	double d;
	memcpy(&d, GP(c->r[ESP] + 4), 8);
	ret64(c, d <= 0 ? 0 : (uint64_t)d);
}

// ---- keymgr / dyld leftovers -----------------------------------------------------------------------
static void sh_keymgr_get2(XLCPU *c) { if (A(1)) U32(A(1)) = 0; xl_ret(c, 0); }

// ---- messaging through function pointers ------------------------------------------------------------
static void sh_msgSend(XLCPU *c) { xl_msgsend(c, XL_MSG_NORMAL); }
static void sh_msgSend_stret(XLCPU *c) { xl_msgsend(c, XL_MSG_STRET); }
static void sh_msgSend_fpret(XLCPU *c) { xl_msgsend(c, XL_MSG_FPRET); }
static void sh_msgSendSuper(XLCPU *c) { xl_msgsend(c, XL_MSG_SUPER); }
static void sh_msgSendSuper_stret(XLCPU *c) { xl_msgsend(c, XL_MSG_SUPER_STRET); }

void xl_sh_cxa_allocate_exception(XLCPU *c);
void xl_sh_cxa_free_exception(XLCPU *c);
void xl_sh_cxa_throw(XLCPU *c);
void xl_sh_cxa_begin_catch(XLCPU *c);
void xl_sh_cxa_end_catch(XLCPU *c);
void xl_sh_cxa_get_exception_ptr(XLCPU *c);
void xl_sh_cxa_rethrow(XLCPU *c);
void xl_sh_unwind_resume(XLCPU *c);
void xl_sh_cxa_current_exception_type(XLCPU *c);
void xl_sh_uncaught_exception(XLCPU *c);
void xl_sh_cxa_call_unexpected(XLCPU *c);
void xl_sh_objc_exception_try_enter(XLCPU *c);
void xl_sh_objc_exception_try_exit(XLCPU *c);
void xl_sh_objc_exception_extract(XLCPU *c);
void xl_sh_objc_exception_match(XLCPU *c);
void xl_sh_objc_exception_throw(XLCPU *c);

static void sh_longjmp(XLCPU *c) { xl_longjmp(c, A(0), (int)A(1)); }

// ---- process -------------------------------------------------------------------------------------------
static void sh_exit(XLCPU *c) { exit((int)A(0)); }
static void sh_abort(XLCPU *c)
{
	uint32_t ret = U32(c->r[ESP]);
	xl_die("guest abort() from %s", xl_name_at(ret));
}

static XLMap env_cache;
static void sh_getenv(XLCPU *c)
{
	const char *v = getenv(GP(A(0)));
	if (!v) {
		xl_ret(c, 0);
		return;
	}
	uint64_t k = (uint64_t)(uintptr_t)v;
	uint32_t g = (uint32_t)xl_map_get(&env_cache, k);
	if (!g || strcmp(GP(g), v)) {
		g = xl_strdup(v);
		xl_map_put(&env_cache, k, g);
	}
	xl_ret(c, g);
}

static __thread uint32_t errno_cell;
static void sh_error(XLCPU *c)
{
	if (!errno_cell)
		errno_cell = xl_calloc(4);
	U32(errno_cell) = (uint32_t)errno;
	xl_ret(c, errno_cell);
}

static void sh_dlopen(XLCPU *c)
{
	void *h = dlopen(A(0) ? GP(A(0)) : NULL, (int)A(1));
	xl_ret(c, xl_h(h));
}
static void sh_dlsym(XLCPU *c)
{
	const char *nm = GP(A(1));
	char buf[256];
	snprintf(buf, sizeof buf, "_%s", nm);
	uint32_t g = xl_lookup_export(buf);
	if (!g && dlsym(RTLD_DEFAULT, nm))
		g = xl_thunk_for(buf);
	xl_ret(c, g);
}
static void sh_dlerror(XLCPU *c)
{
	const char *e = dlerror();
	xl_ret(c, e ? xl_strdup(e) : 0);
}

static void sh_CFBundleGetFunctionPointerForName(XLCPU *c)
{
	NSString *nm = (NSString *)xl_p(A(1));
	char buf[256];
	snprintf(buf, sizeof buf, "_%s", [nm UTF8String]);
	uint32_t g = xl_lookup_export(buf);
	if (!g && dlsym(RTLD_DEFAULT, buf + 1))
		g = xl_thunk_for(buf);
	xl_ret(c, g);
}

static void sh_CFDataGetBytePtr(XLCPU *c)
{
	CFDataRef d = xl_p(A(0));
	const UInt8 *p = d ? CFDataGetBytePtr(d) : NULL;
	xl_ret(c, p ? xl_remap(p, (size_t)CFDataGetLength(d)) : 0);
}

static void sh_zero(XLCPU *c) { xl_ret(c, 0); }

static XLMap glstr;
static void sh_glGetString(XLCPU *c)
{
	const GLubyte *s = glGetString(A(0));
	uint32_t g = (uint32_t)xl_map_get(&glstr, A(0) + 1);
	if (s && !g) {
		g = xl_strdup((const char *)s);
		xl_map_put(&glstr, A(0) + 1, g);
	}
	xl_ret(c, s ? g : 0);
}

// ---- time -----------------------------------------------------------------------------------------------
static __thread uint32_t tm_buf;
static void sh_localtime(XLCPU *c)
{
	time_t t = (int32_t)U32(A(0));
	struct tm r;
	localtime_r(&t, &r);
	if (!tm_buf)
		tm_buf = xl_calloc(48);
	int32_t *o = GP(tm_buf);
	o[0] = r.tm_sec; o[1] = r.tm_min; o[2] = r.tm_hour; o[3] = r.tm_mday; o[4] = r.tm_mon;
	o[5] = r.tm_year; o[6] = r.tm_wday; o[7] = r.tm_yday; o[8] = r.tm_isdst; o[9] = (int32_t)r.tm_gmtoff;
	o[10] = 0;
	xl_ret(c, tm_buf);
}

// ---- files: the 10.4 i386 struct stat ----------------------------------------------------------------------
static void put_stat(uint32_t g, const struct stat *s)
{
	uint8_t *p = GP(g);
	memset(p, 0, 96);
	*(uint32_t *)(p + 0) = (uint32_t)s->st_dev;
	*(uint32_t *)(p + 4) = (uint32_t)s->st_ino;
	*(uint16_t *)(p + 8) = s->st_mode;
	*(uint16_t *)(p + 10) = s->st_nlink;
	*(uint32_t *)(p + 12) = s->st_uid;
	*(uint32_t *)(p + 16) = s->st_gid;
	*(uint32_t *)(p + 20) = (uint32_t)s->st_rdev;
	*(int32_t *)(p + 24) = (int32_t)s->st_atimespec.tv_sec;
	*(int32_t *)(p + 28) = (int32_t)s->st_atimespec.tv_nsec;
	*(int32_t *)(p + 32) = (int32_t)s->st_mtimespec.tv_sec;
	*(int32_t *)(p + 36) = (int32_t)s->st_mtimespec.tv_nsec;
	*(int32_t *)(p + 40) = (int32_t)s->st_ctimespec.tv_sec;
	*(int32_t *)(p + 44) = (int32_t)s->st_ctimespec.tv_nsec;
	*(int64_t *)(p + 48) = s->st_size;
	*(int64_t *)(p + 56) = s->st_blocks;
	*(uint32_t *)(p + 64) = (uint32_t)s->st_blksize;
	*(uint32_t *)(p + 68) = s->st_flags;
	*(uint32_t *)(p + 72) = s->st_gen;
}
static void sh_stat(XLCPU *c)
{
	struct stat s;
	int r = stat(GP(A(0)), &s);
	if (!r)
		put_stat(A(1), &s);
	xl_ret(c, (uint32_t)r);
}
static void sh_lstat(XLCPU *c)
{
	struct stat s;
	int r = lstat(GP(A(0)), &s);
	if (!r)
		put_stat(A(1), &s);
	xl_ret(c, (uint32_t)r);
}
static void sh_fstat(XLCPU *c)
{
	struct stat s;
	int r = fstat((int)A(0), &s);
	if (!r)
		put_stat(A(1), &s);
	xl_ret(c, (uint32_t)r);
}
static void sh_statfs(XLCPU *c)
{
	struct statfs s;
	int r = statfs(GP(A(0)), &s);
	if (!r) {
		uint8_t *p = GP(A(1));
		memset(p, 0, 272);
		uint32_t bs = s.f_bsize;
		uint64_t scale = 1;
		while ((s.f_blocks / scale) > 0x7fffffff)
			scale *= 2;
		*(int32_t *)(p + 4) = (int32_t)(bs * scale);
		*(int32_t *)(p + 8) = (int32_t)s.f_iosize;
		*(int32_t *)(p + 12) = (int32_t)(s.f_blocks / scale);
		*(int32_t *)(p + 16) = (int32_t)(s.f_bfree / scale);
		*(int32_t *)(p + 20) = (int32_t)(s.f_bavail / scale);
		*(int32_t *)(p + 24) = (int32_t)s.f_files;
		*(int32_t *)(p + 28) = (int32_t)s.f_ffree;
		*(int32_t *)(p + 48) = (int32_t)s.f_flags;
		strlcpy((char *)p + 60, s.f_fstypename, 15);
		strlcpy((char *)p + 75, s.f_mntonname, 90);
		strlcpy((char *)p + 165, s.f_mntfromname, 90);
	}
	xl_ret(c, (uint32_t)r);
}

// ---- pthreads: guest objects map to host ones ----------------------------------------------------------------
static XLMap mutexes, conds;

static pthread_mutex_t *mutex_for(uint32_t g, int create)
{
	pthread_mutex_t *m = (pthread_mutex_t *)xl_map_get(&mutexes, g);
	if (!m && create) {
		m = malloc(sizeof *m);
		pthread_mutexattr_t at;
		pthread_mutexattr_init(&at);
		// i386 PTHREAD_RECURSIVE_MUTEX_INITIALIZER signature
		if (U32(g) == 0x32AAABA7 && U32(g + 4) == 0)
			pthread_mutexattr_settype(&at, PTHREAD_MUTEX_NORMAL);
		pthread_mutex_init(m, &at);
		pthread_mutexattr_destroy(&at);
		xl_map_put(&mutexes, g, (uint64_t)m);
	}
	return m;
}

static XLMap mattrs;
static void sh_mutexattr_init(XLCPU *c) { xl_map_put(&mattrs, A(0), PTHREAD_MUTEX_NORMAL + 1); xl_ret(c, 0); }
static void sh_mutexattr_settype(XLCPU *c) { xl_map_put(&mattrs, A(0), A(1) + 1); xl_ret(c, 0); }
static void sh_mutex_init(XLCPU *c)
{
	uint32_t g = A(0);
	pthread_mutex_t *m = (pthread_mutex_t *)xl_map_get(&mutexes, g);
	if (!m) {
		m = malloc(sizeof *m);
		xl_map_put(&mutexes, g, (uint64_t)m);
	}
	pthread_mutexattr_t at;
	pthread_mutexattr_init(&at);
	uint64_t ty = A(1) ? xl_map_get(&mattrs, A(1)) : 0;
	if (ty)
		pthread_mutexattr_settype(&at, (int)ty - 1);
	pthread_mutex_init(m, &at);
	pthread_mutexattr_destroy(&at);
	U32(g) = 0x4d555458;
	xl_ret(c, 0);
}
static void sh_mutex_lock(XLCPU *c) { xl_ret(c, (uint32_t)pthread_mutex_lock(mutex_for(A(0), 1))); }
static void sh_mutex_trylock(XLCPU *c) { xl_ret(c, (uint32_t)pthread_mutex_trylock(mutex_for(A(0), 1))); }
static void sh_mutex_unlock(XLCPU *c) { xl_ret(c, (uint32_t)pthread_mutex_unlock(mutex_for(A(0), 1))); }
static void sh_mutex_destroy(XLCPU *c)
{
	pthread_mutex_t *m = mutex_for(A(0), 0);
	if (m) {
		pthread_mutex_destroy(m);
		xl_map_del(&mutexes, A(0));
		free(m);
	}
	xl_ret(c, 0);
}

static pthread_cond_t *cond_for(uint32_t g)
{
	pthread_cond_t *v = (pthread_cond_t *)xl_map_get(&conds, g);
	if (!v) {
		v = malloc(sizeof *v);
		pthread_cond_init(v, NULL);
		xl_map_put(&conds, g, (uint64_t)v);
	}
	return v;
}
static void sh_cond_init(XLCPU *c) { cond_for(A(0)); xl_ret(c, 0); }
static void sh_cond_destroy(XLCPU *c) { xl_ret(c, 0); }
static void sh_cond_signal(XLCPU *c) { xl_ret(c, (uint32_t)pthread_cond_signal(cond_for(A(0)))); }
static void sh_cond_broadcast(XLCPU *c) { xl_ret(c, (uint32_t)pthread_cond_broadcast(cond_for(A(0)))); }
static void sh_cond_wait(XLCPU *c) { xl_ret(c, (uint32_t)pthread_cond_wait(cond_for(A(0)), mutex_for(A(1), 1))); }
static void sh_cond_timedwait_relative_np(XLCPU *c)
{
	struct timespec ts = {(int32_t)U32(A(2)), (int32_t)U32(A(2) + 4)};
	xl_ret(c, (uint32_t)pthread_cond_timedwait_relative_np(cond_for(A(0)), mutex_for(A(1), 1), &ts));
}

static XLMap attrs;   // guest attr -> detach state + 1
static void sh_attr_init(XLCPU *c) { xl_map_put(&attrs, A(0), PTHREAD_CREATE_JOINABLE + 1); xl_ret(c, 0); }
static void sh_attr_setdetachstate(XLCPU *c) { xl_map_put(&attrs, A(0), A(1) + 1); xl_ret(c, 0); }

typedef struct { uint32_t fn, arg; } ThreadStart;
static void *thread_main(void *p)
{
	ThreadStart ts = *(ThreadStart *)p;
	free(p);
	@autoreleasepool {
		uint32_t a[1] = {ts.arg};
		return (void *)(uintptr_t)xl_guest_call(ts.fn, 1, a);
	}
}
static void sh_pthread_create(XLCPU *c)
{
	ThreadStart *ts = malloc(sizeof *ts);
	ts->fn = A(2);
	ts->arg = A(3);
	pthread_attr_t at;
	pthread_attr_init(&at);
	uint64_t ds = A(1) ? xl_map_get(&attrs, A(1)) : 0;
	if (ds)
		pthread_attr_setdetachstate(&at, (int)ds - 1);
	pthread_t t;
	int r = pthread_create(&t, &at, thread_main, ts);
	pthread_attr_destroy(&at);
	if (!r && A(0))
		U32(A(0)) = xl_h(t);
	xl_ret(c, (uint32_t)r);
}

static void sh_pthread_key_create(XLCPU *c)
{
	pthread_key_t k;
	int r = pthread_key_create(&k, NULL);
	U32(A(0)) = (uint32_t)k;
	xl_ret(c, (uint32_t)r);
}

// ---- CF allocators: guest allocators become one host allocator over the guest heap ----------------
static void *win_alloc(CFIndex n, CFOptionFlags h, void *info) { return GP(xl_malloc((uint32_t)n)); }
static void *win_realloc(void *p, CFIndex n, CFOptionFlags h, void *info) { return GP(xl_realloc(GA(p), (uint32_t)n)); }
static void win_dealloc(void *p, void *info) { xl_free(GA(p)); }
static CFAllocatorRef win_allocator(void)
{
	static CFAllocatorRef a;
	if (!a) {
		CFAllocatorContext ctx = {0, NULL, NULL, NULL, NULL, win_alloc, win_realloc, win_dealloc, NULL};
		a = CFAllocatorCreate(kCFAllocatorDefault, &ctx);
	}
	return a;
}
static void sh_CFAllocatorCreate(XLCPU *c) { CFRetain(win_allocator()); xl_ret(c, xl_h(win_allocator())); }
static void sh_CFAllocatorAllocate(XLCPU *c) { xl_ret(c, xl_malloc(A(1))); }
static void sh_CFAllocatorReallocate(XLCPU *c) { xl_ret(c, xl_realloc(A(1), A(2))); }
static void sh_CFAllocatorDeallocate(XLCPU *c) { xl_free(A(1)); xl_ret(c, 0); }

// ---- the display is the user's: no capture, mode switches or gamma changes -----------------------
static void sh_ok(XLCPU *c) { xl_ret(c, 0); }

// local-domain application support needs admin rights now: use the user's
static void sh_FSFindFolder(XLCPU *c)
{
	short dom = (short)A(0);
	OSType type = A(1);
	if ((dom == kLocalDomain || dom == kSystemDomain || dom == kOnAppropriateDisk) && type == kApplicationSupportFolderType)
		dom = kUserDomain;
	OSErr r = FSFindFolder(dom, type, (Boolean)A(2), A(3) ? GP(A(3)) : NULL);
	xl_ret(c, (uint32_t)(int32_t)r);
}

// Apple Help: pages open in the browser when Help Viewer is gone (appkit.m)
extern int xl_help_in_browser;
void xl_help_register(NSURL *url);
int xl_help_goto(NSString *book, NSString *path, NSString *anchor);
int xl_help_anchor(NSString *book, NSString *anchor);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void sh_AHRegisterHelpBook(XLCPU *c)
{
	const FSRef *ref = A(0) ? (const FSRef *)GP(A(0)) : NULL;
	CFURLRef u = ref ? CFURLCreateFromFSRef(NULL, ref) : NULL;
	if (u)
		xl_help_register((__bridge NSURL *)u);
	OSStatus r = xl_help_in_browser || !ref ? (u ? 0 : paramErr) : AHRegisterHelpBook(ref);
	if (u)
		CFRelease(u);
	xl_ret(c, (uint32_t)r);
}
#pragma clang diagnostic pop
static void sh_AHRegisterHelpBookWithURL(XLCPU *c)
{
	NSURL *u = XL_ID(A(0));
	xl_help_register(u);
	xl_ret(c, (uint32_t)(xl_help_in_browser ? 0 : AHRegisterHelpBookWithURL((__bridge CFURLRef)u)));
}
static void sh_AHGotoPage(XLCPU *c)
{
	NSString *book = XL_ID(A(0)), *path = XL_ID(A(1)), *anchor = XL_ID(A(2));
	xl_ret(c, (uint32_t)(xl_help_in_browser ? xl_help_goto(book, path, anchor)
		: AHGotoPage((__bridge CFStringRef)book, (__bridge CFStringRef)path, (__bridge CFStringRef)anchor)));
}
static void sh_AHLookupAnchor(XLCPU *c)
{
	NSString *book = XL_ID(A(0)), *anchor = XL_ID(A(1));
	xl_ret(c, (uint32_t)(xl_help_in_browser ? xl_help_anchor(book, anchor)
		: AHLookupAnchor((__bridge CFStringRef)book, (__bridge CFStringRef)anchor)));
}
static void sh_AHGotoMainTOC(XLCPU *c)
{
	xl_ret(c, (uint32_t)(xl_help_in_browser ? xl_help_goto(nil, nil, nil) : AHGotoMainTOC((AHTOCType)A(0))));
}

// CFStringGetCharactersPtr: strings made over guest buffers (external characters)
// hand back that buffer; any other string has no guest-visible pointer
static void sh_CFStringGetCharactersPtr(XLCPU *c)
{
	CFStringRef str = (CFStringRef)xl_p(A(0));
	const UniChar *p = str ? CFStringGetCharactersPtr(str) : NULL;
	xl_ret(c, p && xl_in_window(p) ? (uint32_t)((const uint8_t *)p - XG) : 0);
}
// FSSpec resource files are gone from the 64-bit Resource Manager: creating
// or opening one fails with fnfErr (used for Finder alias files only)
static OSErr res_err_override;
static void sh_FSpCreateResFile(XLCPU *c) { res_err_override = fnfErr; xl_ret(c, 0); }
static void sh_FSpOpenResFile(XLCPU *c) { res_err_override = fnfErr; xl_ret(c, 0xffffffffu); }
static void sh_NewAlias(XLCPU *c)
{
	if (A(2))
		U32(A(2)) = 0;
	xl_ret(c, (uint32_t)(int32_t)fnfErr);
}
static void sh_ResError(XLCPU *c)
{
	OSErr e = res_err_override ? res_err_override : ResError();
	res_err_override = 0;
	xl_ret(c, (uint32_t)(int32_t)e);
}

// GetProcessInformation: i386 ProcessInfoRec is
//   0 length, 4 name, 8 number(8), 16 type, 20 signature, 24 mode, 28 location,
//   32 size, 36 freeMem, 40 launcher(8), 48 launchDate, 52 activeTime, 56 appSpec (FSSpec *)
// the FSSpec cannot be filled in (no FSSpec on 64-bit): it is left alone
static void sh_GetProcessInformation(XLCPU *c)
{
	ProcessSerialNumber psn;
	memcpy(&psn, GP(A(0)), sizeof psn);
	uint32_t g = A(1);
	ProcessInfoRec r;
	memset(&r, 0, sizeof r);
	r.processInfoLength = sizeof r;
	uint32_t name = U32(g + 4);
	r.processName = name ? (StringPtr)GP(name) : NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	OSErr e = GetProcessInformation(&psn, &r);
#pragma clang diagnostic pop
	if (e == noErr) {
		memcpy(GP(g + 8), &r.processNumber, 8);
		U32(g + 16) = r.processType;
		U32(g + 20) = r.processSignature;
		U32(g + 24) = r.processMode;
		U32(g + 28) = 0;
		U32(g + 32) = r.processSize;
		U32(g + 36) = r.processFreeMem;
		memcpy(GP(g + 40), &r.processLauncher, 8);
		U32(g + 48) = r.processLaunchDate;
		U32(g + 52) = r.processActiveTime;
	}
	xl_ret(c, (uint32_t)(int32_t)e);
}

// CGL objects with out-parameters: the host object becomes a handle in the guest slot
static void sh_CGLQueryRendererInfo(XLCPU *c)
{
	CGLRendererInfoObj r = NULL;
	GLint n = 0;
	CGLError e = CGLQueryRendererInfo(A(0), &r, &n);
	if (A(1))
		U32(A(1)) = r ? xl_h(r) : 0;
	if (A(2))
		*(int32_t *)GP(A(2)) = n;
	xl_ret(c, e);
}
static void sh_CGLChoosePixelFormat(XLCPU *c)
{
	CGLPixelFormatObj pf = NULL;
	GLint n = 0;
	CGLError e = CGLChoosePixelFormat((const CGLPixelFormatAttribute *)GP(A(0)), &pf, &n);
	if (A(1))
		U32(A(1)) = pf ? xl_h(pf) : 0;
	if (A(2))
		*(int32_t *)GP(A(2)) = n;
	xl_ret(c, e);
}

static void sh_glTexImage2D(XLCPU *c)
{
	if (getenv("XL_GLLOG")) {
		GLint al = 0, rl = 0, cs = 0;
		glGetIntegerv(GL_UNPACK_ALIGNMENT, &al);
		glGetIntegerv(GL_UNPACK_ROW_LENGTH, &rl);
		glGetIntegerv(GL_UNPACK_CLIENT_STORAGE_APPLE, &cs);
		xl_log("glTexImage2D target %x level %d ifmt %x %dx%d fmt %x type %x data %08x align %d rowlen %d client %d",
			A(0), A(1), A(2), A(3), A(4), A(6), A(7), A(8), al, rl, cs);
	}
	glTexImage2D(A(0), (GLint)A(1), (GLint)A(2), (GLsizei)A(3), (GLsizei)A(4), (GLint)A(5), A(6), A(7),
		A(8) ? GP(A(8)) : NULL);
	// a rectangle texture starts out clamped (ARB_texture_rectangle), but the GL
	// of Apple silicon starts it out repeating, and the home screen's photo
	// meshes reach beyond their texture: the photo was drawn again beside itself
	if (A(0) == GL_TEXTURE_RECTANGLE_EXT) {
		glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_RECTANGLE_EXT, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	}
	xl_ret(c, 0);
}

// ---- Component Manager -----------------------------------------------------------------------
// Components and instances are opaque references (small integers, not
// pointers). The app's own audio units cannot be registered: their entry
// points take i386 ComponentParameters, so registering fails as it may.
static void sh_RegisterComponent(XLCPU *c) { xl_ret(c, 0); }

static void sh_FindNextComponent(XLCPU *c)
{
	Component r = FindNextComponent((Component)xl_p(A(0)), A(1) ? (ComponentDescription *)GP(A(1)) : NULL);
	xl_ret(c, r ? xl_h(r) : 0);
}

static void sh_UnregisterComponent(XLCPU *c) { xl_ret(c, (uint16_t)UnregisterComponent((Component)xl_p(A(0)))); }

static void sh_SetDefaultComponent(XLCPU *c)
{
	xl_ret(c, (uint16_t)SetDefaultComponent((Component)xl_p(A(0)), (SInt16)A(1)));
}

static void sh_GetComponentInfo(XLCPU *c)
{
	ComponentDescription d = {0};
	OSErr e = GetComponentInfo((Component)xl_p(A(0)), &d, NULL, NULL, NULL);
	if (A(1))
		memcpy(GP(A(1)), &d, sizeof d);
	xl_ret(c, (uint16_t)e);
}

uint32_t xl_gi_open(uint32_t subtype);
int xl_gi_close(uint32_t h);

static void sh_OpenDefaultComponent(XLCPU *c)
{
	if (A(0) == 'grip') {   // graphics importers are emulated (qtimport.m)
		xl_ret(c, xl_gi_open(A(1)));
		return;
	}
	ComponentInstance r = OpenDefaultComponent((OSType)A(0), (OSType)A(1));
	xl_ret(c, r ? xl_h(r) : 0);
}

static void sh_CloseComponent(XLCPU *c)
{
	if (xl_gi_close(A(0))) {
		xl_ret(c, 0);
		return;
	}
	xl_ret(c, (uint16_t)CloseComponent((ComponentInstance)xl_p(A(0))));
}

// maptable.m
void xl_sh_NSCreateMapTable(XLCPU *c);
void xl_sh_NSCreateMapTableWithZone(XLCPU *c);
void xl_sh_NSFreeMapTable(XLCPU *c);
void xl_sh_NSResetMapTable(XLCPU *c);
void xl_sh_NSMapGet(XLCPU *c);
void xl_sh_NSMapMember(XLCPU *c);
void xl_sh_NSMapInsert(XLCPU *c);
void xl_sh_NSMapInsertKnownAbsent(XLCPU *c);
void xl_sh_NSMapInsertIfAbsent(XLCPU *c);
void xl_sh_NSMapRemove(XLCPU *c);
void xl_sh_NSCountMapTable(XLCPU *c);
void xl_sh_NSAllMapTableValues(XLCPU *c);
void xl_sh_NSAllMapTableKeys(XLCPU *c);
void xl_sh_NSEnumerateMapTable(XLCPU *c);
void xl_sh_NSNextMapEnumeratorPair(XLCPU *c);
void xl_sh_NSEndMapTableEnumeration(XLCPU *c);
void xl_sh_NSCreateHashTable(XLCPU *c);
void xl_sh_NSCreateHashTableWithZone(XLCPU *c);
void xl_sh_NSFreeHashTable(XLCPU *c);
void xl_sh_NSResetHashTable(XLCPU *c);
void xl_sh_NSHashGet(XLCPU *c);
void xl_sh_NSHashInsert(XLCPU *c);
void xl_sh_NSHashInsertKnownAbsent(XLCPU *c);
void xl_sh_NSHashInsertIfAbsent(XLCPU *c);
void xl_sh_NSHashRemove(XLCPU *c);
void xl_sh_NSCountHashTable(XLCPU *c);
void xl_sh_NSEnumerateHashTable(XLCPU *c);
void xl_sh_NSNextHashEnumeratorItem(XLCPU *c);
void xl_sh_NSEndHashTableEnumeration(XLCPU *c);

// ---- table ---------------------------------------------------------------------------------------------------------
typedef struct { const char *name; XLShim fn; } ShimEnt;
static const ShimEnt shims[] = {
	{"_FSpCreateResFile", sh_FSpCreateResFile}, {"_FSpOpenResFile", sh_FSpOpenResFile}, {"_NewAlias", sh_NewAlias},
	{"_ResError", sh_ResError}, {"_CGLQueryRendererInfo", sh_CGLQueryRendererInfo},
	{"_CGLChoosePixelFormat", sh_CGLChoosePixelFormat}, {"_glTexImage2D", sh_glTexImage2D},
	{"_NSCreateMapTable", xl_sh_NSCreateMapTable}, {"_NSCreateMapTableWithZone", xl_sh_NSCreateMapTableWithZone}, {"_NSFreeMapTable", xl_sh_NSFreeMapTable}, {"_NSResetMapTable", xl_sh_NSResetMapTable}, {"_NSMapGet", xl_sh_NSMapGet}, {"_NSMapMember", xl_sh_NSMapMember}, {"_NSMapInsert", xl_sh_NSMapInsert}, {"_NSMapInsertKnownAbsent", xl_sh_NSMapInsertKnownAbsent}, {"_NSMapInsertIfAbsent", xl_sh_NSMapInsertIfAbsent}, {"_NSMapRemove", xl_sh_NSMapRemove}, {"_NSCountMapTable", xl_sh_NSCountMapTable}, {"_NSAllMapTableValues", xl_sh_NSAllMapTableValues}, {"_NSAllMapTableKeys", xl_sh_NSAllMapTableKeys}, {"_NSEnumerateMapTable", xl_sh_NSEnumerateMapTable}, {"_NSNextMapEnumeratorPair", xl_sh_NSNextMapEnumeratorPair}, {"_NSEndMapTableEnumeration", xl_sh_NSEndMapTableEnumeration}, {"_NSCreateHashTable", xl_sh_NSCreateHashTable}, {"_NSCreateHashTableWithZone", xl_sh_NSCreateHashTableWithZone}, {"_NSFreeHashTable", xl_sh_NSFreeHashTable}, {"_NSResetHashTable", xl_sh_NSResetHashTable}, {"_NSHashGet", xl_sh_NSHashGet}, {"_NSHashInsert", xl_sh_NSHashInsert}, {"_NSHashInsertKnownAbsent", xl_sh_NSHashInsertKnownAbsent}, {"_NSHashInsertIfAbsent", xl_sh_NSHashInsertIfAbsent}, {"_NSHashRemove", xl_sh_NSHashRemove}, {"_NSCountHashTable", xl_sh_NSCountHashTable}, {"_NSEnumerateHashTable", xl_sh_NSEnumerateHashTable}, {"_NSNextHashEnumeratorItem", xl_sh_NSNextHashEnumeratorItem}, {"_NSEndHashTableEnumeration", xl_sh_NSEndHashTableEnumeration},
	{"_RegisterComponent", sh_RegisterComponent}, {"_FindNextComponent", sh_FindNextComponent},
	{"_UnregisterComponent", sh_UnregisterComponent}, {"_SetDefaultComponent", sh_SetDefaultComponent},
	{"_GetComponentInfo", sh_GetComponentInfo}, {"_OpenDefaultComponent", sh_OpenDefaultComponent},
	{"_CloseComponent", sh_CloseComponent}, {"_GetProcessInformation", sh_GetProcessInformation},
	{"_malloc", sh_malloc}, {"_calloc", sh_calloc}, {"_realloc", sh_realloc}, {"_free", sh_free},
	{"_valloc", sh_valloc},
	{"_NewPtr", sh_NewPtr}, {"_NewPtrClear", sh_NewPtrClear}, {"_DisposePtr", sh_DisposePtr},
	{"_NewHandle", sh_NewHandle}, {"_NewHandleClear", sh_NewHandleClear}, {"_DisposeHandle", sh_DisposeHandle},
	{"_GetHandleSize", sh_GetHandleSize}, {"_SetHandleSize", sh_SetHandleSize}, {"_HLock", sh_nop},
	{"_HUnlock", sh_nop}, {"_PtrToHand", sh_PtrToHand}, {"_BlockMove", sh_BlockMove}, {"_MemError", sh_zero},
	{"__Znwm", sh_new}, {"__Znam", sh_new}, {"__ZnwmRKSt9nothrow_t", sh_new},
	{"__ZdlPv", sh_delete}, {"__ZdaPv", sh_delete}, {"__ZdlPvRKSt9nothrow_t", sh_delete},
	{"___cxa_guard_acquire", sh_guard_acquire}, {"___cxa_guard_release", sh_guard_release},
	{"___cxa_guard_abort", sh_nop}, {"___cxa_finalize", sh_nop}, {"___cxa_atexit", sh_cxa_atexit}, {"_atexit", sh_cxa_atexit},
	{"___cxa_allocate_exception", xl_sh_cxa_allocate_exception}, {"___cxa_free_exception", xl_sh_cxa_free_exception},
	{"___cxa_throw", xl_sh_cxa_throw}, {"___cxa_begin_catch", xl_sh_cxa_begin_catch},
	{"___cxa_end_catch", xl_sh_cxa_end_catch}, {"___cxa_get_exception_ptr", xl_sh_cxa_get_exception_ptr},
	{"___cxa_rethrow", xl_sh_cxa_rethrow}, {"___cxa_call_unexpected", xl_sh_cxa_call_unexpected},
	{"__Unwind_Resume_or_Rethrow", xl_sh_unwind_resume}, {"__Unwind_Resume", xl_sh_unwind_resume},
	{"___cxa_current_exception_type", xl_sh_cxa_current_exception_type},
	{"__ZSt18uncaught_exceptionv", xl_sh_uncaught_exception},
	{"__ZSt9terminatev", sh_terminate}, {"__ZSt17__throw_bad_allocv", sh_fatal},
	{"__ZSt20__throw_length_errorPKc", sh_fatal}, {"___cxa_pure_virtual", sh_fatal},
	{"__ZNSt9exceptionD2Ev", sh_nop}, {"__ZNSt9exceptionD1Ev", sh_nop}, {"__ZNSt9exceptionD0Ev", sh_nop},
	{"__ZNSt9bad_allocD1Ev", sh_nop}, {"__ZNSt9bad_allocD0Ev", sh_nop}, {"__ZNKSt9exception4whatEv", sh_exception_what},
	{"__ZNKSt9bad_alloc4whatEv", sh_exception_what}, {"__ZNSaIcEC1Ev", sh_nop}, {"__ZNSaIcED1Ev", sh_nop},
	{"__ZNSsC1EPKcmRKSaIcE", sh_string_ctor}, {"__ZNSsD1Ev", sh_string_dtor}, {"__ZNKSs5c_strEv", sh_string_c_str},
	{"__ZSt18_Rb_tree_incrementPKSt18_Rb_tree_node_base", sh_rb_increment},
	{"__ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base", sh_rb_increment},
	{"__ZSt18_Rb_tree_decrementPKSt18_Rb_tree_node_base", sh_rb_decrement},
	{"__ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base", sh_rb_decrement},
	{"__ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_", sh_rb_insert},
	{"__ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_", sh_rb_erase},
	{"___divdi3", sh_divdi3}, {"___moddi3", sh_moddi3}, {"___udivdi3", sh_udivdi3}, {"___umoddi3", sh_umoddi3},
	{"___fixunsdfdi", sh_fixunsdfdi},
	{"___keymgr_dwarf2_register_sections", sh_nop}, {"__keymgr_get_and_lock_processwide_ptr", sh_zero},
	{"__keymgr_get_and_lock_processwide_ptr_2", sh_keymgr_get2}, {"__keymgr_set_and_unlock_processwide_ptr", sh_zero},
	{"_objc_msgSend", sh_msgSend}, {"_objc_msgSend_stret", sh_msgSend_stret}, {"_objc_msgSend_fpret", sh_msgSend_fpret},
	{"_objc_msgSendSuper", sh_msgSendSuper}, {"_objc_msgSendSuper_stret", sh_msgSendSuper_stret},
	{"_objc_exception_try_enter", xl_sh_objc_exception_try_enter},
	{"_objc_exception_try_exit", xl_sh_objc_exception_try_exit},
	{"_objc_exception_extract", xl_sh_objc_exception_extract},
	{"_objc_exception_match", xl_sh_objc_exception_match},
	{"_objc_exception_throw", xl_sh_objc_exception_throw},
	{"_longjmp", sh_longjmp}, {"__longjmp", sh_longjmp}, {"_siglongjmp", sh_longjmp},
	{"_exit", sh_exit}, {"_abort", sh_abort}, {"_getenv", sh_getenv}, {"___error", sh_error},
	{"_dlopen", sh_dlopen}, {"_dlsym", sh_dlsym}, {"_dlerror", sh_dlerror}, {"_dlclose", sh_zero},
	{"_CFBundleGetFunctionPointerForName", sh_CFBundleGetFunctionPointerForName},
	{"_CFDataGetBytePtr", sh_CFDataGetBytePtr},
	{"_CFAllocatorCreate", sh_CFAllocatorCreate}, {"_CFAllocatorAllocate", sh_CFAllocatorAllocate},
	{"_CFAllocatorReallocate", sh_CFAllocatorReallocate}, {"_CFAllocatorDeallocate", sh_CFAllocatorDeallocate}, {"_CFStringGetCharactersPtr", sh_CFStringGetCharactersPtr},
	{"_glGetString", sh_glGetString}, {"_FSFindFolder", sh_FSFindFolder},
	{"_AHRegisterHelpBook", sh_AHRegisterHelpBook}, {"_AHRegisterHelpBookWithURL", sh_AHRegisterHelpBookWithURL},
	{"_AHGotoPage", sh_AHGotoPage}, {"_AHLookupAnchor", sh_AHLookupAnchor}, {"_AHGotoMainTOC", sh_AHGotoMainTOC},
	{"_CGDisplayCapture", sh_ok}, {"_CGDisplayRelease", sh_ok}, {"_CGCaptureAllDisplays", sh_ok},
	{"_CGReleaseAllDisplays", sh_ok}, {"_CGDisplaySwitchToMode", sh_ok}, {"_CGSetDisplayTransferByFormula", sh_ok},
	{"_CGSetDisplayTransferByTable", sh_ok}, {"_CGDisplayRestoreColorSyncSettings", sh_ok}, {"_SetSystemUIMode", sh_ok},
	{"_CGDisplayHideCursor", sh_ok}, {"_CGDisplayShowCursor", sh_ok}, {"_CGDisplayIsCaptured", sh_ok}, {"_localtime", sh_localtime},
	{"_stat", sh_stat}, {"_lstat", sh_lstat}, {"_fstat", sh_fstat}, {"_statfs", sh_statfs},
	{"_pthread_mutexattr_init", sh_mutexattr_init}, {"_pthread_mutexattr_settype", sh_mutexattr_settype},
	{"_pthread_mutexattr_destroy", sh_nop}, {"_pthread_mutex_init", sh_mutex_init},
	{"_pthread_mutex_lock", sh_mutex_lock}, {"_pthread_mutex_trylock", sh_mutex_trylock},
	{"_pthread_mutex_unlock", sh_mutex_unlock}, {"_pthread_mutex_destroy", sh_mutex_destroy},
	{"_pthread_cond_init", sh_cond_init}, {"_pthread_cond_destroy", sh_cond_destroy},
	{"_pthread_cond_signal", sh_cond_signal}, {"_pthread_cond_broadcast", sh_cond_broadcast},
	{"_pthread_cond_wait", sh_cond_wait}, {"_pthread_cond_timedwait_relative_np", sh_cond_timedwait_relative_np},
	{"_pthread_attr_init", sh_attr_init}, {"_pthread_attr_destroy", sh_nop},
	{"_pthread_attr_setdetachstate", sh_attr_setdetachstate}, {"_pthread_create", sh_pthread_create},
	{"_pthread_key_create", sh_pthread_key_create},
	{0}
};

XLShim xl_find_shim(const char *name)
{
	for (const ShimEnt *e = shims; e->name; e++)
		if (!strcmp(e->name, name))
			return e->fn;
	extern XLShim xl_find_iostream_shim(const char *name);
	extern XLShim xl_find_qt_shim(const char *name);
	XLShim f = xl_find_iostream_shim(name);
	if (!f)
		f = xl_find_qt_shim(name);
	if (f)
		return f;
	extern XLShim xl_find_media_shim(const char *name);
	return xl_find_media_shim(name);
}
