// The 4 GB guest window, the guest heap and handles for host pointers.
#import <Foundation/Foundation.h>
#include "rt.h"
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdarg.h>

uint8_t *XG;
int xl_verbose = -1;
int xl_trace_on;

void xl_trace_fn(XLCPU *c, uint32_t addr)
{
	uint32_t sp = c->r[ESP];
	uint32_t *a = (uint32_t *)GP(sp);
	xl_log("fn %s(%08x, %08x, %08x) ret %08x", xl_name_at(addr), a[1], a[2], a[3], a[0]);
}

void xl_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[xl] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

void xl_die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[xl] fatal: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	abort();
}

// ---- hash map -------------------------------------------------------------------
static inline size_t hmix(uint64_t k)
{
	k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53ULL; k ^= k >> 33;
	return (size_t)k;
}

static void map_grow(XLMap *m)
{
	size_t oc = m->cap, nc = oc ? oc * 2 : 1024;
	uint64_t *ok = m->keys, *ov = m->vals;
	m->keys = calloc(nc, 8);
	m->vals = calloc(nc, 8);
	m->cap = nc;
	m->n = 0;
	for (size_t i = 0; i < oc; i++)
		if (ok[i] && ok[i] != ~0ULL) {
			size_t j = hmix(ok[i]) & (nc - 1);
			while (m->keys[j])
				j = (j + 1) & (nc - 1);
			m->keys[j] = ok[i];
			m->vals[j] = ov[i];
			m->n++;
		}
	free(ok);
	free(ov);
}

// key 0 is reserved (empty), ~0 marks a deleted slot
uint64_t xl_map_get(XLMap *m, uint64_t k)
{
	uint64_t v = 0;
	os_unfair_lock_lock(&m->lock);
	if (m->cap) {
		size_t j = hmix(k) & (m->cap - 1);
		while (m->keys[j]) {
			if (m->keys[j] == k) {
				v = m->vals[j];
				break;
			}
			j = (j + 1) & (m->cap - 1);
		}
	}
	os_unfair_lock_unlock(&m->lock);
	return v;
}

void xl_map_put(XLMap *m, uint64_t k, uint64_t v)
{
	os_unfair_lock_lock(&m->lock);
	if ((m->n + 1) * 2 > m->cap)
		map_grow(m);
	size_t j = hmix(k) & (m->cap - 1), tomb = (size_t)-1;
	while (m->keys[j]) {
		if (m->keys[j] == k) {
			m->vals[j] = v;
			os_unfair_lock_unlock(&m->lock);
			return;
		}
		if (m->keys[j] == ~0ULL && tomb == (size_t)-1)
			tomb = j;
		j = (j + 1) & (m->cap - 1);
	}
	if (tomb != (size_t)-1)
		j = tomb;
	else
		m->n++;
	m->keys[j] = k;
	m->vals[j] = v;
	os_unfair_lock_unlock(&m->lock);
}

void xl_map_del(XLMap *m, uint64_t k)
{
	os_unfair_lock_lock(&m->lock);
	if (m->cap) {
		size_t j = hmix(k) & (m->cap - 1);
		while (m->keys[j]) {
			if (m->keys[j] == k) {
				m->keys[j] = ~0ULL;
				m->vals[j] = 0;
				break;
			}
			j = (j + 1) & (m->cap - 1);
		}
	}
	os_unfair_lock_unlock(&m->lock);
}

// ---- window ---------------------------------------------------------------------------
void xl_window_init(void)
{
	if (XG)
		return;
	// 4 GB plus a guard so that G + p + small offsets never leave the reservation
	size_t len = 0x100000000ull + 0x10000;
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
	if (p == MAP_FAILED)
		xl_die("cannot reserve the guest window");
	XG = p;
	// no null-page guard: host pages are 16 KB and the executable starts at 0x1000
	xl_trace_on = getenv("XL_TRACE") != NULL;
	const char *v = getenv("XL_VERBOSE");
	if (v)
		xl_verbose = atoi(v);
}

// ---- heap -----------------------------------------------------------------------------
// Blocks have a 16-byte header: size (usable bytes), class index (or 0xffff for large).
// Small classes keep free lists threaded through the first word.
#define NCLASS 64
static uint32_t class_size[NCLASS];
static int nclass;
static uint32_t freelist[NCLASS];
static uint32_t heap_top = XL_HEAP_LO;
static os_unfair_lock heap_lock = OS_UNFAIR_LOCK_INIT;
typedef struct Span { uint32_t addr, size; struct Span *next; } Span;
static Span *large_free;

static void heap_classes(void)
{
	uint32_t s = 16;
	while (s <= 256) {
		class_size[nclass++] = s;
		s += 16;
	}
	for (uint32_t base = 256; base < 32768; base *= 2)
		for (int k = 1; k <= 4; k++)
			class_size[nclass++] = base + base / 4 * k;
}

static int class_of(uint32_t n)
{
	if (!nclass)
		heap_classes();
	int lo = 0, hi = nclass - 1;
	if (n > class_size[hi])
		return -1;
	while (lo < hi) {
		int mid = (lo + hi) / 2;
		if (class_size[mid] >= n)
			hi = mid;
		else
			lo = mid + 1;
	}
	return lo;
}

