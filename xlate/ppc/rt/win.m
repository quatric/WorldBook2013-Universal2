// Window Manager (see win.h).
#import <AppKit/AppKit.h>
#include "win.h"
#include "ctl.h"

enum { TAG_WIN = 'wind' };
static Win *windows;   // front to back

uint32_t res_get(uint32_t type, int16_t id, int one);

// ---- the content view -----------------------------------------------------------

@interface XLWinView : NSView {
@public
	Win *win;
	NSTrackingArea *track;
}
@end

@interface XLWindow : NSWindow
@end
@implementation XLWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface XLPanel : NSPanel
@end
@implementation XLPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface XLWinDelegate : NSObject <NSWindowDelegate>
@end

static XLWinDelegate *delegate;

@implementation XLWinView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }
- (void)drawRect:(NSRect)dirty
{
	(void)dirty;
	Port *p = win ? win->port : NULL;
	if (!p || !p->pix)
		return;
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
	NSRect b = self.bounds;
	if (b.size.width > w || b.size.height > h) {
		CGContextSetRGBFillColor(cg, p->bg.r / 65535.0, p->bg.g / 65535.0, p->bg.b / 65535.0, 1);
		CGContextFillRect(cg, NSRectToCGRect(b));
	}
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, G(p->pix), (size_t)p->rowBytes * h, NULL);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGImageRef img = CGImageCreate(w, h, 8, 32, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp,
		NULL, false, kCGRenderingIntentDefault);
	CGContextSaveGState(cg);
	CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
	CGContextTranslateCTM(cg, 0, h);
	CGContextScaleCTM(cg, 1, -1);
	CGContextDrawImage(cg, CGRectMake(0, 0, w, h), img);
	CGContextRestoreGState(cg);
	CGImageRelease(img);
	CGColorSpaceRelease(cs);
	CGDataProviderRelease(dp);
}
- (QPoint)globalOf:(NSEvent *)e
{
	NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
	QPoint o = win_origin(win);
	return (QPoint){(int16_t)(o.v + (int)floor(p.y)), (int16_t)(o.h + (int)floor(p.x))};
}
- (void)mouse:(NSEvent *)e what:(int)what
{
	Ev ev = {0};
	ev.what = (uint16_t)what;
	ev.where = [self globalOf:e];
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | (what == 2 ? 0x80 : 0);
	ev.message = what == 1 ? (uint32_t)(e.clickCount > 1 ? 1 : 0) : 0;
	ev.win = win;
	ev_post(ev);
}
- (void)mouseDown:(NSEvent *)e { [self mouse:e what:1]; }
- (void)mouseUp:(NSEvent *)e { [self mouse:e what:2]; }
- (void)rightMouseDown:(NSEvent *)e
{
	// a control-click, as on one-button mice
	Ev ev = {0};
	ev.what = 1;
	ev.where = [self globalOf:e];
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | 0x1000;
	ev.win = win;
	ev_post(ev);
}
- (void)rightMouseUp:(NSEvent *)e { [self mouse:e what:2]; }
- (void)keyUp:(NSEvent *)e { (void)e; }
- (void)flagsChanged:(NSEvent *)e { (void)e; }
- (void)cursorUpdate:(NSEvent *)e { (void)e; }   // the guest sets the cursor
- (void)updateTrackingAreas
{
	if (track)
		[self removeTrackingArea:track];
	[track release];
	track = [[NSTrackingArea alloc] initWithRect:self.bounds
		options:NSTrackingCursorUpdate | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
	[self addTrackingArea:track];
	[super updateTrackingAreas];
}
@end

// key events: Mac Roman characters and the classic key codes (the same as the virtual key codes)
static uint8_t mac_char(NSEvent *e)
{
	NSString *s = (e.modifierFlags & NSEventModifierFlagCommand) ? e.charactersIgnoringModifiers : e.characters;
	if (!s.length)
		return 0;
	unichar u = [s characterAtIndex:0];
	switch (u) {
	case NSLeftArrowFunctionKey: return 28;
	case NSRightArrowFunctionKey: return 29;
	case NSUpArrowFunctionKey: return 30;
	case NSDownArrowFunctionKey: return 31;
	case NSDeleteFunctionKey: return 127;
	case NSHomeFunctionKey: return 1;
	case NSEndFunctionKey: return 4;
	case NSPageUpFunctionKey: return 11;
	case NSPageDownFunctionKey: return 12;
	case NSHelpFunctionKey: return 5;
	case 0x7f: return 8;      // the delete key is backspace
	case 0x19: return 9;      // back tab
	case 3: return 3;
	}
	if (u >= NSF1FunctionKey && u <= NSF35FunctionKey)
		return 16;
	if (u < 128)
		return (uint8_t)u;
	char buf[8];
	if ([s getCString:buf maxLength:sizeof buf encoding:NSMacOSRomanStringEncoding])
		return (uint8_t)buf[0];
	return '?';
}

@implementation XLWinView (Keys)
- (void)keyDown:(NSEvent *)e
{
	Ev ev = {0};
	ev.what = e.ARepeat ? 5 : 3;
	ev.message = mac_char(e) | ((uint32_t)e.keyCode << 8);
	ev.where = ev_mouse_global();
	ev.modifiers = ev_mac_modifiers(e.modifierFlags) | 0x80;
	ev.win = win;
	ev_post(ev);
}
- (void)scrollWheel:(NSEvent *)e
{
	extern void ev_scroll(Win *w, NSEvent *e);
	ev_scroll(win, e);
}
@end

@implementation XLWinDelegate
static Win *of(NSNotification *n)
{
	for (Win *w = windows; w; w = w->next)
		if (w->ns == n.object)
			return w;
	return NULL;
}
static Win *ofw(NSWindow *nw)
{
	for (Win *w = windows; w; w = w->next)
		if (w->ns == nw)
			return w;
	return NULL;
}
- (void)windowDidMove:(NSNotification *)n
{
	Win *w = of(n);
	if (!w)
		return;
	NSRect cr = [(NSWindow *)w->ns contentRectForFrameRect:((NSWindow *)w->ns).frame];
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	w->frame.left = (int16_t)cr.origin.x;
	w->frame.top = (int16_t)qd_global_y(cr.origin.y + cr.size.height);
	w->frame.right = (int16_t)(w->frame.left + wd);
	w->frame.bottom = (int16_t)(w->frame.top + ht);
}
- (BOOL)windowShouldClose:(NSWindow *)nw
{
	Win *w = ofw(nw);
	if (w)
		ev_post_mouse_part(w, 6, 0);   // inGoAway
	return NO;
}
- (BOOL)windowShouldZoom:(NSWindow *)nw toFrame:(NSRect)f
{
	(void)f;
	Win *w = ofw(nw);
	if (w) {
		QRect cur = w->frame;
		int atStd = !memcmp(&cur, &w->stdState, sizeof cur);
		ev_post_mouse_part(w, atStd ? 7 : 8, 0);   // inZoomIn / inZoomOut
	}
	return NO;
}
- (void)windowDidEndLiveResize:(NSNotification *)n
{
	Win *w = of(n);
	if (!w)
		return;
	NSRect cr = [(NSWindow *)w->ns contentRectForFrameRect:((NSWindow *)w->ns).frame];
	uint32_t size = ((uint32_t)(uint16_t)cr.size.height << 16) | (uint16_t)cr.size.width;
	ev_post_mouse_part(w, 5, size);   // inGrow
}
- (void)windowDidMiniaturize:(NSNotification *)n { Win *w = of(n); if (w) w->collapsed = 1; }
- (void)windowDidDeminiaturize:(NSNotification *)n { Win *w = of(n); if (w) w->collapsed = 0; }
@end

// ---- windows ---------------------------------------------------------------------------

Win *WIN(uint32_t tok) { return tok ? tok_get(tok, TAG_WIN) : NULL; }
Win *win_list(void) { return windows; }

Win *win_front(int visible_only)
{
	for (Win *w = windows; w; w = w->next)
		if (!visible_only || w->visible)
			return w;
	return NULL;
}

static int is_floating(Win *w) { return w->wclass == 5 || w->wclass == 7 || w->wclass == 8; }

QPoint win_origin(Win *w) { return (QPoint){w->frame.top, w->frame.left}; }

void win_dirty(Win *w, QRect r)
{
	w->dirty = w->has_dirty ? rect_union(w->dirty, r) : r;
	w->has_dirty = 1;
}

void win_flush(Win *w)
{
	if (!w->has_dirty || !w->view)
		return;
	XLWinView *v = w->view;
	QRect r = rect_off(w->dirty, -w->port->portRect.left, -w->port->portRect.top);
	[v setNeedsDisplayInRect:NSMakeRect(r.left, r.top, r.right - r.left, r.bottom - r.top)];
	w->has_dirty = 0;
}

void win_flush_all(void)
{
	for (Win *w = windows; w; w = w->next)
		win_flush(w);
}

void win_invalidate(Win *w, QRect r)
{
	Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&t, r);
	rgn_op(w->update, w->update, &t, RGN_UNION);
	free(t.r);
}

