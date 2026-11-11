// AppKit behaviour the 2013 code relies on that current AppKit dropped.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "rt.h"

// ---- drawing into windows that are not on screen ------------------------------------------
// The guest draws into an offscreen window ([view lockFocus] ... [view
// unlockFocus]) and then caches the result with NSCachedImageRep
// -initWithWindow:rect:. Current AppKit keeps nothing of such drawing, so
// views in windows that are not visible draw into a bitmap kept per window.
static char win_bitmap_key, snap_key;
static IMP orig_lockFocus, orig_lockFocusIfCanDraw, orig_unlockFocus, orig_cached_init, orig_cached_draw;
static NSMutableArray *focus_stack;   // views focused through the window bitmap

static NSBitmapImageRep *window_bitmap(NSWindow *w, BOOL create)
{
	NSBitmapImageRep *b = objc_getAssociatedObject(w, &win_bitmap_key);
	NSSize sz = [[w contentView] frame].size;
	if (create && (!b || b.pixelsWide != (NSInteger)sz.width || b.pixelsHigh != (NSInteger)sz.height)) {
		if (sz.width < 1 || sz.height < 1)
			return nil;
		b = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)sz.width
			pixelsHigh:(NSInteger)sz.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
			colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:32] autorelease];
		objc_setAssociatedObject(w, &win_bitmap_key, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return b;
}

static BOOL offscreen_focus(NSView *v)
{
	NSWindow *w = [v window];
	if (!w || [w isVisible] || getenv("XL_NOOFFSCREEN"))
		return NO;
	NSBitmapImageRep *b = window_bitmap(w, YES);
	if (!b)
		return NO;
	NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:b];
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:gc];
	NSRect f = [v convertRect:[v bounds] toView:nil];   // window base coordinates
	NSAffineTransform *t = [NSAffineTransform transform];
	[t translateXBy:f.origin.x yBy:f.origin.y];
	if ([v isFlipped]) {
		[t translateXBy:0 yBy:f.size.height];
		[t scaleXBy:1 yBy:-1];
	}
	[t translateXBy:-[v bounds].origin.x yBy:-[v bounds].origin.y];
	[t concat];
	NSRectClip([v bounds]);
	if (!focus_stack)
		focus_stack = [NSMutableArray new];
	[focus_stack addObject:v];
	return YES;
}

static void xl_lockFocus(NSView *self, SEL _cmd)
{
	if (!offscreen_focus(self))
		((void (*)(id, SEL))orig_lockFocus)(self, _cmd);
}

static BOOL xl_lockFocusIfCanDraw(NSView *self, SEL _cmd)
{
	if (offscreen_focus(self))
		return YES;
	return ((BOOL (*)(id, SEL))orig_lockFocusIfCanDraw)(self, _cmd);
}

static void xl_unlockFocus(NSView *self, SEL _cmd)
{
	if ([focus_stack lastObject] == self) {
		[[NSGraphicsContext currentContext] flushGraphics];
		[NSGraphicsContext restoreGraphicsState];
		[focus_stack removeLastObject];
		return;
	}
	((void (*)(id, SEL))orig_unlockFocus)(self, _cmd);
}

static NSBitmapImageRep *snapshot(NSWindow *w, NSRect r)
{
	NSBitmapImageRep *src = window_bitmap(w, NO);
	if (!src)
		return nil;
	NSBitmapImageRep *b = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)r.size.width
		pixelsHigh:(NSInteger)r.size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:32];
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:b]];
	[src drawInRect:NSMakeRect(0, 0, r.size.width, r.size.height) fromRect:r operation:NSCompositingOperationCopy
		fraction:1 respectFlipped:NO hints:nil];
	[NSGraphicsContext restoreGraphicsState];
	static int dumps;
	if (getenv("XL_DUMPREPS") && dumps < 40) {
		NSString *p = [NSString stringWithFormat:@"%s/rep%02d.png", getenv("XL_DUMPREPS"), dumps++];
		[[b representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:p atomically:NO];
	}
	return [b autorelease];
}

