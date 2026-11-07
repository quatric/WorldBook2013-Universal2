// Event Manager: Cocoa events to classic EventRecords, WaitNextEvent, the
// mouse, ticks; the few Carbon Event Manager calls the wizards make.
#import <AppKit/AppKit.h>
#include <mach/mach_time.h>
#include "win.h"
#include "menu.h"

Ev ev_last;
static Ev queue[256];
static int qhead, qn;
static int mouse_down;
static uint32_t t0_ns_valid;
static uint64_t t0;

uint32_t ev_ticks(void)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom) {
		mach_timebase_info(&tb);
		t0 = mach_absolute_time();
		t0_ns_valid = 1;
	}
	uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
	return (uint32_t)(ns * 60 / 1000000000ull) + 600;
}

uint16_t ev_mac_modifiers(NSEventModifierFlags f)
{
	uint16_t m = 0;
	if (f & NSEventModifierFlagCommand)
		m |= 0x100;
	if (f & NSEventModifierFlagShift)
		m |= 0x200;
	if (f & NSEventModifierFlagCapsLock)
		m |= 0x400;
	if (f & NSEventModifierFlagOption)
		m |= 0x800;
	if (f & NSEventModifierFlagControl)
		m |= 0x1000;
	return m;
}

uint16_t ev_modifiers(void)
{
	uint16_t m = ev_mac_modifiers(NSEvent.modifierFlags);
	if (!ev_button_down())
		m |= 0x80;   // btnState: the button is up
	return m;
}

int script_mouse(QPoint *p);
int script_button(int *down);
void script_tick(void);

int ev_button_down(void)
{
	int d;
	if (script_button(&d))
		return d != 0;
	return (NSEvent.pressedMouseButtons & 1) != 0;
}

QPoint ev_mouse_global(void)
{
	QPoint sp;
	if (script_mouse(&sp))
		return sp;
	NSPoint p = NSEvent.mouseLocation;
	return (QPoint){(int16_t)qd_global_y(p.y), (int16_t)floor(p.x)};
}

void ev_post(Ev e)
{
	if (qn == 256)
		return;
	if (!e.when)
		e.when = ev_ticks();
	if (e.what == 1)
		mouse_down = 1;
	queue[(qhead + qn) % 256] = e;
	qn++;
}

// after a host-side tracking loop: the button was released there
void ev_drop_mouseups(void)
{
	for (int i = 0; i < qn; i++) {
		Ev *q = &queue[(qhead + i) % 256];
		if (q->what == 2)
			q->what = 0xffff;
	}
	mouse_down = 0;
}

void ev_post_mouse_part(Win *w, int part, uint32_t data)
{
	Ev e = {0};
	e.what = 1;
	e.where = ev_mouse_global();
	e.modifiers = ev_modifiers() & ~0x80;
	e.part = part;
	e.data = data;
	e.win = w;
	ev_post(e);
}

void ev_forget_window(Win *w)
{
	for (int i = 0; i < qn; i++) {
		Ev *e = &queue[(qhead + i) % 256];
		if (e->win == w) {
			e->what = 0xffff;   // dropped
			e->win = NULL;
		}
	}
	if (ev_last.win == w)
		ev_last.win = NULL;
}

void ev_activate(Win *w, int on)
{
	// replace a pending activate event for the window
	for (int i = 0; i < qn; i++) {
		Ev *e = &queue[(qhead + i) % 256];
		if (e->what == 8 && e->win == w)
			e->what = 0xffff;
	}
	Ev e = {0};
	e.what = 8;
	e.message = w->tok;
	e.modifiers = on ? 1 : 0;
	e.win = w;
	e.where = ev_mouse_global();
	ev_post(e);
}

static int app_active = 1;

static void watch_app(void)
{
	static int done;
	if (done)
		return;
	done = 1;
	[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil
		usingBlock:^(NSNotification *n) {
			(void)n;
			if (!app_active || getenv("PPC_SCRIPT"))   // scripted runs stay "in front"
				return;
			app_active = 0;
			Ev e = {0};
			e.what = 15;
			e.message = 0x01000000;   // suspend
			ev_post(e);
		}];
	[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil
		usingBlock:^(NSNotification *n) {
			(void)n;
			if (app_active)
				return;
			app_active = 1;
			Ev e = {0};
			e.what = 15;
			e.message = 0x01000001;   // resume
			ev_post(e);
		}];
}