Win *win_at(int h, int v)
{
	for (Win *w = windows; w; w = w->next) {
		if (!w->visible || w->collapsed)
			continue;
		NSRect f = ((NSWindow *)w->ns).frame;
		double cy = qd_cocoa_y(v);
		if (h >= f.origin.x && h < f.origin.x + f.size.width && cy > f.origin.y && cy <= f.origin.y + f.size.height)
			return w;
	}
	return NULL;
}

static void list_remove(Win *w)
{
	for (Win **p = &windows; *p; p = &(*p)->next)
		if (*p == w) {
			*p = w->next;
			return;
		}
}

static void list_front(Win *w)
{
	list_remove(w);
	// floating windows stay in front of the others
	if (is_floating(w)) {
		w->next = windows;
		windows = w;
		return;
	}
	Win **p = &windows;
	while (*p && is_floating(*p))
		p = &(*p)->next;
	w->next = *p;
	*p = w;
}

static NSRect cocoa_content(QRect r)
{
	return NSMakeRect(r.left, qd_cocoa_y(r.bottom), r.right - r.left, r.bottom - r.top);
}

static void ns_title(Win *w)
{
	NSString *t = mac_ns(w->title + 1, w->title[0]);
	((NSWindow *)w->ns).title = t;
}

static Win *win_create(int wclass, uint32_t attrs, QRect bounds, const uint8_t *title, int visible, uint32_t refCon, uint32_t behind)
{
	Win *w = calloc(1, sizeof *w);
	w->wclass = wclass;
	w->attrs = attrs;
	w->frame = bounds;
	w->refCon = refCon;
	w->kind = 8;   // userKind
	w->update = rgn_new();
	if (title)
		memcpy(w->title, title, title[0] + 1);
	int wd = bounds.right - bounds.left, ht = bounds.bottom - bounds.top;
	w->port = port_new(0, 0, (QRect){0, 0, (int16_t)ht, (int16_t)wd}, 1);
	w->port->win = w;
	w->tok = tok_new(w, 256, TAG_WIN);
	ST32(w->tok + 0, w->port->tok);   // so that a WindowPtr dereferences to its port, as in classic code
	w->stdState = qd_screen_rect();
	w->stdState.top += qd_menubar_height + 22;
	w->stdState = rect_off(w->stdState, 0, 0);
	w->userState = bounds;

	NSWindowStyleMask style;
	BOOL panel = NO;
	switch (wclass) {
	case 11: case 14: case 12: style = NSWindowStyleMaskBorderless; break;     // plain
	case 5: case 7: case 8: style = NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow; panel = YES; break;
	case 1: case 2: case 3: case 4: style = NSWindowStyleMaskTitled; break;   // alerts, modal dialogs
	default: style = NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable; break;
	}
	if (style != NSWindowStyleMaskBorderless) {
		if (attrs & 1)
			style |= NSWindowStyleMaskClosable;
		if (attrs & 0x10)
			style |= NSWindowStyleMaskResizable;
		if (!(attrs & 8) && wclass == 6)
			style &= ~NSWindowStyleMaskMiniaturizable;
	}
	NSRect cr = cocoa_content(bounds);
	NSWindow *nw;
	if (panel)
		nw = [[XLPanel alloc] initWithContentRect:cr styleMask:style backing:NSBackingStoreBuffered defer:NO];
	else
		nw = [[XLWindow alloc] initWithContentRect:cr styleMask:style backing:NSBackingStoreBuffered defer:NO];
	nw.releasedWhenClosed = NO;
	if (!delegate)
		delegate = [XLWinDelegate new];
	nw.delegate = delegate;
	if (panel) {
		nw.level = NSFloatingWindowLevel;
		((NSPanel *)nw).floatingPanel = YES;
		((NSPanel *)nw).hidesOnDeactivate = YES;
		((NSPanel *)nw).becomesKeyOnlyIfNeeded = YES;
	} else if (wclass >= 1 && wclass <= 4)
		nw.level = NSModalPanelWindowLevel;
	if (!(attrs & 6))
		[nw standardWindowButton:NSWindowZoomButton].enabled = NO;
	else
		[nw standardWindowButton:NSWindowZoomButton].enabled = YES;
	nw.tabbingMode = NSWindowTabbingModeDisallowed;
	XLWinView *v = [[XLWinView alloc] initWithFrame:NSMakeRect(0, 0, wd, ht)];
	v->win = w;
	nw.contentView = v;
	nw.acceptsMouseMovedEvents = YES;
	w->ns = nw;
	w->view = v;
	ns_title(w);
	if (behind == 0xffffffffu || behind == 0) {
		list_front(w);
	} else {
		Win *b = WIN(behind);
		if (b) {
			w->next = b->next;
			b->next = w;
		} else
			list_front(w);
	}
	if (visible) {
		extern void win_show(Win *w);
		win_show(w);
	}
	return w;
}