static id xl_cached_initWithWindow(id self, SEL _cmd, NSWindow *w, NSRect r)
{
	self = ((id (*)(id, SEL, NSWindow *, NSRect))orig_cached_init)(self, _cmd, w, r);
	if (self && w) {
		NSBitmapImageRep *b = snapshot(w, r);
		if (b)
			objc_setAssociatedObject(self, &snap_key, b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return self;
}

static BOOL xl_cached_draw(id self, SEL _cmd)
{
	NSBitmapImageRep *b = objc_getAssociatedObject(self, &snap_key);
	if (b)
		return [b drawInRect:NSMakeRect(0, 0, [(NSImageRep *)self size].width, [(NSImageRep *)self size].height)];
	return ((BOOL (*)(id, SEL))orig_cached_draw)(self, _cmd);
}

// ---- drawing to screen ----------------------------------------------------------------------
// A layer-backed NSOpenGLView draws with no current graphics context, which
// +currentContextDrawingToScreen reports as not drawing to the screen; the
// guest views then take their printing path. Printing always has a context.
static IMP orig_drawingToScreen;
static BOOL xl_drawingToScreen(id self, SEL _cmd)
{
	if (![NSGraphicsContext currentContext])
		return YES;
	return ((BOOL (*)(id, SEL))orig_drawingToScreen)(self, _cmd);
}

// ---- -[NSView isFlipped] -------------------------------------------------------------------
// SMKAppKit's NSView(EXThreadFlippedView) category replaces -[NSView isFlipped]
// with "is this the view pushed as flipped on this thread". Current AppKit's
// own implementation answers for its private views (the title bar's text among
// them), so the original stays the answer unless the guest pushed the view.
static IMP view_isFlipped_orig, view_isFlipped_guest;
static BOOL xl_view_isFlipped(NSView *self, SEL _cmd)
{
	if (((BOOL (*)(id, SEL))view_isFlipped_guest)(self, _cmd))
		return YES;
	return ((BOOL (*)(id, SEL))view_isFlipped_orig)(self, _cmd);
}

void xl_host_method_replaced(Class cls, SEL sel, IMP orig, IMP guest)
{
	if (cls == [NSView class] && sel == @selector(isFlipped)) {
		view_isFlipped_orig = orig;
		view_isFlipped_guest = guest;
		method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)xl_view_isFlipped);
	}
}

// ---- NSMovie -------------------------------------------------------------------------------
// NSMovie wrapped a QuickTime Movie; the class remains without its methods.
// Movies are not available yet: initialisers fail.
static id xl_movie_initWithURL(id self, SEL _cmd, NSURL *url, BOOL byRef)
{
	if (xl_verbose > 0)
		xl_log("NSMovie %s: movies not available", [[url absoluteString] UTF8String]);
	[self release];
	return nil;
}

// ---- delegate messages current AppKit sends without asking -------------------------------
// NSLayoutManager sends -layoutManagerDidInvalidateLayout: to a delegate that
// implements other layout delegate methods even when it does not respond to it
static void xl_noop_obj(id self, SEL _cmd, id arg) {}

static void add_noop(const char *cls, const char *sel)
{
	Class c = objc_getClass(cls);
	SEL s = sel_registerName(sel);
	if (c && !class_respondsToSelector(c, s))
		class_addMethod(c, s, (IMP)xl_noop_obj, "v@:@");
}

// Table column identifiers in the 2013 nibs are numbers; NSComboBoxCell now
// compares them with -isEqualToString: while decoding
static BOOL xl_number_isEqualToString(NSNumber *self, SEL _cmd, NSString *s)
{
	return [s isKindOfClass:[NSString class]] && [[self stringValue] isEqualToString:s];
}

// ---- text containers that keep state between line fragment requests ------------------------
// HSExtendedTextContainer takes each answer from its layout manager's run state, and every
// request advances that state. The typesetter of the time asked once per fragment; the current
// one asks again for the same fragment to check it and, getting the next fragment instead,
// starts over forever. A request repeating the previous one gets the previous answer.
static IMP tc_lfr_orig;
static struct {
	id tc;
	NSRect proposed, result, remaining;
	NSUInteger index;
	NSWritingDirection dir;
} tc_last;

static NSRect xl_tc_lineFragmentRect(NSTextContainer *self, SEL _cmd, NSRect proposed, NSUInteger index,
	NSWritingDirection dir, NSRect *remaining)
{
	if (tc_last.tc == self && tc_last.index == index && tc_last.dir == dir && NSEqualRects(tc_last.proposed, proposed)) {
		if (remaining)
			*remaining = tc_last.remaining;
		return tc_last.result;
	}
	NSRect rem = NSZeroRect;
	NSRect r = ((NSRect (*)(id, SEL, NSRect, NSUInteger, NSWritingDirection, NSRect *))tc_lfr_orig)(self, _cmd, proposed,
		index, dir, &rem);
	if (remaining)
		*remaining = rem;
	tc_last.tc = self;
	tc_last.proposed = proposed;
	tc_last.index = index;
	tc_last.dir = dir;
	tc_last.result = r;
	tc_last.remaining = rem;
	return r;
}