// ---- Cocoa events --------------------------------------------------------------------------

int ev_pump(double wait)
{
	watch_app();
	menu_flush();
	static int scripted = -1;
	if (scripted < 0)
		scripted = getenv("PPC_SCRIPT") != NULL;
	if (scripted) {
		script_tick();
		if (wait > 0.03)
			wait = 0.03;
	}
	win_flush_all();
	int any = 0;
	NSDate *until = wait > 0 ? [NSDate dateWithTimeIntervalSinceNow:wait] : [NSDate distantPast];
	for (;;) {
		@autoreleasepool {
			NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
			if (!e)
				break;
			any = 1;
			if (e.type == NSEventTypeLeftMouseUp && mouse_down) {
				mouse_down = 0;
			}
			[NSApp sendEvent:e];
			if (e.type == NSEventTypeLeftMouseUp && !e.window) {
				// released outside our windows
			}
		}
		until = [NSDate distantPast];
		if (qn)
			break;
	}
	win_flush_all();
	return any;
}

void ev_scroll(Win *w, NSEvent *e)
{
	// as arrow keys in the window under the mouse (the wizards predate the scroll wheel)
	(void)w;
	double dy = e.scrollingDeltaY;
	if (e.hasPreciseScrollingDeltas)
		dy /= 10;
	int n = (int)lround(fabs(dy));
	if (n > 5)
		n = 5;
	for (int i = 0; i < n; i++) {
		Ev k = {0};
		k.what = 3;
		k.message = dy > 0 ? (30 | 0x7e00) : (31 | 0x7d00);
		k.where = ev_mouse_global();
		k.modifiers = 0x80;
		k.win = w;
		(void)k;
	}
}

static int take(uint16_t mask, Ev *out, int remove)
{
	for (int i = 0; i < qn; i++) {
		Ev *e = &queue[(qhead + i) % 256];
		if (e->what == 0xffff)
			continue;
		if (!(mask & (e->what == 23 ? 0x400 : 1 << e->what)))
			continue;
		*out = *e;
		if (remove) {
			// shift the rest down
			for (int k = i; k > 0; k--)
				queue[(qhead + k) % 256] = queue[(qhead + k - 1) % 256];
			qhead = (qhead + 1) % 256;
			qn--;
		}
		return 1;
	}
	// drop leading dropped entries
	while (qn && queue[qhead].what == 0xffff) {
		qhead = (qhead + 1) % 256;
		qn--;
	}
	return 0;
}

static int update_event(uint16_t mask, Ev *out)
{
	if (!(mask & (1 << 6)))
		return 0;
	for (Win *w = win_list(); w; w = w->next)
		if (w->visible && !rgn_empty(w->update)) {
			memset(out, 0, sizeof *out);
			out->what = 6;
			out->message = w->tok;
			out->win = w;
			return 1;
		}
	return 0;
}

static void write_event(uint32_t a, Ev *e)
{
	ST16(a, e->what);
	ST32(a + 2, e->message);
	ST32(a + 6, e->when ? e->when : ev_ticks());
	STPT(a + 10, e->where);
	ST16(a + 14, e->modifiers);
}

static int get_event(uint16_t mask, uint32_t evp, double wait)
{
	double deadline = CFAbsoluteTimeGetCurrent() + wait;
	for (;;) {
		ev_pump(0);
		Ev e;
		int got = take(mask, &e, 1) || update_event(mask, &e);
		if (got) {
			if (e.what == 8 && e.win)
				e.message = e.win->tok;
			if (!e.where.h && !e.where.v && e.what != 1)
				e.where = ev_mouse_global();
			if (e.what != 1 && e.what != 2 && e.what != 3 && e.what != 5)
				e.modifiers = ev_modifiers() | (e.what == 8 ? (e.modifiers & 1) : 0);
			ev_last = e;
			write_event(evp, &e);
			return 1;
		}
		double left = deadline - CFAbsoluteTimeGetCurrent();
		if (left <= 0)
			break;
		ev_pump(left > 0.5 ? 0.5 : left);
	}
	Ev n = {0};
	n.where = ev_mouse_global();
	n.modifiers = ev_modifiers();
	ev_last = n;
	write_event(evp, &n);
	return 0;
}

// ---- shims -----------------------------------------------------------------------------------