void win_show(Win *w)
{
	if (w->visible)
		return;
	Win *oldfront = win_front(1);
	w->visible = 1;
	NSWindow *nw = w->ns;
	[NSApp activateIgnoringOtherApps:YES];
	if (w == win_front(0) || is_floating(w))
		[nw makeKeyAndOrderFront:nil];
	else
		[nw orderFront:nil];
	win_invalidate(w, w->port->portRect);
	if (win_front(1) == w && !is_floating(w) && oldfront != w) {
		if (oldfront && !is_floating(oldfront))
			ev_activate(oldfront, 0);
		ev_activate(w, 1);
	}
}

static void win_hide(Win *w)
{
	if (!w->visible)
		return;
	int wasfront = win_front(1) == w;
	w->visible = 0;
	[(NSWindow *)w->ns orderOut:nil];
	if (wasfront) {
		ev_activate(w, 0);
		Win *f = win_front(1);
		if (f) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}

static void select_window(Win *w)
{
	Win *old = NULL;
	for (Win *x = windows; x; x = x->next)
		if (x->visible && !is_floating(x)) {
			old = x;
			break;
		}
	list_front(w);
	[(NSWindow *)w->ns makeKeyAndOrderFront:nil];
	if (old != w && !is_floating(w)) {
		if (old)
			ev_activate(old, 0);
		ev_activate(w, 1);
	}
}

static void win_dispose(Win *w)
{
	int wasfront = win_front(1) == w;
	if (w->root)
		ctl_dispose_all(w);
	list_remove(w);
	NSWindow *nw = w->ns;
	nw.delegate = nil;
	[nw orderOut:nil];
	[nw close];
	((XLWinView *)w->view)->win = NULL;
	[(XLWinView *)w->view release];
	[nw release];
	gfree(w->port->pix);
	port_free(w->port);
	rgn_free(w->update);
	tok_free(w->tok);
	extern void ev_forget_window(Win *w);
	ev_forget_window(w);
	free(w);
	if (wasfront) {
		Win *f = win_front(1);
		if (f && !is_floating(f)) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}

static void size_window(Win *w, int wd, int ht)
{
	if (wd <= 0 || ht <= 0)
		return;
	QRect pr = w->port->portRect;
	port_resize(w->port, (QRect){pr.top, pr.left, (int16_t)(pr.top + ht), (int16_t)(pr.left + wd)});
	w->frame.right = (int16_t)(w->frame.left + wd);
	w->frame.bottom = (int16_t)(w->frame.top + ht);
	NSWindow *nw = w->ns;
	NSRect cr = cocoa_content(w->frame);
	[nw setFrame:[nw frameRectForContentRect:cr] display:NO];
	[(XLWinView *)w->view setFrame:NSMakeRect(0, 0, wd, ht)];
	[(XLWinView *)w->view setNeedsDisplay:YES];
}

static void move_window(Win *w, int h, int v)
{
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	w->frame = (QRect){(int16_t)v, (int16_t)h, (int16_t)(v + ht), (int16_t)(h + wd)};
	NSWindow *nw = w->ns;
	NSRect cr = cocoa_content(w->frame);
	[nw setFrame:[nw frameRectForContentRect:cr] display:NO];
}

// ---- shims -------------------------------------------------------------------------------------

// classic window definition IDs -> Carbon classes and attributes
static void proc_class(int proc, int goAway, int *cls, uint32_t *attrs)
{
	*attrs = goAway ? 1 : 0;
	int var = proc & 15;
	if (proc < 64) {
		switch (proc) {
		case 0: *cls = 6; *attrs |= 0x10 | 8; break;          // documentProc
		case 1: case 2: case 3: *cls = proc == 1 ? 3 : 11; break;
		case 4: *cls = 6; *attrs |= 8; break;                 // noGrowDocProc
		case 5: *cls = 4; break;                              // movableDBoxProc
		case 8: *cls = 6; *attrs |= 0x10 | 6 | 8; break;      // zoomDocProc
		case 12: *cls = 6; *attrs |= 6 | 8; break;
		case 16: *cls = 6; break;
		default: *cls = 6; break;
		}
		return;
	}
	switch (proc >> 4) {
	case 64:   // kWindowDocumentProc 1024..
		*cls = 6;
		*attrs |= 8;
		if (var & 1)
			*attrs |= 0x10;
		if (var & 2)
			*attrs |= 4;
		if (var & 4)
			*attrs |= 2;
		break;
	case 65:   // dialogs 1040..
		*cls = var == 0 ? 3 : var == 1 ? 11 : var == 2 ? 11 : var == 3 ? 4 : var == 5 ? 2 : var == 6 ? 1 : 3;
		break;
	case 66: case 67: case 68: case 69:   // floating 1056.., side floating
		*cls = 7;
		if (var & 1)
			*attrs |= 0x10;
		break;
	default: *cls = 6; break;
	}
}

static void sh_NewCWindow(PPC *c)
{
	// NewCWindow(storage, bounds, title, visible, procID, behind, goAwayFlag, refCon)
	int cls;
	uint32_t attrs;
	proc_class((int16_t)A(4), A(6) & 0xff, &cls, &attrs);
	uint8_t title[256] = {0};
	if (A(2))
		memcpy(title, G(A(2)), LD8(A(2)) + 1);
	Win *w = win_create(cls, attrs, RECT(A(1)), title, A(3) & 0xff, A(7), A(5));
	w->procID = (int16_t)A(4);
	w->goAway = A(6) & 0xff;
	RET(w->tok);
}

static void sh_GetNewCWindow(PPC *c)
{
	uint32_t h = res_get('WIND', (int16_t)A(0), 0);
	if (!h) {
		RET(0);
		return;
	}
	uint32_t p = HP(h);
	QRect r = RECT(p);
	int proc = (int16_t)LD16(p + 8), vis = LD16(p + 10) != 0, goAway = LD16(p + 12) != 0;
	uint32_t refCon = LD32(p + 14);
	uint8_t title[256];
	memcpy(title, G(p + 18), LD8(p + 18) + 1);
	uint32_t pos_off = p + 18 + 1 + title[0];
	if (pos_off & 1)
		pos_off++;
	if (pos_off + 2 <= p + HSize(h)) {
		int pos = LD16(pos_off);
		QRect s = qd_screen_rect();
		int wd = r.right - r.left, ht = r.bottom - r.top;
		if (pos == 0x280a || pos == 0xa80a) {   // center on the main screen
			r.left = (int16_t)((s.right - wd) / 2);
			r.top = (int16_t)(qd_menubar_height + (s.bottom - qd_menubar_height - ht) / 2);
		} else if (pos == 0x300a || pos == 0xb00a) {   // alert position
			r.left = (int16_t)((s.right - wd) / 2);
			r.top = (int16_t)(qd_menubar_height + (s.bottom - qd_menubar_height - ht) / 3);
		}
		r.right = (int16_t)(r.left + wd);
		r.bottom = (int16_t)(r.top + ht);
	}
	int cls;
	uint32_t attrs;
	proc_class(proc, goAway, &cls, &attrs);
	Win *w = win_create(cls, attrs, r, title, vis, refCon, A(2));
	w->procID = proc;
	w->goAway = goAway;
	RET(w->tok);
}

static void sh_CreateNewWindow(PPC *c)
{
	// CreateNewWindow(class, attributes, const Rect *bounds, WindowRef *)
	Win *w = win_create((int)A(0), A(1), RECT(A(2)), NULL, 0, 0, 0xffffffffu);
	ST32(A(3), w->tok);
	RET(0);
}

static void sh_CreateCustomWindow(PPC *c)
{
	// CreateCustomWindow(const WindowDefSpec *, class, attributes, const Rect *, WindowRef *)
	Win *w = win_create((int)A(1), A(2), RECT(A(3)), NULL, 0, 0, 0xffffffffu);
	w->wdef = A(0) ? LD32(A(0) + 4) : 0;
	ST32(A(4), w->tok);
	RET(0);
}

static void sh_DisposeWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_dispose(w); }
static void sh_ShowWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_show(w); }
static void sh_HideWindow(PPC *c) { Win *w = WIN(A(0)); if (w) win_hide(w); }
static void sh_SelectWindow(PPC *c) { Win *w = WIN(A(0)); if (w) select_window(w); }
static void sh_HiliteWindow(PPC *c) { Win *w = WIN(A(0)); if (w) w->hilited = A(1) & 0xff; }
static void sh_SendBehind(PPC *c)
{
	Win *w = WIN(A(0)), *b = WIN(A(1));
	if (!w)
		return;
	int wasfront = win_front(1) == w;
	list_remove(w);
	if (b) {
		w->next = b->next;
		b->next = w;
		[(NSWindow *)w->ns orderWindow:NSWindowBelow relativeTo:((NSWindow *)b->ns).windowNumber];
	} else {
		Win **p = &windows;
		while (*p)
			p = &(*p)->next;
		*p = w;
		w->next = NULL;
		[(NSWindow *)w->ns orderBack:nil];
	}
	if (wasfront && win_front(1) != w) {
		ev_activate(w, 0);
		Win *f = win_front(1);
		if (f) {
			[(NSWindow *)f->ns makeKeyWindow];
			ev_activate(f, 1);
		}
	}
}
static void sh_FrontWindow(PPC *c) { Win *w = win_front(1); RET(w ? w->tok : 0); }
static void sh_FrontNonFloatingWindow(PPC *c)
{
	for (Win *w = windows; w; w = w->next)
		if (w->visible && !is_floating(w)) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetFrontWindowOfClass(PPC *c)
{
	for (Win *w = windows; w; w = w->next)
		if ((w->wclass == (int)A(0) || (int)A(0) == -1) && (w->visible || !(A(1) & 0xff))) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetNextWindowOfClass(PPC *c)
{
	Win *w = WIN(A(0));
	for (w = w ? w->next : NULL; w; w = w->next)
		if ((w->wclass == (int)A(1) || (int)A(1) == -1) && (w->visible || !(A(2) & 0xff))) {
			RET(w->tok);
			return;
		}
	RET(0);
}
static void sh_GetWindowList(PPC *c) { RET(windows ? windows->tok : 0); }
static void sh_GetNextWindow(PPC *c) { Win *w = WIN(A(0)); RET(w && w->next ? w->next->tok : 0); }
static void sh_GetWRefCon(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->refCon : 0); }
static void sh_SetWRefCon(PPC *c) { Win *w = WIN(A(0)); if (w) w->refCon = A(1); }
static void sh_GetWTitle(PPC *c) { Win *w = WIN(A(0)); if (w) memcpy(G(A(1)), w->title, w->title[0] + 1); }
static void sh_SetWTitle(PPC *c)
{
	Win *w = WIN(A(0));
	if (w && A(1)) {
		memcpy(w->title, G(A(1)), LD8(A(1)) + 1);
		ns_title(w);
	}
}
static void sh_GetWindowKind(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->kind : 0); }
static void sh_SetWindowKind(PPC *c) { Win *w = WIN(A(0)); if (w) w->kind = (int16_t)A(1); }
static void sh_GetWindowClass(PPC *c) { Win *w = WIN(A(0)); if (w) ST32(A(1), w->wclass); RET(w ? 0 : -5600); }
static void sh_GetWindowPort(PPC *c) { Win *w = WIN(A(0)); RET(w ? w->port->tok : 0); }
static void sh_SetPortWindowPort(PPC *c) { Win *w = WIN(A(0)); if (w) qd_port = w->port; }
static void sh_GetWindowFromPort(PPC *c) { Port *p = PORT(A(0)); RET(p && p->win ? p->win->tok : 0); }
static void sh_IsWindowVisible(PPC *c) { Win *w = WIN(A(0)); RET(w && w->visible); }
static void sh_IsValidWindowPtr(PPC *c) { RET(WIN(A(0)) != NULL); }
static void sh_IsWindowCollapsed(PPC *c) { Win *w = WIN(A(0)); RET(w && w->collapsed); }
static void sh_CollapseWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	if (A(1) & 0xff)
		[(NSWindow *)w->ns miniaturize:nil];
	else
		[(NSWindow *)w->ns deminiaturize:nil];
	RET(0);
}