static uint32_t bump(uint32_t n)
{
	uint32_t p = heap_top;
	if ((uint64_t)p + n > XL_HEAP_HI)
		xl_die("guest heap exhausted");
	heap_top += n;
	return p;
}

#define HDR_SIZE(b) (*(uint32_t *)GP((b) - 16))
#define HDR_CLASS(b) (*(uint32_t *)GP((b) - 12))

uint32_t xl_malloc(uint32_t n)
{
	if (!n)
		n = 1;
	os_unfair_lock_lock(&heap_lock);
	int k = class_of(n);
	uint32_t b;
	if (k >= 0) {
		b = freelist[k];
		if (b) {
			freelist[k] = *(uint32_t *)GP(b);
			HDR_CLASS(b) = (uint32_t)k;
		} else {
			uint32_t bs = class_size[k] + 16;
			uint32_t cnt = bs < 4096 ? 65536 / bs : 4;
			uint32_t run = bump(bs * cnt);
			for (uint32_t i = 1; i < cnt; i++) {
				uint32_t o = run + i * bs + 16;
				*(uint32_t *)GP(o - 16) = class_size[k];
				*(uint32_t *)GP(o - 12) = (uint32_t)k | 0x10000;
				*(uint32_t *)GP(o) = freelist[k];
				freelist[k] = o;
			}
			b = run + 16;
			*(uint32_t *)GP(b - 16) = class_size[k];
			*(uint32_t *)GP(b - 12) = (uint32_t)k;
		}
	} else {
		uint32_t need = (n + 16 + 4095) & ~4095u;
		Span **pp = &large_free, *s;
		b = 0;
		while ((s = *pp)) {
			if (s->size >= need) {
				b = s->addr + 16;
				if (s->size - need >= 65536) {
					s->addr += need;
					s->size -= need;
				} else {
					need = s->size;
					*pp = s->next;
					free(s);
				}
				break;
			}
			pp = &s->next;
		}
		if (!b)
			b = bump(need) + 16;
		*(uint32_t *)GP(b - 16) = need - 16;
		*(uint32_t *)GP(b - 12) = 0xffff;
	}
	os_unfair_lock_unlock(&heap_lock);
	return b;
}

uint32_t xl_calloc(uint32_t n)
{
	uint32_t b = xl_malloc(n);
	memset(GP(b), 0, n);
	return b;
}

uint32_t xl_msize(uint32_t p)
{
	return p ? HDR_SIZE(p) : 0;
}

void xl_free(uint32_t p)
{
	if (!p)
		return;
	if (p < XL_HEAP_LO || p >= XL_HEAP_HI) {
		if (xl_verbose > 0)
			xl_log("free of non-heap pointer %08x", p);
		return;
	}
	os_unfair_lock_lock(&heap_lock);
	uint32_t k = HDR_CLASS(p);
	if (k < (uint32_t)nclass) {
		*(uint32_t *)GP(p) = freelist[k];
		freelist[k] = p;
		HDR_CLASS(p) = k | 0x10000;
	} else if (k & 0x10000) {
		os_unfair_lock_unlock(&heap_lock);
		XLCPU *c = xl_cpu();
		xl_log("double free of %08x (from %s)", p, xl_name_at(*(uint32_t *)GP(c->r[ESP])));
		return;
	} else if (k == 0xffff) {
		Span *s = malloc(sizeof *s);
		s->addr = p - 16;
		s->size = HDR_SIZE(p) + 16;
		// keep the list sorted and merge neighbours
		Span **pp = &large_free;
		while (*pp && (*pp)->addr < s->addr)
			pp = &(*pp)->next;
		s->next = *pp;
		*pp = s;
		if (s->next && s->addr + s->size == s->next->addr) {
			Span *n = s->next;
			s->size += n->size;
			s->next = n->next;
			free(n);
		}
		Span *prev = NULL;
		for (Span *q = large_free; q && q != s; q = q->next)
			prev = q;
		if (prev && prev->addr + prev->size == s->addr) {
			prev->size += s->size;
			prev->next = s->next;
			free(s);
		}
		HDR_CLASS(p) = 0xfffe;
	} else {
		if (xl_verbose > 0)
			xl_log("double or bad free %08x", p);
	}
	os_unfair_lock_unlock(&heap_lock);
}

uint32_t xl_realloc(uint32_t p, uint32_t n)
{
	if (!p)
		return xl_malloc(n);
	uint32_t old = HDR_SIZE(p);
	if (n <= old && n >= old / 2)
		return p;
	uint32_t q = xl_malloc(n);
	memcpy(GP(q), GP(p), old < n ? old : n);
	xl_free(p);
	return q;
}

uint32_t xl_strdup(const char *s)
{
	if (!s)
		return 0;
	if (xl_in_window(s))
		return GA(s);
	size_t n = strlen(s) + 1;
	uint32_t g = xl_malloc((uint32_t)n);
	memcpy(GP(g), s, n);
	return g;
}

