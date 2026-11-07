// Entry: an AppKit application whose main thread runs the translated program.
#import <AppKit/AppKit.h>
#include "ppcrt.h"

// the wizards find their data (".World Book.wz") next to themselves: in the
// bundle's Resources folder, beside the resource fork

void ppc_start(const char *rsrc_path);

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
		[NSApp finishLaunching];
		NSString *r = getenv("PPC_RSRC") ? @(getenv("PPC_RSRC"))
			: [[NSBundle mainBundle] pathForResource:@"Application" ofType:@"rsrc"];
		if (!r) {
			fprintf(stderr, "no Application.rsrc in the bundle\n");
			return 1;
		}
		snprintf(ppc_app_dir, sizeof ppc_app_dir, "%s", r.stringByDeletingLastPathComponent.fileSystemRepresentation);
		ppc_start(r.fileSystemRepresentation);
	}
	return 0;
}