static QRect structure_rect(Win *w)
{
	NSRect f = ((NSWindow *)w->ns).frame;
	return (QRect){(int16_t)qd_global_y(f.origin.y + f.size.height), (int16_t)f.origin.x,
		(int16_t)qd_global_y(f.origin.y), (int16_t)(f.origin.x + f.size.width)};
}

static QRect region_rect(Win *w, int code)
{
	switch (code) {
	case 32: case 35: return structure_rect(w);           // structure, opaque
	case 33: case 40: return w->frame;                    // content, global port
	case 0: case 5: {                                     // title bar, drag
		QRect s = structure_rect(w);
		s.bottom = w->frame.top;
		return s;
	}
	case 34: return w->update->n ? rect_off(w->update->bbox, w->frame.left, w->frame.top) : (QRect){0, 0, 0, 0};
	default: return (QRect){0, 0, 0, 0};
	}
}

static void sh_GetWindowBounds(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-5600);
		return;
	}
	PUTRECT(A(2), region_rect(w, (int)A(1)));
	RET(0);
}
static void sh_GetWindowPortBounds(PPC *c)
{
	Win *w = WIN(A(0));
	if (w)
		PUTRECT(A(1), w->port->portRect);
	RET(A(1));
}
static void sh_GetWindowRegion(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(2));
	if (!w || !g) {
		RET(-50);
		return;
	}
	rgn_set_rect(g, region_rect(w, (int)A(1)));
	rgn_sync(A(2));
	RET(0);
}