static void stable_line_fragments(const char *cls)
{
	Class c = objc_getClass(cls);
	SEL s = @selector(lineFragmentRectForProposedRect:atIndex:writingDirection:remainingRect:);
	Method m = class_getInstanceMethod([NSTextContainer class], s);
	if (!c || !m)
		return;
	tc_lfr_orig = method_getImplementation(m);
	class_addMethod(c, s, (IMP)xl_tc_lineFragmentRect, method_getTypeEncoding(m));
}

// ---- home screen layout ----------------------------------------------------------------------
// The home screen is a borderless window the size of a layout minus 22 points:
// its layouts are sized to whole screens, less the 22-point menu bar of 2013.
// -[LayoutController loadBestLayoutForScreen:] picks the largest that fits
// -[NSScreen frame], so with today's taller menu bar, and a Dock, the window
// runs off the visible area (on 1280x720 its top goes under the menu bar and
// its bottom off the screen). While the layout is chosen, the screen reports
// its visible area plus those 22 points; the window is then kept inside the
// visible area, and its title bar (if it has one) made transparent.
static IMP orig_screen_frame, orig_load_layout, orig_create_window;
static int choosing_layout;

static NSRect xl_screen_frame(NSScreen *self, SEL _cmd)
{
	NSRect f = ((NSRect (*)(id, SEL))orig_screen_frame)(self, _cmd);
	if (!choosing_layout)
		return f;
	int saved = choosing_layout;
	choosing_layout = 0;   // -visibleFrame asks for -frame
	NSRect v = [self visibleFrame];
	choosing_layout = saved;
	v.size.height += 22;
	const char *forced = getenv("XL_LAYOUT_SCREEN");   // tests: WxH picks another screen's layout
	if (forced)
		sscanf(forced, "%lfx%lf", &v.size.width, &v.size.height);
	if (xl_verbose > 0)
		xl_log("home screen layout for %gx%g", v.size.width, v.size.height);
	return v;
}

static id xl_load_layout(id self, SEL _cmd, NSScreen *screen)
{
	choosing_layout++;
	id r = ((id (*)(id, SEL, NSScreen *))orig_load_layout)(self, _cmd, screen);
	choosing_layout--;
	return r;
}

static id xl_create_window(id self, SEL _cmd, NSScreen *screen)
{
	id r = ((id (*)(id, SEL, NSScreen *))orig_create_window)(self, _cmd, screen);
	NSWindow *w = [self window];
	NSScreen *s = screen ?: [w screen] ?: [NSScreen mainScreen];
	if (w && ([w styleMask] & NSWindowStyleMaskTitled)) {
		// on the screen with the menu bar the window has a title bar, drawn
		// over the layout's top 22 points (left for it); today's is taller and
		// would cover the artwork, so it is transparent over the layout
		[w setStyleMask:[w styleMask] | NSWindowStyleMaskFullSizeContentView];
		[w setTitlebarAppearsTransparent:YES];
		[w setTitleVisibility:NSWindowTitleHidden];
	}
	if (w && s) {
		NSRect f = [w frame], v = [s visibleFrame];
		NSRect g = f;
		g.origin.x = MAX(NSMinX(v), MIN(NSMinX(f), NSMaxX(v) - NSWidth(f)));
		g.origin.y = MAX(NSMinY(v), MIN(NSMinY(f), NSMaxY(v) - NSHeight(f)));
		if (!NSEqualRects(f, g)) {
			if (xl_verbose > 0)
				xl_log("home window moved from %s to %s", [NSStringFromRect(f) UTF8String], [NSStringFromRect(g) UTF8String]);
			[w setFrame:g display:NO];
		}
	}
	return r;
}

static void fitting_home_layout(void)
{
	Class c = objc_getClass("LayoutController");
	Method m = c ? class_getInstanceMethod(c, @selector(loadBestLayoutForScreen:)) : NULL;
	if (!m)
		return;
	orig_load_layout = method_setImplementation(m, (IMP)xl_load_layout);
	m = class_getInstanceMethod(c, @selector(createWindowOnScreen:));
	if (m)
		orig_create_window = method_setImplementation(m, (IMP)xl_create_window);
	orig_screen_frame = method_setImplementation(class_getInstanceMethod([NSScreen class], @selector(frame)),
		(IMP)xl_screen_frame);
}

