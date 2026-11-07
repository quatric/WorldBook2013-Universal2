// Entry: load the translated images, register their classes, run the guest main.
#import <AppKit/AppKit.h>
#include "rt.h"

void xl_refresh_nsapp(void);

static uint32_t find_func(XLImage *im, const char *name)
{
	for (size_t i = 0; i < im->nfuncs; i++)
		if (!strcmp(im->funcs[i].name, name))
			return im->funcs[i].addr + *im->slide;
	return 0;
}

// A stripped executable (What's New?) has no _main symbol. Its crt1 start
// routine at the entry point ends with "call main; movl %eax,(%esp); call exit".
static uint32_t main_from_start(XLImage *im)
{
	if (!im->entry)
		return 0;
	uint32_t a = im->entry + *im->slide;
	const uint8_t *p = GP(a);
	for (uint32_t i = 0; i + 13 <= 0x200; i++) {
		if (p[i] != 0xe8 || p[i + 5] != 0x89 || p[i + 6] != 0x04 || p[i + 7] != 0x24 || p[i + 8] != 0xe8)
			continue;
		int32_t rel;
		memcpy(&rel, p + i + 1, 4);
		uint32_t t = a + i + 5 + (uint32_t)rel;
		for (size_t k = 0; k < im->nfuncs; k++)
			if (im->funcs[k].addr + *im->slide == t)
				return t;
	}
	return 0;
}

static uint32_t guest_strv(int n, char **v)
{
	uint32_t a = xl_calloc(4 * (n + 1));
	for (int i = 0; i < n; i++)
		*(uint32_t *)GP(a + 4 * i) = xl_strdup(v[i]);
	return a;
}

int main(int argc, char **argv, char **envp)
{
	@autoreleasepool {
		xl_load_images();
		xl_cpu();
		xl_objc_init();
		xl_run_initializers();
		NSString *pc = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSPrincipalClass"];
		Class app = pc ? NSClassFromString(pc) : [NSApplication class];
		[app sharedApplication];
		xl_refresh_nsapp();
	}
	// the executable is the image without an install name
	XLImage *exe = NULL;
	for (XLImage *im = xl_images; im; im = im->next)
		if (!im->install[0])
			exe = im;
	uint32_t m = exe ? find_func(exe, "_main") : 0;
	if (!m && exe)
		m = main_from_start(exe);
	if (!m)
		xl_die("no _main in the executable");
	int envc = 0;
	while (envp[envc])
		envc++;
	char *apple[] = {argv[0], NULL};
	uint32_t args[4] = {(uint32_t)argc, guest_strv(argc, argv), guest_strv(envc, envp), guest_strv(1, apple)};
	uint32_t r = xl_guest_call(m, 4, args);
	exit((int)r);
}
