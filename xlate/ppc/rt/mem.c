// The guest heap and the Memory Manager: pointers and relocatable handles.
//
// Blocks carry an 8-byte header (requested size, capacity) and come from size
// classes with free lists; the heap grows upwards from HEAP_BASE. A handle is
// the address of a master pointer in the master pointer area (MP_BASE ..), whose
// value is the block (0 for an empty handle). Handle states (locked, purgeable,
// resource) are kept host-side, one byte per master pointer.
#include "ppcrt.h"

enum { MP_BASE = 0x03000000, MP_TOP = 0x04000000 };
enum { NSMALL = 128, NLARGE = 32 };

static uint32_t heap_top = HEAP_BASE;
static uint32_t free_small[NSMALL + 1];    // capacity 16 * i
static uint32_t free_large[NLARGE];        // capacity 1 << i
static uint32_t mp_next = MP_BASE, mp_free;
static uint8_t *hstate;
int16_t mem_err;

static uint32_t cls_cap(uint32_t n, int *small, int *idx)
{
	if (n <= 16 * NSMALL) {
		uint32_t i = (n + 15) / 16;
		if (!i)
			i = 1;
		*small = 1;
		*idx = (int)i;
		return 16 * i;
	}
	int i = 32 - __builtin_clz(n - 1);
	*small = 0;
	*idx = i;
	return 1u << i;
}

uint32_t gmalloc(uint32_t n)
{
	int small, idx;
	uint32_t cap = cls_cap(n, &small, &idx);
	uint32_t *list = small ? &free_small[idx] : &free_large[idx];
	uint32_t p;
	if (*list) {
		p = *list;
		*list = LD32(p);
	} else {
		if (heap_top + 8 + cap > HEAP_TOP) {
			ppc_log("guest heap exhausted (%u bytes wanted)", n);
			return 0;
		}
		p = heap_top + 8;
		heap_top += 8 + cap;
		if (cap >= 4096)   // keep large blocks 16-aligned
			heap_top = (heap_top + 15) & ~15u;
	}
	ST32(p - 8, n);
	ST32(p - 4, cap);
	return p;
}

uint32_t gcalloc(uint32_t n)
{
	uint32_t p = gmalloc(n);
	if (p)
		memset(G(p), 0, n);
	return p;
}

void gfree(uint32_t p)
{
	if (!p)
		return;
	uint32_t cap = LD32(p - 4);
	int small, idx;
	cls_cap(cap, &small, &idx);
	if (cls_cap(cap, &small, &idx) != cap) {
		ppc_log("gfree: %08x is not a heap block (capacity %u)", p, cap);
		return;
	}
	uint32_t *list = small ? &free_small[idx] : &free_large[idx];
	ST32(p - 8, 0xdeadbeef);
	ST32(p, *list);
	*list = p;
}

uint32_t gsize(uint32_t p) { return p ? LD32(p - 8) : 0; }

uint32_t grealloc(uint32_t p, uint32_t n)
{
	if (!p)
		return gmalloc(n);
	uint32_t cap = LD32(p - 4);
	if (n <= cap) {
		ST32(p - 8, n);
		return p;
	}
	uint32_t q = gmalloc(n + n / 4);
	if (!q)
		return 0;
	ST32(q - 8, n);
	memcpy(G(q), G(p), LD32(p - 8));
	gfree(p);
	return q;
}

uint32_t gstrdup(const char *s)
{
	uint32_t p = gmalloc((uint32_t)strlen(s) + 1);
	strcpy(G(p), s);
	return p;
}

// ---- handles ----------------------------------------------------------------

int is_handle(uint32_t h) { return h >= MP_BASE && h < mp_next && !(h & 3) && hstate[(h - MP_BASE) / 4] & 1; }

static uint32_t new_mp(void)
{
	uint32_t h;
	if (mp_free) {
		h = mp_free;
		mp_free = LD32(h);
	} else {
		h = mp_next;
		mp_next += 4;
	}
	hstate[(h - MP_BASE) / 4] = 1;
	ST32(h, 0);
	return h;
}

uint32_t NewHandleG(uint32_t n)
{
	uint32_t h = new_mp();
	uint32_t p = gmalloc(n ? n : 1);
	ST32(p - 8, n);
	ST32(h, p);
	return h;
}

uint32_t NewHandleClearG(uint32_t n)
{
	uint32_t h = NewHandleG(n);
	memset(G(HP(h)), 0, n);
	return h;
}

uint32_t NewHandleFrom(const void *src, uint32_t n)
{
	uint32_t h = NewHandleG(n);
	memcpy(G(HP(h)), src, n);
	return h;
}

void DisposeHandleG(uint32_t h)
{
	if (!is_handle(h))
		return;
	gfree(LD32(h));
	hstate[(h - MP_BASE) / 4] = 0;
	ST32(h, mp_free);
	mp_free = h;
}

uint32_t HSize(uint32_t h)
{
	if (!is_handle(h))
		return 0;
	uint32_t p = LD32(h);
	return p ? LD32(p - 8) : 0;
}

int HSetSize(uint32_t h, uint32_t n)
{
	if (!is_handle(h))
		return -109;   // nilHandleErr
	uint32_t p = LD32(h);
	if (!p) {
		p = gmalloc(n ? n : 1);
		ST32(p - 8, n);
		ST32(h, p);
		return 0;
	}
	uint32_t q = grealloc(p, n);
	if (!q)
		return -108;
	ST32(h, q);
	return 0;
}

static uint8_t *hst(uint32_t h) { return &hstate[(h - MP_BASE) / 4]; }

void mem_init(void)
{
	hstate = calloc((MP_TOP - MP_BASE) / 4, 1);
}

