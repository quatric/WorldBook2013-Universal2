// AppKit behaviour the 2013 code relies on that current AppKit dropped.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
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
	if (!w || [w isVisible])
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

void xl_appkit_hooks(void)
{
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