static Win *port_win(void) { return qd_port ? qd_port->win : NULL; }

static void sh_InvalWindowRect(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		win_invalidate(w, RECT(A(1)));
		RET(0);
	} else
		RET(-5600);
}
static void sh_InvalWindowRgn(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(1));
	if (w && g)
		rgn_op(w->update, w->update, g, RGN_UNION);
	RET(0);
}
static void sh_ValidWindowRect(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_set_rect(&t, RECT(A(1)));
		rgn_op(w->update, w->update, &t, RGN_DIFF);
		free(t.r);
	}
	RET(0);
}
static void sh_ValidWindowRgn(PPC *c)
{
	Win *w = WIN(A(0));
	Rgn *g = RGN(A(1));
	if (w && g)
		rgn_op(w->update, w->update, g, RGN_DIFF);
	RET(0);
}

static void sh_BeginUpdate(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	Port *p = w->port;
	if (!w->saved_vis)
		w->saved_vis = rgn_new();
	rgn_copy(w->saved_vis, p->vis);
	// the update region is in local coordinates of the port's origin at invalidation time
	rgn_op(p->vis, p->vis, w->update, RGN_SECT);
	rgn_set_empty(w->update);
	w->in_update = 1;
}
static void sh_EndUpdate(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w || !w->in_update)
		return;
	rgn_copy(w->port->vis, w->saved_vis);
	w->in_update = 0;
}
static void sh_DrawGrowIcon(PPC *c) { (void)c; }
static void sh_SetWindowContentColor(PPC *c)
{
	Win *w = WIN(A(0));
	if (w) {
		w->content_color = (RGB16){(uint16_t)LD16(A(1)), (uint16_t)LD16(A(1) + 2), (uint16_t)LD16(A(1) + 4)};
		w->has_content_color = 1;
	}
	RET(0);
}
static void sh_SetWindowStandardState(PPC *c) { Win *w = WIN(A(0)); if (w) w->stdState = RECT(A(1)); RET(0); }
static void sh_SetWindowUserState(PPC *c) { Win *w = WIN(A(0)); if (w) w->userState = RECT(A(1)); RET(0); }