// ---- home screen photos ----------------------------------------------------------------------
// The OpenGL home screen tells the media provider what textures to make for
// the photos (rectangle ones, which do not repeat) in -onceInit, which
// -[GLView drawRect:] runs at the view's first draw. -[LayoutController
// showHomeScreen:] shows the window and then starts the provider's preloading
// thread: 2013's -showWindow: had drawn the window by the time it returned,
// today the first draw waits for the next display pass. The thread then made
// its first photo with no flags at all, a power-of-two texture that repeats,
// and the strip showed that photo again over the cards beside it. Preloading
// starts once the view has drawn: at once where -display still draws it, else
// on a later turn of the run loop.
static IMP orig_start_preloading;

static NSView *gl_home_view(void)
{
	Class glv = objc_getClass("GLView");
	if (!glv)
		return nil;
	for (NSWindow *w in [NSApp windows])
		if ([w isVisible] && [[w contentView] isKindOfClass:glv])
			return [w contentView];
	return nil;
}

static void xl_start_preloading(id self, SEL _cmd)
{
	static int waits;
	NSView *v = gl_home_view();
	if (v && [self respondsToSelector:@selector(textureFlags)]
		&& !((unsigned (*)(id, SEL))objc_msgSend)(self, @selector(textureFlags)) && waits < 150) {
		if (!waits)
			[v display];
		if (!((unsigned (*)(id, SEL))objc_msgSend)(self, @selector(textureFlags))) {
			waits++;
			[self retain];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
				xl_start_preloading(self, _cmd);
				[self release];
			});
			return;
		}
	}
	if (xl_verbose > 0)
		xl_log("home screen photos: preloading starts after %d wait(s), texture flags %x", waits,
			[self respondsToSelector:@selector(textureFlags)]
				? ((unsigned (*)(id, SEL))objc_msgSend)(self, @selector(textureFlags)) : 0);
	waits = 0;
	((void (*)(id, SEL))orig_start_preloading)(self, _cmd);
}

static void preloading_after_first_draw(void)
{
	Class c = objc_getClass("MediaProvider");
	Method m = c ? class_getInstanceMethod(c, @selector(startPreloading)) : NULL;
	if (m)
		orig_start_preloading = method_setImplementation(m, (IMP)xl_start_preloading);
}

// ---- bundles translated into the executable ------------------------------------------------
// Preference panes and plug-ins are i386 bundles the app loads with NSBundle.
// Their code is translated with the app (xlate/images.txt) and their classes
// registered at launch, so loading one of them is already done: -load says
// so, and -principalClass and -classNamed: answer with the translated classes.
static IMP orig_bundle_load, orig_bundle_loadErr, orig_bundle_isLoaded, orig_bundle_principal, orig_bundle_classNamed,
	orig_bundle_preflight;
static NSSet *translated_bundle_exes;

static BOOL translated_bundle(NSBundle *b)
{
	NSString *e = [[b executablePath] stringByResolvingSymlinksInPath];
	return e && [translated_bundle_exes containsObject:e];
}

static BOOL xl_bundle_load(NSBundle *self, SEL _cmd)
{
	return translated_bundle(self) || ((BOOL (*)(id, SEL))orig_bundle_load)(self, _cmd);
}

static BOOL xl_bundle_loadErr(NSBundle *self, SEL _cmd, NSError **err)
{
	return translated_bundle(self) || ((BOOL (*)(id, SEL, NSError **))orig_bundle_loadErr)(self, _cmd, err);
}

static BOOL xl_bundle_preflight(NSBundle *self, SEL _cmd, NSError **err)
{
	return translated_bundle(self) || ((BOOL (*)(id, SEL, NSError **))orig_bundle_preflight)(self, _cmd, err);
}

static BOOL xl_bundle_isLoaded(NSBundle *self, SEL _cmd)
{
	return translated_bundle(self) || ((BOOL (*)(id, SEL))orig_bundle_isLoaded)(self, _cmd);
}

static Class xl_bundle_principal(NSBundle *self, SEL _cmd)
{
	if (translated_bundle(self)) {
		NSString *n = [self objectForInfoDictionaryKey:@"NSPrincipalClass"];
		Class c = n ? NSClassFromString(n) : nil;
		if (xl_verbose)
			xl_log("principal class of %s: %s", [[self bundlePath] fileSystemRepresentation], c ? class_getName(c) : "none");
		return c;
	}
	return ((Class (*)(id, SEL))orig_bundle_principal)(self, _cmd);
}

static Class xl_bundle_classNamed(NSBundle *self, SEL _cmd, NSString *name)
{
	if (translated_bundle(self))
		return NSClassFromString(name);
	return ((Class (*)(id, SEL, NSString *))orig_bundle_classNamed)(self, _cmd, name);
}

