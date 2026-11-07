// Multilingual Text Engine (MLTE) on the text engine of te.m.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "te.h"
#include "win.h"

void ev_drop_mouseups(void);
int scrap_get(uint32_t type, void **out, uint32_t *n);

typedef struct {
	uint32_t tok;
	TEng *e;
	Win *win;
	QRect frame;
	uint32_t options;
	int vscroll, hscroll, grow;
	int focused, active;
	int readonly, noselect, single;
	uint32_t refcon;
} Txn;

static Txn *T(uint32_t tok) { return tok_get(tok, 'XLtx'); }

enum { SB = 15 };

static QRect sb_rect(Txn *t)
{
	return (QRect){t->frame.top, (int16_t)(t->frame.right - SB), (int16_t)(t->frame.bottom - (t->grow ? SB : 0)), t->frame.right};
}

static void layout_rects(Txn *t)
{
	QRect view = t->frame;
	if (t->vscroll)
		view.right -= SB;
	if (t->hscroll || t->grow)
		view.bottom -= t->hscroll ? SB : 0;
	int top_off = t->e ? t->e->view.top - t->e->dest.top : 0;
	QRect dest = view;
	dest.top = (int16_t)(view.top - top_off);
	dest.bottom = 32000;
	if (!t->e->wrap)
		dest.right = 32000;
	t->e->dest = dest;
	t->e->view = view;
	te_layout(t->e);
}

static int scroll_max(Txn *t)
{
	int h = te_total_height(t->e), vh = t->e->view.bottom - t->e->view.top;
	return h > vh ? h - vh : 0;
}

static HIThemeTrackDrawInfo track(Txn *t)
{
	HIThemeTrackDrawInfo ti;
	memset(&ti, 0, sizeof ti);
	QRect r = sb_rect(t);
	ti.kind = kThemeMediumScrollBar;
	ti.bounds = CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top);
	ti.min = 0;
	ti.max = scroll_max(t);
	ti.value = t->e->view.top - t->e->dest.top;
	ti.attributes = kThemeTrackShowThumb;
	ti.enableState = t->active && ti.max > 0 ? kThemeTrackActive : kThemeTrackInactive;
	ti.trackInfo.scrollbar.viewsize = t->e->view.bottom - t->e->view.top;
	return ti;
}