static void sh_WaitNextEvent(PPC *c)
{
	// WaitNextEvent(mask, EventRecord *, sleep ticks, mouseRgn)
	uint32_t sleep = A(2);
	double wait = sleep / 60.0;
	if (wait > 1)
		wait = 1;
	RET(get_event((uint16_t)A(0), A(1), wait));
}
static void sh_GetNextEvent(PPC *c) { RET(get_event((uint16_t)A(0), A(1), 0)); }
static void sh_StillDown(PPC *c)
{
	ev_pump(0);
	RET(ev_button_down());
}
static void sh_WaitMouseUp(PPC *c)
{
	ev_pump(0);
	RET(ev_button_down());
}
static void sh_WaitMouseMoved(PPC *c)
{
	// WaitMouseMoved(Point initialGlobalMouse): true once the mouse moves a few pixels with the button down
	QPoint s = PT(A(0));
	double end = CFAbsoluteTimeGetCurrent() + 0.5;
	while (ev_button_down() && CFAbsoluteTimeGetCurrent() < end) {
		QPoint m = ev_mouse_global();
		if (abs(m.h - s.h) > 2 || abs(m.v - s.v) > 2) {
			RET(1);
			return;
		}
		ev_pump(0.01);
	}
	RET(0);
}
static void sh_GetMouse(PPC *c)
{
	ev_pump(0);
	QPoint g = ev_mouse_global();
	Port *p = qd_port;
	if (p && p->win) {
		QPoint o = win_origin(p->win);
		g.h = (int16_t)(g.h - o.h + p->portRect.left);
		g.v = (int16_t)(g.v - o.v + p->portRect.top);
	}
	STPT(A(0), g);
}
static void sh_GetGlobalMouse(PPC *c) { STPT(A(0), ev_mouse_global()); }
static void sh_TickCount(PPC *c) { RET(ev_ticks()); }
static void sh_GetDblTime(PPC *c) { RET((uint32_t)(NSEvent.doubleClickInterval * 60)); }
static void sh_GetCurrentKeyModifiers(PPC *c) { RET(ev_modifiers()); }
static void sh_Delay(PPC *c)
{
	uint32_t end = ev_ticks() + A(0);
	while (ev_ticks() < end)
		ev_pump(1 / 60.0);
	if (A(1))
		ST32(A(1), ev_ticks());
}
static void sh_FlushEvents(PPC *c) { (void)c; qn = 0; }
static void sh_SysBeep(PPC *c) { NSBeep(); }
static void sh_IsCmdChar(PPC *c)
{
	uint32_t e = A(0);
	RET((LD16(e + 14) & 0x100) && (LD32(e + 2) & 0xff) == (A(1) & 0xff));
}

// Carbon events: handlers are accepted; the classic event loop carries everything
typedef struct { uint32_t target, upp, n, types, user; } Handler;
static void sh_InstallEventHandler(PPC *c)
{
	// InstallEventHandler(target, handler, numTypes, list, userData, EventHandlerRef *)
	if (ppc_verbose)
		for (uint32_t i = 0; i < A(2) && i < 8; i++)
			ppc_log("InstallEventHandler: class '%.4s' kind %u", (char *)&(uint32_t){__builtin_bswap32(LD32(A(3) + 8 * i))},
				LD32(A(3) + 8 * i + 4));
	if (A(5))
		ST32(A(5), gcalloc(4));
	RET(0);
}
static void sh_CallNextEventHandler(PPC *c) { RET(-9874); }   // eventNotHandledErr
static void sh_GetEventParameter(PPC *c) { RET(-9870); }      // eventParameterNotFoundErr
static void sh_ConvertEventRefToEventRecord(PPC *c) { RET(0); }
static void sh_GetCurrentEventLoop(PPC *c) { RET(1); }
static void sh_GetApplicationEventTarget(PPC *c) { RET(2); }

static void sh_upp_keep(PPC *c) { (void)c; }

static const ShimDef evshims[] = {
	S(WaitNextEvent), S(GetNextEvent), S(StillDown), S(WaitMouseUp), S(WaitMouseMoved), S(GetMouse), S(GetGlobalMouse),
	S(TickCount), S(GetDblTime), S(GetCurrentKeyModifiers), S(Delay), S(FlushEvents), S(SysBeep), S(IsCmdChar),
	S(InstallEventHandler), S(CallNextEventHandler), S(GetEventParameter), S(ConvertEventRefToEventRecord),
	S(GetCurrentEventLoop), S(GetApplicationEventTarget), {"NewEventHandlerUPP", sh_upp_keep},
};
REGISTER(evshims)