static void translated_bundles(void)
{
	NSString *dir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
	NSMutableSet *s = [NSMutableSet set];
	for (XLImage *im = xl_images; im; im = im->next) {
		if (!im->install || strncmp(im->install, "@executable_path/", 17) || !strstr(im->install, "/Contents/MacOS/"))
			continue;
		NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:im->install + 17]];
		[s addObject:[[p stringByStandardizingPath] stringByResolvingSymlinksInPath]];
	}
	if (![s count])
		return;
	translated_bundle_exes = [s copy];
	if (xl_verbose)
		xl_log("translated bundles: %s", [[s description] UTF8String]);
	Class b = [NSBundle class];
#define HOOK(sel, fn, orig) orig = method_setImplementation(class_getInstanceMethod(b, @selector(sel)), (IMP)fn)
	HOOK(load, xl_bundle_load, orig_bundle_load);
	HOOK(loadAndReturnError:, xl_bundle_loadErr, orig_bundle_loadErr);
	HOOK(preflightAndReturnError:, xl_bundle_preflight, orig_bundle_preflight);
	HOOK(isLoaded, xl_bundle_isLoaded, orig_bundle_isLoaded);
	HOOK(principalClass, xl_bundle_principal, orig_bundle_principal);
	HOOK(classNamed:, xl_bundle_classNamed, orig_bundle_classNamed);
#undef HOOK
}

// ---- boxes in old nibs --------------------------------------------------------------------
// Old nibs draw lines as boxes a couple of points tall, with the default
// title ("Box") left on: the title fell outside the box and was clipped
// away. Views no longer clip to their bounds by default (macOS 14), so such
// boxes from typedstream (pre-keyed) nibs, too short to show a title, lose it.
// Borderless ones still carrying the placeholder title lose the placeholder.
static IMP orig_box_initWithCoder;

static id xl_box_initWithCoder(NSBox *self, SEL _cmd, NSCoder *c)
{
	self = ((id (*)(id, SEL, NSCoder *))orig_box_initWithCoder)(self, _cmd, c);
	if (!self || [c allowsKeyedCoding] || [self titlePosition] == NSNoTitle)
		return self;
	if (NSHeight([self frame]) < NSHeight([self titleRect]))
		[self setTitlePosition:NSNoTitle];
	else if ([self borderType] == NSNoBorder && ([[self title] isEqualToString:@"Title"] || [[self title] isEqualToString:@"Box"]))
		// borderless boxes that only group views keep Interface Builder's
		// placeholder title, which AppKit of the time did not show; emptied
		// rather than removed so the content stays where the nib put it
		[self setTitle:@""];
	return self;
}

static void clipping_old_boxes(void)
{
	orig_box_initWithCoder = method_setImplementation(class_getInstanceMethod([NSBox class], @selector(initWithCoder:)),
		(IMP)xl_box_initWithCoder);
}

// ---- help books --------------------------------------------------------------------------
// Help Viewer is gone (macOS 27): Apple Help calls succeed and show nothing.
// The help books are HTML folders in the bundles, so pages open in the
// default browser instead (on macOS 27, com.apple.helpviewer is Tips, which
// shows them blank). A book is found by its CFBundleHelpBookName in the
// bundles registered with AHRegisterHelpBook (and the main bundle); its
// pages are in the CFBundleHelpBookFolder resource or, for a .help bundle,
// in its localized resources.
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *help_books;
static NSMutableDictionary<NSString *, NSString *> *help_tocs;

void xl_help_register(NSURL *url)
{
	NSBundle *b = url ? [NSBundle bundleWithURL:url] : [NSBundle mainBundle];
	NSString *name = [b objectForInfoDictionaryKey:@"CFBundleHelpBookName"];
	if (!name)
		return;
	if (!help_books) {
		help_books = [[NSMutableDictionary alloc] init];
		help_tocs = [[NSMutableDictionary alloc] init];
	}
	NSMutableArray *dirs = help_books[name] ?: (help_books[name] = [NSMutableArray array]);
	NSString *folder = [b objectForInfoDictionaryKey:@"CFBundleHelpBookFolder"];
	NSMutableArray *cand = [NSMutableArray array];
	if (folder) {
		NSString *p = [b pathForResource:folder ofType:nil];
		if (p)
			[cand addObject:p];
	}
	if ([[[b bundlePath] pathExtension] isEqualToString:@"help"]) {
		for (NSString *l in [b preferredLocalizations])
			[cand addObject:[[b resourcePath] stringByAppendingPathComponent:[l stringByAppendingPathExtension:@"lproj"]]];
		[cand addObject:[b resourcePath]];
	}
	BOOL isDir;
	for (NSString *p in cand) {
		p = [p stringByResolvingSymlinksInPath];
		if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir && ![dirs containsObject:p])
			[dirs addObject:p];
	}
	NSString *toc = [b objectForInfoDictionaryKey:@"CFBundleHelpTOCFile"];
	if (toc && !help_tocs[name])
		help_tocs[name] = toc;
	if (xl_verbose)
		xl_log("help book '%s': %s", [name UTF8String], [[dirs description] UTF8String]);
}