static void draw_sb(Txn *t)
{
	if (!t->vscroll || !t->e->port)
		return;
	Port *p = t->e->port;
	QRect r = sb_rect(t);
	HIThemeTrackDrawInfo ti = track(t);
	CGContextRef cg = qd_cg_begin(p);
	CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
	CGContextFillRect(cg, ti.bounds);
	HIThemeDrawTrack(&ti, NULL, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
}

static void draw_all(Txn *t)
{
	if (!t->e->port)
		return;
	te_draw(t->e, NULL);
	draw_sb(t);
}

static void on_change(TEng *e)
{
	Txn *t = e->owner;
	if (t)
		draw_sb(t);
}

static void scroll_to(Txn *t, int v)
{
	int max = scroll_max(t);
	if (v > max)
		v = max;
	if (v < 0)
		v = 0;
	int cur = t->e->view.top - t->e->dest.top;
	if (v != cur) {
		t->e->dest = rect_off(t->e->dest, 0, cur - v);
		draw_all(t);
		win_flush_all();
	}
}

static QPoint mouse_local(Port *p)
{
	QPoint g = ev_mouse_global();
	if (p->win) {
		QPoint o = win_origin(p->win);
		g.h = (int16_t)(g.h - o.h + p->portRect.left);
		g.v = (int16_t)(g.v - o.v + p->portRect.top);
	}
	return g;
}

static void track_sb(Txn *t, QPoint pt)
{
	HIThemeTrackDrawInfo ti = track(t);
	if (ti.max <= 0)
		return;
	CGPoint cp = CGPointMake(pt.h, pt.v);
	ControlPartCode part = 0;
	HIThemeHitTestTrack(&ti, &cp, &part);
	int line = t->e->lh && t->e->nl ? t->e->lh[0] : 16;
	int page = (t->e->view.bottom - t->e->view.top) - line;
	if (page < line)
		page = line;
	int start = ti.value;
	uint32_t next = 0;
	while (1) {
		QPoint m = mouse_local(t->e->port);
		int cur = t->e->view.top - t->e->dest.top;
		if (part == kControlIndicatorPart) {
			CGPoint off = CGPointMake(0, m.v - pt.v);
			HIThemeTrackDrawInfo t0 = ti;
			t0.value = start;
			CGFloat rel = 0;
			HIThemeGetTrackThumbPositionFromOffset(&t0, &off, &rel);
			scroll_to(t, (int)lround(rel * ti.max));
		} else if (ev_ticks() >= next) {
			int d = part == kControlUpButtonPart ? -line : part == kControlDownButtonPart ? line
				: part == kControlPageUpPart ? -page : part == kControlPageDownPart ? page : 0;
			scroll_to(t, cur + d);
			next = ev_ticks() + (next ? 3 : 18);
		}
		if (!ev_button_down())
			break;
		ev_pump(0.015);
	}
	ev_drop_mouseups();
}

// ---- data -------------------------------------------------------------------------------------------

static void range(Txn *t, uint32_t *a, uint32_t *b)
{
	if (*a == 0xffffffffu) {
		*a = (uint32_t)t->e->selStart;
		*b = (uint32_t)t->e->selEnd;
	}
	if (*b > (uint32_t)t->e->n)
		*b = (uint32_t)t->e->n;
	if (*a > *b)
		*a = *b;
}

static NSData *to_mac(uint32_t type, const void *d, uint32_t n)
{
	if (type == 'utxt' || type == 'ustr') {
		NSString *s = [[NSString alloc] initWithBytes:d length:n encoding:NSUTF16BigEndianStringEncoding];
		s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
		return [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
	}
	return [NSData dataWithBytes:d length:n];
}

static void set_data(Txn *t, uint32_t type, const void *d, uint32_t n, uint32_t a, uint32_t b)
{
	range(t, &a, &b);
	NSData *md = to_mac(type, d, n);
	if (!md)
		md = [NSData data];
	if (a == 0 && b == (uint32_t)t->e->n) {
		te_set_text(t->e, md.bytes, (int)md.length);
		t->e->selStart = t->e->selEnd = t->e->anchor = 0;
		layout_rects(t);
	} else {
		te_set_select(t->e, (int)a, (int)b);
		te_delete_sel(t->e);
		te_insert(t->e, md.bytes, (int)md.length, NULL, 0);
	}
}

// ---- shims -------------------------------------------------------------------------------------------

static void sh_TXNInitTextension(PPC *c) { (void)c; RET(0); }
static void sh_TXNTerminateTextension(PPC *c) { (void)c; }
static void sh_TXNVersionInformation(PPC *c) { if (A(0)) ST32(A(0), 0x7); RET(0x01600000); }

static void sh_TXNNewObject(PPC *c)
{
	// TXNNewObject(fileSpec, window, frame, frameOptions, frameType, fileType, encoding, &obj, &frameID, refcon)
	Txn *t = calloc(1, sizeof *t);
	t->win = WIN(A(1));
	Port *p = t->win ? t->win->port : qd_port;
	t->frame = A(2) ? RECT(A(2)) : (p ? p->portRect : (QRect){0, 0, 100, 100});
	t->options = A(3);
	t->vscroll = (t->options >> 28) & 1;
	t->hscroll = 0;
	t->grow = (t->options >> 20) & 1;
	t->readonly = (t->options >> 5) & 1;
	t->noselect = (t->options >> 7) & 1;
	t->single = (t->options >> 14) & 1;
	t->refcon = A(9);
	int mono = (t->options >> 17) & 1;
	t->e = te_create(p, t->frame, t->frame, !mono);
	t->e->owner = t;
	t->e->on_change = on_change;
	t->e->readonly = t->readonly;
	t->e->has_bg = 1;
	t->e->bg = (RGB16){0xffff, 0xffff, 0xffff};
	t->e->font = 0;
	t->e->size = 12;
	t->e->face = 0;
	t->e->color = (RGB16){0, 0, 0};
	te_restyle_all(t->e);
	layout_rects(t);
	t->tok = tok_new(t, 16, 'XLtx');
	ST32(A(7), t->tok);
	if (A(8))
		ST32(A(8), 1);
	RET(0);
}
static void sh_TXNDeleteObject(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	tok_free(t->tok);
	te_dispose(t->e);
	free(t);
}
static void sh_TXNSetData(PPC *c)
{
	// TXNSetData(obj, type, data, size, start, end)
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	set_data(t, A(1), A(2) ? G(A(2)) : "", A(3), A(4), A(5));
	draw_all(t);
	RET(0);
}
static void sh_TXNGetDataEncoded(PPC *c)
{
	// TXNGetDataEncoded(obj, start, end, Handle *, encoding)
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	uint32_t a = A(1), b = A(2);
	range(t, &a, &b);
	uint32_t type = A(4);
	NSData *d;
	if (type == 'utxt' || type == 'ustr') {
		NSString *s = mac_ns(t->e->t + a, b - a);
		d = [s dataUsingEncoding:NSUTF16BigEndianStringEncoding];
		if (!d)
			d = [NSData data];
	} else
		d = [NSData dataWithBytes:t->e->t + a length:b - a];
	ST32(A(3), NewHandleFrom(d.bytes, (uint32_t)d.length));
	RET(0);
}
static void sh_TXNDataSize(PPC *c) { Txn *t = T(A(0)); RET(t ? (uint32_t)t->e->n * 2 : 0); }
static void sh_TXNGetSelection(PPC *c)
{
	Txn *t = T(A(0));
	if (A(1))
		ST32(A(1), t ? (uint32_t)t->e->selStart : 0);
	if (A(2))
		ST32(A(2), t ? (uint32_t)t->e->selEnd : 0);
}
static void sh_TXNSetSelection(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	uint32_t a = A(1), b = A(2);
	if (a > (uint32_t)t->e->n)
		a = (uint32_t)t->e->n;
	if (b > (uint32_t)t->e->n)
		b = (uint32_t)t->e->n;
	te_set_select(t->e, (int)a, (int)b);
	te_sel_view(t->e);
	draw_all(t);
	RET(0);
}
static void sh_TXNSelectAll(PPC *c) { Txn *t = T(A(0)); if (t) { te_set_select(t->e, 0, t->e->n); draw_all(t); } }
static void sh_TXNIsSelectionEmpty(PPC *c) { Txn *t = T(A(0)); RET(!t || t->e->selStart == t->e->selEnd); }
static void sh_TXNClick(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	uint32_t ev = A(1);
	QPoint g = LDPT(ev + 10);
	Port *p = t->e->port;
	QPoint l = g;
	if (p && p->win) {
		QPoint o = win_origin(p->win);
		l.h = (int16_t)(g.h - o.h + p->portRect.left);
		l.v = (int16_t)(g.v - o.v + p->portRect.top);
	}
	QRect sb = sb_rect(t);
	if (t->vscroll && l.h >= sb.left && l.h < sb.right && l.v >= sb.top && l.v < sb.bottom) {
		track_sb(t, l);
		return;
	}
	if (t->noselect)
		return;
	te_click(t->e, l, (LD16(ev + 14) & 0x200) != 0);
}
static void sh_TXNKeyDown(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	uint32_t ev = A(1);
	uint8_t ch = (uint8_t)LD32(ev + 2);
	uint16_t mods = LD16(ev + 14);
	if (t->single && (ch == 13 || ch == 3))
		return;
	if (ch == 11 || ch == 12) {   // page up/down
		int page = t->e->view.bottom - t->e->view.top;
		scroll_to(t, t->e->view.top - t->e->dest.top + (ch == 11 ? -page : page));
		return;
	}
	if (ch == 1 || ch == 4) {     // home/end
		scroll_to(t, ch == 1 ? 0 : scroll_max(t));
		return;
	}
	te_key(t->e, ch, mods);
	draw_sb(t);
}
static void sh_TXNAdjustCursor(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	Port *p = t->e->port;
	if (!p)
		return;
	QPoint m = mouse_local(p);
	QRect v = t->e->view;
	if (!t->noselect && m.h >= v.left && m.h < v.right && m.v >= v.top && m.v < v.bottom)
		[NSCursor.IBeamCursor set];
}
static void sh_TXNFocus(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	t->focused = A(1) & 0xff;
	te_activate(t->e, t->focused && !t->noselect);
}
static void sh_TXNActivate(PPC *c)
{
	// TXNActivate(obj, frameID, scrollBarState)
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	t->active = A(2) & 0xff;
	draw_sb(t);
	RET(0);
}
static void sh_TXNDraw(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	if (A(1)) {
		Port *save = t->e->port;
		t->e->port = PORT(A(1));
		draw_all(t);
		t->e->port = save;
	} else
		draw_all(t);
}
static void sh_TXNForceUpdate(PPC *c) { Txn *t = T(A(0)); if (t) draw_all(t); }
static void sh_TXNUpdate(PPC *c) { Txn *t = T(A(0)); if (t) draw_all(t); }
static void sh_TXNCut(PPC *c)
{
	Txn *t = T(A(0));
	if (!t || t->readonly)
		return RET(0);
	te_copy(t->e);
	te_snapshot(t->e);
	te_delete_sel(t->e);
	draw_all(t);
	RET(0);
}
static void sh_TXNCopy(PPC *c) { Txn *t = T(A(0)); if (t) te_copy(t->e); RET(0); }
static void sh_TXNPaste(PPC *c)
{
	Txn *t = T(A(0));
	if (!t || t->readonly)
		return RET(0);
	te_paste(t->e);
	draw_sb(t);
	RET(0);
}
static void sh_TXNClear(PPC *c)
{
	Txn *t = T(A(0));
	if (!t || t->readonly)
		return RET(0);
	te_snapshot(t->e);
	te_delete_sel(t->e);
	draw_all(t);
	RET(0);
}
static void sh_TXNUndo(PPC *c) { Txn *t = T(A(0)); if (t && !t->e->redo) { te_undo(t->e); draw_sb(t); } }
static void sh_TXNRedo(PPC *c) { Txn *t = T(A(0)); if (t && t->e->redo) { te_undo(t->e); draw_sb(t); } }
static void sh_TXNCanUndo(PPC *c)
{
	Txn *t = T(A(0));
	if (A(1))
		ST32(A(1), 1);   // kTXNTypingAction
	RET(t && t->e->has_undo && !t->e->redo);
}
static void sh_TXNCanRedo(PPC *c)
{
	Txn *t = T(A(0));
	if (A(1))
		ST32(A(1), 1);
	RET(t && t->e->has_undo && t->e->redo);
}
static void sh_TXNIsScrapPastable(PPC *c)
{
	(void)c;
	void *d;
	uint32_t n;
	int ok = scrap_get('TEXT', &d, &n);
	if (ok)
		free(d);
	RET(ok);
}
static void sh_TXNConvertToPublicScrap(PPC *c) { (void)c; RET(0); }
static void sh_TXNConvertFromPublicScrap(PPC *c) { (void)c; RET(0); }
static void sh_TXNGetLineMetrics(PPC *c)
{
	// TXNGetLineMetrics(obj, line, Fixed *width, Fixed *height)
	Txn *t = T(A(0));
	int l = (int)A(1);
	if (!t || l < 0 || l >= t->e->nl)
		return RET(-50);
	if (A(2))
		ST32(A(2), (uint32_t)(int32_t)(te_line_width(t->e, l) * 65536));
	if (A(3))
		ST32(A(3), (uint32_t)(t->e->lh[l] << 16));
	RET(0);
}
static void sh_TXNGetViewRect(PPC *c) { Txn *t = T(A(0)); if (t) PUTRECT(A(1), t->e->view); }
static void sh_TXNSetViewRect(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return;
	QRect r = RECT(A(1));
	t->frame = r;
	if (t->vscroll)
		t->frame.right += SB;
	layout_rects(t);
}
static void sh_TXNSetFrameBounds(PPC *c)
{
	// TXNSetFrameBounds(obj, top, left, bottom, right, frameID)
	Txn *t = T(A(0));
	if (!t)
		return;
	t->frame = (QRect){(int16_t)A(1), (int16_t)A(2), (int16_t)A(3), (int16_t)A(4)};
	layout_rects(t);
}
static void sh_TXNSetBackground(PPC *c)
{
	Txn *t = T(A(0));
	uint32_t b = A(1);
	if (!t || !b)
		return RET(0);
	if (LD32(b) == 1) {   // kTXNBackgroundTypeRGB
		t->e->bg = (RGB16){LD16(b + 4), LD16(b + 6), LD16(b + 8)};
		t->e->has_bg = 1;
	}
	RET(0);
}

static void sh_TXNSetTXNObjectControls(PPC *c)
{
	// TXNSetTXNObjectControls(obj, clearAll, count, tags[], data[])
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	uint32_t n = A(2), tags = A(3), data = A(4);
	int relayout = 0;
	for (uint32_t i = 0; i < n; i++) {
		uint32_t tag = LD32(tags + 4 * i), v = LD32(data + 4 * i);
		switch (tag) {
		case 'wwrs': t->e->wrap = v == 0; relayout = 1; break;
		case 'just': t->e->just = v == 4 ? 1 : v == 2 ? -1 : 0; relayout = 1; break;
		case 'iopv': t->readonly = v != 0; t->e->readonly = t->readonly; break;
		case 'nsel': t->noselect = v != 0; break;
		default: break;
		}
	}
	if (relayout)
		layout_rects(t);
	RET(0);
}
static void sh_TXNGetTXNObjectControls(PPC *c)
{
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	uint32_t n = A(1), tags = A(2), data = A(3);
	for (uint32_t i = 0; i < n; i++) {
		uint32_t tag = LD32(tags + 4 * i), v = 0;
		switch (tag) {
		case 'wwrs': v = t->e->wrap ? 0 : 1; break;
		case 'just': v = t->e->just == 1 ? 4 : t->e->just == -1 ? 2 : 0; break;
		case 'iopv': v = t->readonly; break;
		default: break;
		}
		ST32(data + 4 * i, v);
	}
	RET(0);
}

static void sh_TXNSetTypeAttributes(PPC *c)
{
	// TXNSetTypeAttributes(obj, count, TXNTypeAttributes[], start, end)
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	uint32_t n = A(1), at = A(2), a = A(3), b = A(4);
	range(t, &a, &b);
	int mode = 0, font = 0, face = 0, size = 0;
	RGB16 col = {0, 0, 0};
	for (uint32_t i = 0; i < n; i++) {
		uint32_t tag = LD32(at + 12 * i), v = LD32(at + 12 * i + 8);
		switch (tag) {
		case 'fntf': mode |= 1; font = (int16_t)v; break;
		case 'font': {
			NSString *nm = pstr_ns(v);
			mode |= 1;
			font = qd_font_num(nm);
			break;
		}
		case 'face': mode |= 2; face = (int)(v & 0xff); break;
		case 'size': mode |= 4; size = (int)((int32_t)v >> 16); break;
		case 'klor': mode |= 8; col = (RGB16){LD16(v), LD16(v + 2), LD16(v + 4)}; break;
		default: break;
		}
	}
	int s0 = t->e->selStart, s1 = t->e->selEnd;
	t->e->selStart = (int)a;
	t->e->selEnd = (int)b;
	if (a == 0 && b == (uint32_t)t->e->n) {
		// the whole text: also the style of typing into an empty text
		if (mode & 1) t->e->font = font;
		if (mode & 2) t->e->face = face;
		if (mode & 4) t->e->size = size;
		if (mode & 8) t->e->color = col;
	}
	if (a == b && t->e->n == 0) {
		te_restyle_all(t->e);
		for (int i = 0; i < t->e->nruns; i++)
			t->e->runs[i].color = t->e->color;
	} else
		te_set_style(t->e, mode, font, face, size, col, 0);
	t->e->selStart = s0;
	t->e->selEnd = s1;
	te_layout(t->e);
	RET(0);
}
static void sh_TXNGetContinuousTypeAttributes(PPC *c)
{
	// TXNGetContinuousTypeAttributes(obj, &flags, count, TXNTypeAttributes[])
	Txn *t = T(A(0));
	if (!t)
		return RET(-50);
	int mode = 15;
	TRun r;
	te_continuous(t->e, &mode, &r);
	uint32_t flags = 0;
	if (mode & 1) flags |= 1;
	if (mode & 4) flags |= 2;
	if (mode & 2) flags |= 4;
	if (mode & 8) flags |= 8;
	if (A(1))
		ST32(A(1), flags);
	uint32_t n = A(2), at = A(3);
	for (uint32_t i = 0; i < n; i++) {
		uint32_t a = at + 12 * i;
		uint32_t tag = LD32(a);
		switch (tag) {
		case 'fntf': ST32(a + 8, (uint32_t)(uint16_t)r.font); break;
		case 'face': ST32(a + 8, r.face); break;
		case 'size': ST32(a + 8, (uint32_t)r.size << 16); break;
		case 'klor': { uint32_t p = LD32(a + 8); if (p) { ST16(p, r.color.r); ST16(p + 2, r.color.g); ST16(p + 4, r.color.b); } break; }
		case 'font': { uint32_t p = LD32(a + 8); if (p) ns_pstr(qd_font_name(r.font), p); break; }
		default: break;
		}
	}
	RET(0);
}

static const ShimDef txnshims[] = {
	S(TXNInitTextension), S(TXNTerminateTextension), S(TXNVersionInformation), S(TXNNewObject), S(TXNDeleteObject),
	S(TXNSetData), S(TXNGetDataEncoded), S(TXNDataSize), S(TXNGetSelection), S(TXNSetSelection), S(TXNSelectAll),
	S(TXNIsSelectionEmpty), S(TXNClick), S(TXNKeyDown), S(TXNAdjustCursor), S(TXNFocus), S(TXNActivate),
	S(TXNDraw), S(TXNForceUpdate), S(TXNUpdate), S(TXNCut), S(TXNCopy), S(TXNPaste), S(TXNClear), S(TXNUndo),
	S(TXNRedo), S(TXNCanUndo), S(TXNCanRedo), S(TXNIsScrapPastable), S(TXNConvertToPublicScrap),
	S(TXNConvertFromPublicScrap), S(TXNGetLineMetrics), S(TXNGetViewRect), S(TXNSetViewRect),
	S(TXNSetFrameBounds), S(TXNSetBackground), S(TXNSetTXNObjectControls), S(TXNGetTXNObjectControls),
	S(TXNSetTypeAttributes), S(TXNGetContinuousTypeAttributes),
};
REGISTER(txnshims)