// ---- Memory Manager shims ------------------------------------------------------

static void sh_NewPtr(PPC *c) { uint32_t p = gmalloc(A(0)); mem_err = p ? 0 : -108; RET(p); }
static void sh_NewPtrClear(PPC *c) { uint32_t p = gcalloc(A(0)); mem_err = p ? 0 : -108; RET(p); }
static void sh_DisposePtr(PPC *c) { gfree(A(0)); mem_err = 0; }
static void sh_NewHandle(PPC *c) { mem_err = 0; RET(NewHandleG(A(0))); }
static void sh_NewHandleClear(PPC *c) { mem_err = 0; RET(NewHandleClearG(A(0))); }
static void sh_TempNewHandle(PPC *c)
{
	uint32_t h = NewHandleG(A(0));
	if (A(1))
		ST16(A(1), 0);
	mem_err = 0;
	RET(h);
}
static void sh_DisposeHandle(PPC *c) { DisposeHandleG(A(0)); mem_err = 0; }
static void sh_GetHandleSize(PPC *c) { mem_err = is_handle(A(0)) ? 0 : -109; RET(HSize(A(0))); }
static void sh_SetHandleSize(PPC *c) { mem_err = (int16_t)HSetSize(A(0), A(1)); }
static void sh_HLock(PPC *c) { if (is_handle(A(0))) *hst(A(0)) |= 0x80; mem_err = 0; }
static void sh_HUnlock(PPC *c) { if (is_handle(A(0))) *hst(A(0)) &= ~0x80; mem_err = 0; }
static void sh_HNoPurge(PPC *c) { if (is_handle(A(0))) *hst(A(0)) &= ~0x40; mem_err = 0; }
static void sh_HGetState(PPC *c)
{
	// lock 0x80, purge 0x40, resource 0x20
	RET(is_handle(A(0)) ? (*hst(A(0)) & 0xe0) : 0);
	mem_err = 0;
}
static void sh_HSetState(PPC *c)
{
	if (is_handle(A(0)))
		*hst(A(0)) = (*hst(A(0)) & 0x1f) | (A(1) & 0xe0);
	mem_err = 0;
}
void mem_set_resource_flag(uint32_t h, int on)
{
	if (is_handle(h))
		*hst(h) = on ? (*hst(h) | 0x20) : (*hst(h) & ~0x20);
}
static void sh_EmptyHandle(PPC *c)
{
	uint32_t h = A(0);
	if (is_handle(h)) {
		gfree(LD32(h));
		ST32(h, 0);
	}
	mem_err = 0;
}
static void sh_ReallocateHandle(PPC *c)
{
	uint32_t h = A(0);
	if (is_handle(h)) {
		gfree(LD32(h));
		uint32_t p = gmalloc(A(1) ? A(1) : 1);
		ST32(p - 8, A(1));
		ST32(h, p);
	}
	mem_err = 0;
}
static void sh_MemError(PPC *c) { RET((uint32_t)(int32_t)mem_err); }
static void sh_MaxBlock(PPC *c) { RET(64u << 20); }
static void sh_MoreMasterPointers(PPC *c) { (void)c; }
static void sh_BlockMove(PPC *c) { memmove(G(A(1)), G(A(0)), A(2)); }
static void sh_HandToHand(PPC *c)
{
	uint32_t hp = A(0), h = LD32(hp);
	uint32_t n = HSize(h);
	uint32_t nh = NewHandleG(n);
	memcpy(G(HP(nh)), G(HP(h)), n);
	ST32(hp, nh);
	mem_err = 0;
	RET(0);
}
static void sh_HandAndHand(PPC *c)
{
	uint32_t a = A(0), b = A(1);
	uint32_t na = HSize(a), nb = HSize(b);
	HSetSize(b, na + nb);
	memcpy(G(HP(b) + nb), G(HP(a)), na);
	mem_err = 0;
	RET(0);
}
static void sh_PtrToHand(PPC *c)
{
	uint32_t h = NewHandleG(A(2));
	memcpy(G(HP(h)), G(A(0)), A(2));
	ST32(A(1), h);
	mem_err = 0;
	RET(0);
}
static void sh_PtrAndHand(PPC *c)
{
	uint32_t p = A(0), h = A(1), n = A(2);
	uint32_t o = HSize(h);
	HSetSize(h, o + n);
	memcpy(G(HP(h) + o), G(p), n);
	mem_err = 0;
	RET(0);
}
static void sh_SetGrowZone(PPC *c) { (void)c; }
static void sh_GZSaveHnd(PPC *c) { RET(0); }
static void sh_UPP(PPC *c) { (void)c; }   // NewXxxUPP(proc) = proc on PowerPC: r3 stays
static void sh_nop(PPC *c) { (void)c; }

static const ShimDef memshims[] = {
	S(NewPtr), S(NewPtrClear), S(DisposePtr), S(NewHandle), S(NewHandleClear), S(TempNewHandle), S(DisposeHandle),
	S(GetHandleSize), S(SetHandleSize), S(HLock), S(HUnlock), S(HNoPurge), S(HGetState), S(HSetState),
	S(EmptyHandle), S(ReallocateHandle), S(MemError), S(MaxBlock), S(MoreMasterPointers), S(BlockMove),
	{"BlockMoveData", sh_BlockMove}, {"HLockHi", sh_HLock}, S(HandToHand), S(HandAndHand), S(PtrToHand),
	S(PtrAndHand), S(SetGrowZone), S(GZSaveHnd),
	{"NewGrowZoneUPP", sh_UPP}, {"DisposeGrowZoneUPP", sh_nop},
};
REGISTER(memshims)