static NSArray<NSString *> *help_dirs(NSString **book)
{
	if (!help_books)
		xl_help_register(nil);
	if (!*book)
		*book = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleHelpBookName"];
	if (*book && !help_books[*book])
		xl_help_register(nil);
	return *book ? help_books[*book] : nil;
}

static NSArray<NSString *> *help_pages(NSArray<NSString *> *dirs)
{
	NSMutableArray *l = [NSMutableArray array];
	for (NSString *d in dirs)
		for (NSString *f in [[NSFileManager defaultManager] enumeratorAtPath:d]) {
			NSString *e = [[f pathExtension] lowercaseString];
			if ([e isEqualToString:@"htm"] || [e isEqualToString:@"html"])
				[l addObject:[d stringByAppendingPathComponent:f]];
		}
	return l;
}

static BOOL help_open(NSString *file, NSString *anchor)
{
	if (!file)
		return NO;
	NSURLComponents *u = [NSURLComponents componentsWithURL:[NSURL fileURLWithPath:file] resolvingAgainstBaseURL:NO];
	if (anchor.length)
		u.fragment = anchor;
	NSWorkspace *ws = [NSWorkspace sharedWorkspace];
	// the browser, not whatever opens .htm files, so the anchor is kept
	NSURL *browser = [ws URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com/"]];
	if (xl_verbose || getenv("XL_HELP_DRYRUN"))
		xl_log("help page %s", [[u.URL absoluteString] UTF8String]);
	if (getenv("XL_HELP_DRYRUN"))
		return YES;
	if (!browser)
		return [ws openURL:u.URL];
	[ws openURLs:@[u.URL] withApplicationAtURL:browser configuration:[NSWorkspaceOpenConfiguration configuration]
		completionHandler:nil];
	return YES;
}

static NSString *help_toc(NSString *book, NSArray<NSString *> *dirs)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray *names = [NSMutableArray array];
	if (help_tocs[book])
		[names addObject:help_tocs[book]];
	[names addObjectsFromArray:@[@"index.html", @"index.htm"]];
	for (NSString *n in names)
		for (NSString *d in dirs)
			if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:n]])
				return [d stringByAppendingPathComponent:n];
	// a page named like its folder or book ("Trivia Help.html")
	for (NSString *p in help_pages(dirs)) {
		NSString *base = [[p lastPathComponent] stringByDeletingPathExtension];
		if ([book hasPrefix:base] || [base isEqualToString:[[p stringByDeletingLastPathComponent] lastPathComponent]])
			return p;
	}
	return [help_pages(dirs) firstObject];
}

static NSString *help_find_anchor(NSArray<NSString *> *dirs, NSString *anchor)
{
	NSString *pat = [NSString stringWithFormat:@"(name|id)\\s*=\\s*\"?%@[\"\\s>]", [NSRegularExpression escapedPatternForString:anchor]];
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionCaseInsensitive error:nil];
	for (NSString *p in help_pages(dirs)) {
		NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]
			?: [NSString stringWithContentsOfFile:p encoding:NSISOLatin1StringEncoding error:nil];
		if (s && [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)])
			return p;
	}
	return nil;
}

// AHGotoPage(book, path, anchor): 0, or paramErr when there is no such book
int xl_help_goto(NSString *book, NSString *path, NSString *anchor)
{
	if (xl_verbose)
		xl_log("help goto book '%s' path '%s' anchor '%s'", [book UTF8String], [path UTF8String], [anchor UTF8String]);
	NSArray *dirs = help_dirs(&book);
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *file = nil;
	if ([path hasPrefix:@"file:"])
		file = [[NSURL URLWithString:path] path];
	else if ([path isAbsolutePath] && [fm fileExistsAtPath:path])
		file = path;
	for (NSString *d in dirs) {
		if (file || !path.length)
			break;
		NSString *p = [d stringByAppendingPathComponent:path];
		if ([fm fileExistsAtPath:p])
			file = p;
	}
	if (!file && path.length)
		for (NSString *p in help_pages(dirs))
			if ([[p lastPathComponent] caseInsensitiveCompare:[path lastPathComponent]] == NSOrderedSame) {
				file = p;
				break;
			}
	if (!file && anchor.length)
		file = help_find_anchor(dirs, anchor);
	if (!file)
		file = help_toc(book, dirs);
	return help_open(file, anchor) ? 0 : -50;
}