static void sh_MoveWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	move_window(w, (int16_t)A(1), (int16_t)A(2));
	if (A(3) & 0xff)
		select_window(w);
}
static void sh_SizeWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (w)
		size_window(w, (int16_t)A(1), (int16_t)A(2));
}
static void sh_DragWindow(PPC *c) { (void)c; }   // Cocoa moves windows by their title bars
static void sh_GrowWindow(PPC *c)
{
	// the size the user gave the window (inGrow comes after the live resize)
	if (ev_last.part == 5)
		RET(ev_last.data);
	else
		RET(0);
}
static void sh_TrackGoAway(PPC *c) { RET(1); }
static void sh_TrackBox(PPC *c) { RET(1); }
static void sh_ZoomWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w)
		return;
	QRect r = (int16_t)A(1) == 8 ? w->stdState : w->userState;
	if ((int16_t)A(1) == 8)
		w->userState = w->frame;
	move_window(w, r.left, r.top);
	size_window(w, r.right - r.left, r.bottom - r.top);
	win_invalidate(w, w->port->portRect);
}
static void sh_RepositionWindow(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-50);
		return;
	}
	int method = (int)A(2);
	QRect s = qd_screen_rect();
	Win *parent = WIN(A(1));
	if (parent && (method == 2 || method == 4 || method == 6)) {
		s = parent->frame;
	} else
		s.top = (int16_t)qd_menubar_height;
	int wd = w->frame.right - w->frame.left, ht = w->frame.bottom - w->frame.top;
	int h = s.left + (s.right - s.left - wd) / 2;
	int v = (method == 3 || method == 4) ? s.top + (s.bottom - s.top - ht) / 3 : s.top + (s.bottom - s.top - ht) / 2;
	if (v < qd_menubar_height + 22)
		v = qd_menubar_height + 22;
	move_window(w, h, v);
	RET(0);
}
static void sh_HideFloatingWindows(PPC *c) { RET(0); }
static void sh_ShowFloatingWindows(PPC *c) { RET(0); }
static void sh_IsWindowPathSelectClick(PPC *c) { RET(0); }
static void sh_WindowPathSelect(PPC *c) { RET(-128); }
static void sh_TrackWindowProxyDrag(PPC *c) { RET(-5604); }
static void sh_GetWindowEventTarget(PPC *c)
{
	Win *w = WIN(A(0));
	if (w && !w->evtarget)
		w->evtarget = tok_new(w, 16, 'evtg');
	RET(w ? w->evtarget : 0);
}

