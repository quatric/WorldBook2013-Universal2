// Imported data symbols: guest copies of host variables and constants.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "rt.h"
#include <dlfcn.h>
#include <runetype.h>

#define XL_DATA_LO 0x17000000u
#define XL_DATA_HI 0x18000000u
static uint32_t data_top = XL_DATA_LO;
static XLMap by_name;
uint32_t xl_nsapp_cell;

static uint32_t dalloc(uint32_t n)
{
	data_top = (data_top + 15) & ~15u;
	uint32_t p = data_top;
	data_top += n ? n : 4;
	if (data_top > XL_DATA_HI)
		xl_die("data symbol area full");
	return p;
}

static uint64_t hname(const char *s)
{
	uint64_t h = 1469598103934665603ULL;
	while (*s)
		h = (h ^ (uint8_t)*s++) * 1099511628211ULL;
	return h | 1;
}

static uint32_t make(const char *name)
{
	const char *n = name + 1;
	void *sym = dlsym(RTLD_DEFAULT, n);
	uint32_t g;
	if (!strcmp(name, "___sF")) {
		g = dalloc(3 * 88);
		xl_bind_handle(g, stdin);
		xl_bind_handle(g + 88, stdout);
		xl_bind_handle(g + 176, stderr);
		return g;
	}
	if (!strcmp(name, "__DefaultRuneLocale")) {
		// i386 _RuneLocale: magic[8] encoding[32] sgetrune sputrune invalid_rune runetype[256] maplower[256] mapupper[256]
		g = dalloc(52 + 3 * 1024 + 64);
		uint8_t *p = GP(g);
		memcpy(p, _DefaultRuneLocale.__magic, 8);
		memcpy(p + 8, _DefaultRuneLocale.__encoding, 32);
		memcpy(p + 52, _DefaultRuneLocale.__runetype, 1024);
		for (int i = 0; i < 256; i++) {
			((int32_t *)(p + 52 + 1024))[i] = _DefaultRuneLocale.__maplower[i];
			((int32_t *)(p + 52 + 2048))[i] = _DefaultRuneLocale.__mapupper[i];
		}
		return g;
	}
	if (!strcmp(name, "_NSApp")) {
		g = dalloc(4);
		xl_nsapp_cell = g;
		return g;
	}
	if (!strncmp(name, "_NSZero", 7)) {
		g = dalloc(16);
		return g;
	}
	if (!strcmp(name, "_NSAppKitVersionNumber") || !strcmp(name, "_NSFoundationVersionNumber") ||
		!strcmp(name, "_kCFAbsoluteTimeIntervalSince1970")) {
		g = dalloc(8);
		if (sym)
			memcpy(GP(g), sym, 8);
		return g;
	}
	if (!strncmp(name, "__ZT", 4) || !strcmp(name, "__ZSt7nothrow") || !strcmp(name, "___CFConstantStringClassReference") ||
		!strcmp(name, "_errno") || strstr(name, "init_routine")) {
		g = dalloc(64);
		if (!strncmp(name, "__ZTI", 5)) {
			// typeinfo: {vtable, name}
			*(uint32_t *)GP(g + 4) = xl_strdup(name + 5);
		}
		return g;
	}
	if (strstr(name, "CallBacks")) {
		// NSMapTable/NSHashTable callbacks: the guest passes copies of these by
		// value, so they carry what they mean for maptable.m to read back
		g = dalloc(64);
		if (sym)
			xl_bind_handle(g, sym);
		uint32_t flags = 0;
		if (strstr(name, "Object"))
			flags |= XL_CB_OBJECT;
		if (strstr(name, "Object") && !strstr(name, "NonRetained"))
			flags |= XL_CB_RETAIN;
		if (strstr(name, "Owned") && !strstr(name, "NonOwned"))
			flags |= XL_CB_FREE;
		*(uint32_t *)GP(g) = XL_CB_MAGIC;
		*(uint32_t *)GP(g + 4) = flags;
		return g;
	}
	if (!sym) {
		xl_log("missing data symbol %s", name);
		return dalloc(16);
	}
	if (strncmp(name, "_NS", 3) && strncmp(name, "_kCF", 4) && strncmp(name, "_kSC", 4) && strncmp(name, "_kCG", 4) &&
		strncmp(name, "_Web", 4)) {
		// plain data: copy what is there (sizes are unknown; 16 bytes covers scalars)
		xl_log("data symbol %s copied by value", name);
		g = dalloc(16);
		memcpy(GP(g), sym, 16);
		return g;
	}
	// a constant object (NSString keys, CF constants)
	g = dalloc(4);
	*(uint32_t *)GP(g) = xl_hobj(*(id *)sym);
	xl_bind_handle(g, sym);
	return g;
}

uint32_t xl_data_symbol(const char *name)
{
	uint64_t k = hname(name);
	uint32_t g = (uint32_t)xl_map_get(&by_name, k);
	if (g)
		return g;
	g = make(name);
	xl_map_put(&by_name, k, g);
	return g;
}

void xl_refresh_nsapp(void)
{
	if (xl_nsapp_cell)
		*(uint32_t *)GP(xl_nsapp_cell) = xl_hobj(NSApp);
}