// AHLookupAnchor(book, anchor)
int xl_help_anchor(NSString *book, NSString *anchor)
{
	NSArray *dirs = help_dirs(&book);
	NSString *file = anchor.length ? help_find_anchor(dirs, anchor) : nil;
	return help_open(file ?: help_toc(book, dirs), file ? anchor : nil) ? 0 : -50;
}

static void xl_app_showHelp(id self, SEL _cmd, id sender)
{
	xl_help_goto(nil, nil, nil);
}

static void xl_help_openAnchor(id self, SEL _cmd, NSString *anchor, NSString *book)
{
	xl_help_anchor(book, anchor);
}

// ---- responses without a type ------------------------------------------------------------
// The apps' own URL protocols (Surf The Ages: stm://SurfTheAges/index.htm)
// answer with an NSURLResponse of no MIME type. WebKit used to guess one from
// the extension; today it cannot show such a response and stops the load
// ("Frame load interrupted", a blank page). A response made with no type for
// a URL outside the standard schemes gets the type of its extension.
static IMP orig_response_init;

static id xl_response_init(NSURLResponse *self, SEL _cmd, NSURL *url, NSString *mime, NSInteger length, NSString *enc)
{
	static NSSet *standard;
	if (!standard)
		standard = [[NSSet alloc] initWithObjects:@"http", @"https", @"file", @"data", @"about", @"ftp", nil];
	if (!mime && url && ![standard containsObject:[[url scheme] lowercaseString]]) {
		NSString *ext = [[url path] pathExtension];
		mime = ext.length ? [[UTType typeWithFilenameExtension:ext] preferredMIMEType] : nil;
		if (!mime)
			mime = @"text/html";   // the protocols serve pages, and pages link the rest
		if (xl_verbose)
			xl_log("response type for %s: %s (length %ld)", [[url absoluteString] UTF8String], [mime UTF8String], (long)length);
	}
	return ((id (*)(id, SEL, NSURL *, NSString *, NSInteger, NSString *))orig_response_init)(self, _cmd, url, mime, length, enc);
}

static void typed_responses(void)
{
	orig_response_init = method_setImplementation(class_getInstanceMethod([NSURLResponse class],
		@selector(initWithURL:MIMEType:expectedContentLength:textEncodingName:)), (IMP)xl_response_init);
}

int xl_help_in_browser = -1;   // Help Viewer missing (set at launch)

static void help_viewer_gone(void)
{
	// Tips took over Help Viewer's identifier but shows these books blank
	NSURL *hv = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.helpviewer"];
	xl_help_in_browser = getenv("XL_HELP_BROWSER") ? atoi(getenv("XL_HELP_BROWSER"))
		: ![[hv lastPathComponent] isEqualToString:@"HelpViewer.app"];
	if (!xl_help_in_browser)
		return;
	method_setImplementation(class_getInstanceMethod([NSApplication class], @selector(showHelp:)), (IMP)xl_app_showHelp);
	method_setImplementation(class_getInstanceMethod([NSHelpManager class], @selector(openHelpAnchor:inBook:)),
		(IMP)xl_help_openAnchor);
}

// Surf The Ages pages start a sound with <embed src="x.wav" autostart>. The
// encyclopedia's frame load delegate plays a .wav or .mov a frame starts
// loading itself and stops the web view; a plug-in used to take the embed, but
// WebKit now loads it into a subframe, so the delegate stopped the whole page
// and the pictures still loading never came. For a subframe, only that frame stops.
static __thread id media_subframe;
static IMP orig_provisional, orig_stopLoading;

static void xl_webview_stopLoading(id self, SEL _cmd, id sender)
{
	if (media_subframe) {
		((void (*)(id, SEL))objc_msgSend)(media_subframe, @selector(stopLoading));
		return;
	}
	((void (*)(id, SEL, id))orig_stopLoading)(self, _cmd, sender);
}