// FindWindow(Point, WindowRef *) -> part
static void sh_FindWindow(PPC *c)
{
	QPoint p = PT(A(0));
	uint32_t out = A(1);
	if (ev_last.part && ev_last.where.h == p.h && ev_last.where.v == p.v) {
		if (out)
			ST32(out, ev_last.win ? ev_last.win->tok : 0);
		RET(ev_last.part);
		return;
	}
	if (out)
		ST32(out, 0);
	if (p.v < qd_menubar_height && p.v >= 0) {
		RET(1);   // inMenuBar
		return;
	}
	Win *w = win_at(p.h, p.v);
	if (!w) {
		RET(0);
		return;
	}
	if (out)
		ST32(out, w->tok);
	if (p.v >= w->frame.top && p.v < w->frame.bottom && p.h >= w->frame.left && p.h < w->frame.right)
		RET(3);   // inContent
	else
		RET(4);   // inDrag
}

static const ShimDef winshims[] = {
	S(NewCWindow), S(GetNewCWindow), S(CreateNewWindow), S(CreateCustomWindow), S(DisposeWindow), S(ShowWindow),
	S(HideWindow), S(SelectWindow), S(HiliteWindow), S(SendBehind), S(FrontWindow), S(FrontNonFloatingWindow),
	S(GetFrontWindowOfClass), S(GetNextWindowOfClass), S(GetWindowList), S(GetNextWindow), S(GetWRefCon),
	S(SetWRefCon), S(GetWTitle), S(SetWTitle), S(GetWindowKind), S(SetWindowKind), S(GetWindowClass),
	S(GetWindowPort), S(SetPortWindowPort), S(GetWindowFromPort), S(IsWindowVisible), S(IsValidWindowPtr),
	S(IsWindowCollapsed), S(CollapseWindow), S(GetWindowBounds), S(GetWindowPortBounds), S(GetWindowRegion),
	S(InvalWindowRect), S(InvalWindowRgn), S(ValidWindowRect), S(ValidWindowRgn), S(BeginUpdate), S(EndUpdate),
	S(DrawGrowIcon), S(SetWindowContentColor), S(SetWindowStandardState), S(SetWindowUserState), S(MoveWindow),
	S(SizeWindow), S(DragWindow), S(GrowWindow), S(TrackGoAway), S(TrackBox), S(ZoomWindow), S(RepositionWindow),
	S(HideFloatingWindows), S(ShowFloatingWindows), S(IsWindowPathSelectClick), S(WindowPathSelect),
	S(TrackWindowProxyDrag), S(GetWindowEventTarget), S(FindWindow),
	{"NewWindowDefUPP", sh_DrawGrowIcon},
};
REGISTER(winshims)