// ---- remapped host buffers -----------------------------------------------------------
static uint32_t remap_top = XL_REMAP_LO;
static Span *remap_free;
static os_unfair_lock remap_lock = OS_UNFAIR_LOCK_INIT;

uint32_t xl_remap(const void *p, size_t n)
{
	if (!p)
		return 0;
	if (xl_in_window(p))
		return GA(p);
	mach_vm_address_t src = (mach_vm_address_t)p & ~(mach_vm_address_t)(vm_page_size - 1);
	size_t off = (size_t)((mach_vm_address_t)p - src);
	size_t len = (off + n + vm_page_size - 1) & ~(vm_page_size - 1);
	if (!len)
		len = vm_page_size;
	os_unfair_lock_lock(&remap_lock);
	uint32_t g = 0;
	// first fit in the address-ordered free list, splitting a larger span
	for (Span **pp = &remap_free, *s; (s = *pp); pp = &s->next)
		if (s->size >= len) {
			g = s->addr;
			if (s->size == len) {
				*pp = s->next;
				free(s);
			} else {
				s->addr += (uint32_t)len;
				s->size -= (uint32_t)len;
			}
			break;
		}
	if (!g) {
		if (remap_top + len > XL_REMAP_HI) {
			os_unfair_lock_unlock(&remap_lock);
			return 0;
		}
		g = remap_top;
		remap_top += (uint32_t)len;
	}
	os_unfair_lock_unlock(&remap_lock);
	mach_vm_address_t dst = (mach_vm_address_t)(XG + g);
	vm_prot_t cur, max;
	kern_return_t kr = mach_vm_remap(mach_task_self(), &dst, len, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
		mach_task_self(), src, FALSE, &cur, &max, VM_INHERIT_NONE);
	if (kr != KERN_SUCCESS) {
		xl_log("mach_vm_remap failed %d", kr);
		return 0;
	}
	return g + (uint32_t)off;
}

void xl_unmap(uint32_t g, size_t n)
{
	uint32_t base = g & ~(uint32_t)(vm_page_size - 1);
	size_t len = ((g - base) + n + vm_page_size - 1) & ~(vm_page_size - 1);
	if (!len)
		len = vm_page_size;
	mmap(XG + base, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED | MAP_NORESERVE, -1, 0);
	// back into the address-ordered free list, merged with its neighbours;
	// a span ending at the top lowers the top instead
	os_unfair_lock_lock(&remap_lock);
	Span **pp = &remap_free, *prev = NULL;
	while (*pp && (*pp)->addr < base) {
		prev = *pp;
		pp = &(*pp)->next;
	}
	Span *next = *pp;
	if (prev && prev->addr + prev->size == base) {
		prev->size += (uint32_t)len;
		if (next && prev->addr + prev->size == next->addr) {
			prev->size += next->size;
			prev->next = next->next;
			free(next);
		}
	} else if (next && base + len == next->addr) {
		next->addr = base;
		next->size += (uint32_t)len;
	} else {
		Span *s = malloc(sizeof *s);
		s->addr = base;
		s->size = (uint32_t)len;
		s->next = next;
		*pp = s;
	}
	// the last span touching the top is given back to the bump area
	Span **lp = &remap_free;
	while (*lp && (*lp)->next)
		lp = &(*lp)->next;
	if (*lp && (*lp)->addr + (*lp)->size == remap_top) {
		remap_top = (*lp)->addr;
		free(*lp);
		*lp = NULL;
	}
	os_unfair_lock_unlock(&remap_lock);
}

// ---- handles ---------------------------------------------------------------------------
static XLMap h2p;   // static handles -> host
static XLMap p2h;   // host -> handle (cells and static handles)

void xl_bind_handle(uint32_t h, const void *p)
{
	xl_map_put(&h2p, h, (uint64_t)p);
	if (!xl_map_get(&p2h, (uint64_t)p))
		xl_map_put(&p2h, (uint64_t)p, h);
}

uint32_t xl_cell(const void *p, uint32_t size)
{
	uint32_t b = xl_calloc(8 + (size < 8 ? 8 : size));
	*(const void **)GP(b) = p;
	return b + 8;
}

uint32_t xl_h(const void *p)
{
	if (!p)
		return 0;
	uint32_t h = (uint32_t)xl_map_get(&p2h, (uint64_t)p);
	if (h)
		return h;
	h = xl_cell(p, 8);
	xl_map_put(&p2h, (uint64_t)p, h);
	return h;
}

void *xl_p_quiet(uint32_t h)
{
	if (!h)
		return NULL;
	if (h >= XL_HEAP_LO && h < XL_HEAP_HI)
		return *(void **)GP(h - 8);
	return (void *)xl_map_get(&h2p, h);
}

void *xl_p(uint32_t h)
{
	if (!h)
		return NULL;
	if (h >= XL_HEAP_LO && h < XL_HEAP_HI)
		return *(void **)GP(h - 8);
	void *p = (void *)xl_map_get(&h2p, h);
	if (!p && xl_verbose >= 0)
		xl_log("unknown handle %08x (%s)", h, xl_name_at(h));
	return p;
}
