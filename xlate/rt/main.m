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
	XLImage *exe = xl_image_named("wb");
	uint32_t m = find_func(exe, "_main");
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