static void xl_provisional(id self, SEL _cmd, id webView, id frame)
{
	if (!orig_stopLoading) {
		Class wv = objc_getClass("WebView");
		Method m = wv ? class_getInstanceMethod(wv, @selector(stopLoading:)) : NULL;
		if (m)
			orig_stopLoading = method_setImplementation(m, (IMP)xl_webview_stopLoading);
	}
	id main = ((id (*)(id, SEL))objc_msgSend)(webView, @selector(mainFrame));
	id saved = media_subframe;
	media_subframe = frame != main ? frame : nil;
	((void (*)(id, SEL, id, id))orig_provisional)(self, _cmd, webView, frame);
	media_subframe = saved;
}

static void subframe_media(const char *cls)
{
	Class c = objc_getClass(cls);
	Method m = c ? class_getInstanceMethod(c, @selector(webView:didStartProvisionalLoadForFrame:)) : NULL;
	if (m)
		orig_provisional = method_setImplementation(m, (IMP)xl_provisional);
}

// ---- drawing into a flipped image ------------------------------------------------------------
// The text cards of Just Looking (+[WBThumbnailCell imageFromText:...]) are
// drawn into an image made flipped with -setFlipped:YES, then kept as its
// TIFFRepresentation. Today such an image stores what is drawn into it upside
// down. -lockFocusFlipped:YES on an unflipped image gives the same flipped
// coordinates with the bitmap the right way up; the flag comes back at -unlockFocus.
static IMP orig_image_lockFocus, orig_image_unlockFocus;
static __thread int image_focusing;
static char flipped_key;

static void xl_image_lockFocus(NSImage *self, SEL _cmd)
{
	if (image_focusing || ![self isFlipped]) {
		((void (*)(id, SEL))orig_image_lockFocus)(self, _cmd);
		return;
	}
	image_focusing = 1;
	[self setFlipped:NO];
	objc_setAssociatedObject(self, &flipped_key, @YES, OBJC_ASSOCIATION_RETAIN);
	[self lockFocusFlipped:YES];
	image_focusing = 0;
}

static void xl_image_unlockFocus(NSImage *self, SEL _cmd)
{
	((void (*)(id, SEL))orig_image_unlockFocus)(self, _cmd);
	if (objc_getAssociatedObject(self, &flipped_key)) {
		objc_setAssociatedObject(self, &flipped_key, nil, OBJC_ASSOCIATION_RETAIN);
		[self setFlipped:YES];
	}
}

static void flipped_images(void)
{
	Class c = [NSImage class];
	orig_image_lockFocus = method_setImplementation(class_getInstanceMethod(c, @selector(lockFocus)), (IMP)xl_image_lockFocus);
	orig_image_unlockFocus = method_setImplementation(class_getInstanceMethod(c, @selector(unlockFocus)), (IMP)xl_image_unlockFocus);
}

void xl_appkit_hooks(void)
{
	flipped_images();
	help_viewer_gone();
	typed_responses();
	subframe_media("STMController");
	clipping_old_boxes();
	translated_bundles();
	fitting_home_layout();
	preloading_after_first_draw();
	stable_line_fragments("HSExtendedTextContainer");
	if (!class_respondsToSelector([NSNumber class], @selector(isEqualToString:)))
		class_addMethod([NSNumber class], @selector(isEqualToString:), (IMP)xl_number_isEqualToString, "c@:@");
	add_noop("HSArticleView", "layoutManagerDidInvalidateLayout:");
	Class movie = objc_getClass("NSMovie");
	if (movie && !class_getInstanceMethod(movie, @selector(initWithURL:byReference:)))
		class_addMethod(movie, @selector(initWithURL:byReference:), (IMP)xl_movie_initWithURL, "@@:@c");
	orig_drawingToScreen = method_setImplementation(class_getClassMethod([NSGraphicsContext class],
		@selector(currentContextDrawingToScreen)), (IMP)xl_drawingToScreen);
	Class vc = [NSView class];
	orig_lockFocus = method_setImplementation(class_getInstanceMethod(vc, @selector(lockFocus)), (IMP)xl_lockFocus);
	orig_lockFocusIfCanDraw = method_setImplementation(class_getInstanceMethod(vc, @selector(lockFocusIfCanDraw)),
		(IMP)xl_lockFocusIfCanDraw);
	orig_unlockFocus = method_setImplementation(class_getInstanceMethod(vc, @selector(unlockFocus)), (IMP)xl_unlockFocus);
	Class k = objc_getClass("NSCachedImageRep");
	if (k) {
		Method m = class_getInstanceMethod(k, @selector(initWithWindow:rect:));
		if (m)
			orig_cached_init = method_setImplementation(m, (IMP)xl_cached_initWithWindow);
		m = class_getInstanceMethod(k, @selector(draw));
		if (m)
			orig_cached_draw = method_setImplementation(m, (IMP)xl_cached_draw);
	}
}
