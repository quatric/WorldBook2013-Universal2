// List Manager: text lists with the standard LDEF and a vertical scroll bar.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "win.h"
#include "hmap.h"

void ev_drop_mouseups(void);

typedef struct { uint8_t *d; int n; int sel; } LCell;

typedef struct {
	uint32_t h;
	Win *win;
	Port *port;
	QRect view;
	QPoint csize;
	int rows, cols;
	LCell *cells;
	int top, left;          // the first visible row and column
	int vscroll, hscroll, grow;
	int active, drawing;
	int8_t selFlags;
	uint32_t click_tick;
	int last_r, last_c;
	int anchor_r;
} List;

static HMap lists;

static List *L(uint32_t h) { return hm_get(&lists, h); }

enum { SB = 15 };

static int vis_rows(List *l)
{
	int ch = l->csize.v > 0 ? l->csize.v : 16;
	return (l->view.bottom - l->view.top + ch - 1) / ch;
}
static int vis_cols(List *l)
{
	int cw = l->csize.h > 0 ? l->csize.h : 100;
	return (l->view.right - l->view.left + cw - 1) / cw;
}
static int full_rows(List *l)
{
	int ch = l->csize.v > 0 ? l->csize.v : 16;
	return (l->view.bottom - l->view.top) / ch;
}
static int max_top(List *l)
{
	int m = l->rows - full_rows(l);
	return m > 0 ? m : 0;
}

// the guest's ListRec
static void lsync(List *l)
{
	uint32_t p = HP(l->h);
	if (!p)
		return;
	PUTRECT(p, l->view);
	ST32(p + 8, l->port ? l->port->tok : 0);
	STPT(p + 12, (QPoint){0, 5});
	STPT(p + 16, l->csize);
	QRect vis = {(int16_t)l->top, (int16_t)l->left, (int16_t)(l->top + vis_rows(l)), (int16_t)(l->left + vis_cols(l))};
	if (vis.bottom > l->rows)
		vis.bottom = (int16_t)l->rows;
	if (vis.right > l->cols)
		vis.right = (int16_t)l->cols;
	PUTRECT(p + 20, vis);
	ST8(p + 36, (uint8_t)l->selFlags);
	ST8(p + 37, l->active ? 255 : 0);
	ST16(p + 56, (uint16_t)l->last_r);
	ST16(p + 58, (uint16_t)l->last_c);
	PUTRECT(p + 72, ((QRect){0, 0, (int16_t)l->rows, (int16_t)l->cols}));
}

static LCell *cell(List *l, int r, int c)
{
	if (r < 0 || c < 0 || r >= l->rows || c >= l->cols)
		return NULL;
	return &l->cells[r * l->cols + c];
}

static QRect sb_rect(List *l)
{
	return (QRect){(int16_t)(l->view.top - 1), (int16_t)(l->view.right - 1), (int16_t)(l->view.bottom + 1 - (l->grow ? SB - 1 : 0)), (int16_t)(l->view.right + SB - 1)};
}

static HIThemeTrackDrawInfo track(List *l)
{
	HIThemeTrackDrawInfo ti;
	memset(&ti, 0, sizeof ti);
	QRect r = sb_rect(l);
	ti.kind = kThemeMediumScrollBar;
	ti.bounds = CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top);
	ti.min = 0;
	ti.max = max_top(l);
	ti.value = l->top;
	ti.attributes = kThemeTrackShowThumb;
	ti.enableState = l->active && ti.max > 0 ? kThemeTrackActive : kThemeTrackInactive;
	ti.trackInfo.scrollbar.viewsize = full_rows(l);
	return ti;
}

static void draw_sb(List *l)
{
	if (!l->vscroll || !l->port || !l->drawing)
		return;
	HIThemeTrackDrawInfo ti = track(l);
	CGContextRef cg = qd_cg_begin(l->port);
	CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
	CGContextFillRect(cg, ti.bounds);
	HIThemeDrawTrack(&ti, NULL, cg, kHIThemeOrientationInverted);
	qd_cg_end(l->port);
	qd_dirty(l->port, sb_rect(l));
}

static QRect cell_rect(List *l, int r, int c)
{
	int t = l->view.top + (r - l->top) * l->csize.v, x = l->view.left + (c - l->left) * l->csize.h;
	return (QRect){(int16_t)t, (int16_t)x, (int16_t)(t + l->csize.v), (int16_t)(x + l->csize.h)};
}

static void draw_cell(List *l, int r, int c)
{
	Port *p = l->port;
	QRect cr = rect_sect(cell_rect(l, r, c), l->view);
	if (rect_empty(cr))
		return;
	LCell *ce = cell(l, r, c);
	Paint bg = {NULL, p->bg, p->bg, 8};
	static const uint8_t black[8] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
	bg.pat = black;
	bg.fg = (RGB16){0xffff, 0xffff, 0xffff};
	if (ce && ce->sel && l->active)
		bg.fg = p->hilite;
	else if (ce && ce->sel)
		bg.fg = (RGB16){0xd4d4, 0xd4d4, 0xd4d4};
	qd_fill_rect(p, cr, bg);
	if (!ce || !ce->n)
		return;
	QPoint save = p->pnLoc;
	RGB16 fg = p->fg;
	int asc, desc, wid, lead;
	qd_font_info(p, &asc, &desc, &wid, &lead);
	Rgn *clip = rgn_new();
	rgn_copy(clip, p->clip);
	rgn_sect_rect(p->clip, cr);
	p->pnLoc = (QPoint){(int16_t)(cr.top + (l->csize.v - asc - desc) / 2 + asc), (int16_t)(cell_rect(l, r, c).left + 5)};
	p->fg = (RGB16){0, 0, 0};
	qd_text_draw(p, ce->d, ce->n);
	rgn_copy(p->clip, clip);
	rgn_free(clip);
	p->fg = fg;
	p->pnLoc = save;
}

static void draw_all(List *l)
{
	if (!l->drawing || !l->port)
		return;
	Port *p = l->port;
	Paint white = {NULL, {0xffff, 0xffff, 0xffff}, {0xffff, 0xffff, 0xffff}, 8};
	static const uint8_t black[8] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
	white.pat = black;
	qd_fill_rect(p, l->view, white);
	for (int r = l->top; r < l->rows && r < l->top + vis_rows(l); r++)
		for (int c = l->left; c < l->cols && c < l->left + vis_cols(l); c++)
			draw_cell(l, r, c);
	draw_sb(l);
}

static void scroll_to(List *l, int top)
{
	int m = max_top(l);
	if (top > m)
		top = m;
	if (top < 0)
		top = 0;
	if (top != l->top) {
		l->top = top;
		lsync(l);
		draw_all(l);
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

static void track_sb(List *l, QPoint pt)
{
	HIThemeTrackDrawInfo ti = track(l);
	if (ti.max <= 0)
		return;
	CGPoint cp = CGPointMake(pt.h, pt.v);
	ControlPartCode part = 0;
	HIThemeHitTestTrack(&ti, &cp, &part);
	int page = full_rows(l) - 1;
	if (page < 1)
		page = 1;
	int start = l->top;
	uint32_t next = 0;
	for (;;) {
		QPoint m = mouse_local(l->port);
		if (part == kControlIndicatorPart) {
			CGPoint off = CGPointMake(0, m.v - pt.v);
			HIThemeTrackDrawInfo t0 = ti;
			t0.value = start;
			CGFloat rel = 0;
			HIThemeGetTrackThumbPositionFromOffset(&t0, &off, &rel);
			scroll_to(l, (int)lround(rel * ti.max));
		} else if (ev_ticks() >= next) {
			int d = part == kControlUpButtonPart ? -1 : part == kControlDownButtonPart ? 1
				: part == kControlPageUpPart ? -page : part == kControlPageDownPart ? page : 0;
			scroll_to(l, l->top + d);
			next = ev_ticks() + (next ? 3 : 18);
		}
		if (!ev_button_down())
			break;
		ev_pump(0.015);
	}
	ev_drop_mouseups();
}

// ---- shims ----------------------------------------------------------------------------------------

static void sh_LNew(PPC *c)
{
	// LNew(rView, dataBounds, cSize, proc, window, drawIt, hasGrow, scrollHoriz, scrollVert)
	List *l = calloc(1, sizeof *l);
	l->view = RECT(A(0));
	QRect db = RECT(A(1));
	l->rows = db.bottom - db.top;
	l->cols = db.right - db.left;
	if (l->rows < 0)
		l->rows = 0;
	if (l->cols < 0)
		l->cols = 0;
	l->csize = PT(A(2));
	l->win = WIN(A(4));
	l->port = l->win ? l->win->port : qd_port;
	l->drawing = A(5) & 0xff;
	l->grow = A(6) & 0xff;
	l->hscroll = A(7) & 0xff;
	l->vscroll = A(8) & 0xff;
	if (l->csize.h == 0)
		l->csize.h = (int16_t)(l->cols ? (l->view.right - l->view.left) / (l->cols ? l->cols : 1) : l->view.right - l->view.left);
	if (l->csize.v == 0) {
		int asc = 12, desc = 3, wid, lead = 1;
		if (l->port)
			qd_font_info(l->port, &asc, &desc, &wid, &lead);
		l->csize.v = (int16_t)(asc + desc + lead);
	}
	l->cells = calloc((size_t)(l->rows * l->cols) + 1, sizeof(LCell));
	l->active = 1;
	l->last_r = l->last_c = -1;
	l->h = NewHandleClearG(96);
	hm_put(&lists, l->h, l);
	lsync(l);
	draw_all(l);
	RET(l->h);
}
static void sh_LDispose(PPC *c)
{
	List *l = L(A(0));
	if (!l)
		return;
	for (int i = 0; i < l->rows * l->cols; i++)
		free(l->cells[i].d);
	free(l->cells);
	hm_del(&lists, l->h);
	DisposeHandleG(l->h);
	free(l);
}

static void resize(List *l, int rows, int cols, int at_r, int at_c, int nr, int nc)
{
	// rows/cols: the new dimensions; nr rows inserted at at_r, nc columns at at_c
	LCell *n = calloc((size_t)(rows * cols) + 1, sizeof(LCell));
	for (int r = 0; r < l->rows; r++)
		for (int c = 0; c < l->cols; c++) {
			int r2 = r >= at_r ? r + nr : r, c2 = c >= at_c ? c + nc : c;
			if (r2 >= 0 && r2 < rows && c2 >= 0 && c2 < cols)
				n[r2 * cols + c2] = l->cells[r * l->cols + c];
			else
				free(l->cells[r * l->cols + c].d);
		}
	free(l->cells);
	l->cells = n;
	l->rows = rows;
	l->cols = cols;
}

static void sh_LAddRow(PPC *c)
{
	// LAddRow(count, rowNum, list) -> the first row added
	List *l = L(A(2));
	int n = (int16_t)A(0), at = (int16_t)A(1);
	if (!l || n <= 0)
		return RET(0);
	if (at < 0 || at > l->rows)
		at = l->rows;
	resize(l, l->rows + n, l->cols ? l->cols : 1, at, 0, n, 0);
	lsync(l);
	draw_all(l);
	RET(at);
}
static void sh_LAddColumn(PPC *c)
{
	List *l = L(A(2));
	int n = (int16_t)A(0), at = (int16_t)A(1);
	if (!l || n <= 0)
		return RET(0);
	if (at < 0 || at > l->cols)
		at = l->cols;
	resize(l, l->rows, l->cols + n, 0, at, 0, n);
	lsync(l);
	draw_all(l);
	RET(at);
}
static void sh_LDelRow(PPC *c)
{
	// LDelRow(count, rowNum, list): count 0 deletes all
	List *l = L(A(2));
	int n = (int16_t)A(0), at = (int16_t)A(1);
	if (!l)
		return;
	if (n == 0) {
		at = 0;
		n = l->rows;
	}
	if (at < 0 || at >= l->rows)
		return;
	if (at + n > l->rows)
		n = l->rows - at;
	for (int r = at; r < at + n; r++)
		for (int k = 0; k < l->cols; k++)
			free(l->cells[r * l->cols + k].d);
	memmove(l->cells + at * l->cols, l->cells + (at + n) * l->cols, (size_t)(l->rows - at - n) * l->cols * sizeof(LCell));
	l->rows -= n;
	if (l->top > max_top(l))
		l->top = max_top(l);
	lsync(l);
	draw_all(l);
}
static void sh_LSetCell(PPC *c)
{
	// LSetCell(dataPtr, dataLen, LCell, list)
	List *l = L(A(3));
	if (!l)
		return;
	QPoint cp = PT(A(2));
	LCell *ce = cell(l, cp.v, cp.h);
	if (!ce)
		return;
	int n = (int16_t)A(1);
	if (n < 0)
		n = 0;
	free(ce->d);
	ce->d = malloc(n + 1);
	if (n)
		memcpy(ce->d, G(A(0)), n);
	ce->n = n;
	if (l->drawing && cp.v >= l->top && cp.v < l->top + vis_rows(l))
		draw_cell(l, cp.v, cp.h);
}
static void sh_LAddToCell(PPC *c)
{
	List *l = L(A(3));
	if (!l)
		return;
	QPoint cp = PT(A(2));
	LCell *ce = cell(l, cp.v, cp.h);
	if (!ce)
		return;
	int n = (int16_t)A(1);
	ce->d = realloc(ce->d, ce->n + n + 1);
	memcpy(ce->d + ce->n, G(A(0)), n);
	ce->n += n;
	if (l->drawing)
		draw_cell(l, cp.v, cp.h);
}
static void sh_LGetCell(PPC *c)
{
	// LGetCell(dataPtr, short *dataLen, LCell, list)
	List *l = L(A(3));
	QPoint cp = PT(A(2));
	LCell *ce = l ? cell(l, cp.v, cp.h) : NULL;
	int want = (int16_t)LD16(A(1));
	int n = ce ? (ce->n < want ? ce->n : want) : 0;
	if (n > 0)
		memcpy(G(A(0)), ce->d, n);
	ST16(A(1), (uint16_t)n);
}
static void sh_LCellSize(PPC *c)
{
	List *l = L(A(1));
	if (!l)
		return;
	l->csize = PT(A(0));
	lsync(l);
	draw_all(l);
}
static void sh_LSize(PPC *c)
{
	List *l = L(A(2));
	if (!l)
		return;
	l->view.right = (int16_t)(l->view.left + (int16_t)A(0));
	l->view.bottom = (int16_t)(l->view.top + (int16_t)A(1));
	if (l->top > max_top(l))
		l->top = max_top(l);
	lsync(l);
	draw_all(l);
}
static void sh_LScroll(PPC *c)
{
	List *l = L(A(2));
	if (l)
		scroll_to(l, l->top + (int16_t)A(1));
}
static void sh_LSetDrawingMode(PPC *c)
{
	List *l = L(A(1));
	if (!l)
		return;
	l->drawing = A(0) & 0xff;
	if (l->drawing)
		draw_all(l);
}
static void sh_LUpdate(PPC *c) { List *l = L(A(1)); if (l) { int d = l->drawing; l->drawing = 1; draw_all(l); l->drawing = d; } }
static void sh_LDraw(PPC *c) { List *l = L(A(1)); QPoint cp = PT(A(0)); if (l) draw_cell(l, cp.v, cp.h); }
static void sh_LActivate(PPC *c)
{
	List *l = L(A(1));
	if (!l)
		return;
	l->active = A(0) & 0xff;
	lsync(l);
	draw_all(l);
}
static void sh_LSetSelect(PPC *c)
{
	// LSetSelect(setIt, LCell, list)
	List *l = L(A(2));
	if (!l)
		return;
	QPoint cp = PT(A(1));
	LCell *ce = cell(l, cp.v, cp.h);
	if (!ce)
		return;
	int on = A(0) & 0xff;
	if (ce->sel != on) {
		ce->sel = on;
		if (l->drawing && cp.v >= l->top && cp.v < l->top + vis_rows(l))
			draw_cell(l, cp.v, cp.h);
	}
}
static void sh_LGetSelect(PPC *c)
{
	// LGetSelect(next, LCell *, list)
	List *l = L(A(2));
	if (!l)
		return RET(0);
	QPoint cp = LDPT(A(1));
	if (!(A(0) & 0xff)) {
		LCell *ce = cell(l, cp.v, cp.h);
		RET(ce && ce->sel);
		return;
	}
	int r = cp.v < 0 ? 0 : cp.v, k = cp.h < 0 ? 0 : cp.h;
	for (; r < l->rows; r++, k = 0)
		for (; k < l->cols; k++)
			if (l->cells[r * l->cols + k].sel) {
				STPT(A(1), ((QPoint){(int16_t)r, (int16_t)k}));
				RET(1);
				return;
			}
	RET(0);
}
static void sh_LNextCell(PPC *c)
{
	// LNextCell(hNext, vNext, LCell *, list)
	List *l = L(A(3));
	if (!l)
		return RET(0);
	QPoint cp = LDPT(A(2));
	int h = A(0) & 0xff, v = A(1) & 0xff;
	int r = cp.v, k = cp.h;
	if (h && k + 1 < l->cols)
		k++;
	else if (v && r + 1 < l->rows) {
		r++;
		if (h)
			k = 0;
	} else
		return RET(0);
	STPT(A(2), ((QPoint){(int16_t)r, (int16_t)k}));
	RET(1);
}
static void sh_LLastClick(PPC *c) { List *l = L(A(0)); RET(l ? (uint32_t)((uint16_t)l->last_r << 16 | (uint16_t)l->last_c) : 0xffffffffu); }

static void select_only(List *l, int r0, int r1, int col)
{
	for (int r = 0; r < l->rows; r++)
		for (int k = 0; k < l->cols; k++) {
			LCell *ce = &l->cells[r * l->cols + k];
			int on = r >= r0 && r <= r1 && (k == col || l->cols == 1);
			if (ce->sel != on) {
				ce->sel = on;
				if (l->drawing && r >= l->top && r < l->top + vis_rows(l))
					draw_cell(l, r, k);
			}
		}
}

static void sh_LClick(PPC *c)
{
	// LClick(Point, modifiers, list) -> double click
	List *l = L(A(2));
	if (!l)
		return RET(0);
	QPoint pt = PT(A(0));
	uint16_t mods = (uint16_t)A(1);
	QRect sb = sb_rect(l);
	if (l->vscroll && pt.h >= sb.left && pt.h < sb.right && pt.v >= sb.top && pt.v < sb.bottom) {
		track_sb(l, pt);
		return RET(0);
	}
	if (pt.h < l->view.left || pt.h >= l->view.right || pt.v < l->view.top || pt.v >= l->view.bottom)
		return RET(0);
	int only = l->selFlags & 0x80;
	int r = l->top + (pt.v - l->view.top) / l->csize.v, k = l->left + (pt.h - l->view.left) / l->csize.h;
	uint32_t now = ev_ticks();
	int dbl = r == l->last_r && k == l->last_c && now - l->click_tick < (uint32_t)(NSEvent.doubleClickInterval * 60);
	l->click_tick = now;
	int toggle = !only && (mods & 0x100);
	int extend = !only && (mods & 0x200) && l->last_r >= 0;
	if (r >= l->rows || k >= l->cols) {
		if (!(l->selFlags & 0x02) && !toggle && !extend)
			select_only(l, -1, -2, 0);
		l->last_r = l->last_c = -1;
		lsync(l);
		win_flush_all();
		ev_drop_mouseups();
		return RET(0);
	}
	int anchor = extend ? l->anchor_r : r;
	int tog_on = 0;
	if (toggle) {
		LCell *ce = cell(l, r, k);
		tog_on = !ce->sel;
		ce->sel = tog_on;
		draw_cell(l, r, k);
	} else if (extend)
		select_only(l, anchor < r ? anchor : r, anchor < r ? r : anchor, k);
	else
		select_only(l, r, r, k);
	if (!extend)
		l->anchor_r = r;
	win_flush_all();
	int cur = r;
	while (ev_button_down()) {
		ev_pump(0.015);
		QPoint m = mouse_local(l->port);
		int rr = l->top + (m.v - l->view.top) / l->csize.v;
		if (m.v < l->view.top && l->top > 0) {
			scroll_to(l, l->top - 1);
			rr = l->top;
		} else if (m.v >= l->view.bottom && l->top < max_top(l)) {
			scroll_to(l, l->top + 1);
			rr = l->top + full_rows(l) - 1;
		}
		if (rr < 0)
			rr = 0;
		if (rr >= l->rows)
			rr = l->rows - 1;
		if (rr == cur)
			continue;
		cur = rr;
		if (toggle) {
			LCell *ce = cell(l, rr, k);
			if (ce && ce->sel != tog_on) {
				ce->sel = tog_on;
				draw_cell(l, rr, k);
			}
		} else if (only)
			select_only(l, rr, rr, k);
		else
			select_only(l, anchor < rr ? anchor : rr, anchor < rr ? rr : anchor, k);
		win_flush_all();
	}
	ev_drop_mouseups();
	l->last_r = cur;
	l->last_c = k;
	lsync(l);
	RET(dbl);
}
static void sh_GetListViewBounds(PPC *c)
{
	List *l = L(A(0));
	if (l && A(1))
		PUTRECT(A(1), l->view);
	RET(A(1));
}
static void sh_GetListVerticalScrollBar(PPC *c) { (void)c; RET(0); }
static void sh_GetListHorizontalScrollBar(PPC *c) { (void)c; RET(0); }
static void sh_SetListSelectionFlags(PPC *c) { List *l = L(A(0)); if (l) { l->selFlags = (int8_t)A(1); lsync(l); } }
static void sh_GetListSelectionFlags(PPC *c) { List *l = L(A(0)); RET(l ? (uint8_t)l->selFlags : 0); }
static void sh_GetListDataBounds(PPC *c) { List *l = L(A(0)); if (l) PUTRECT(A(1), ((QRect){0, 0, (int16_t)l->rows, (int16_t)l->cols})); RET(A(1)); }
static void sh_GetListVisibleCells(PPC *c) { List *l = L(A(0)); if (l) { lsync(l); PUTRECT(A(1), RECT(HP(l->h) + 20)); } RET(A(1)); }
static void sh_GetListCellSize(PPC *c) { List *l = L(A(0)); if (l) STPT(A(1), l->csize); RET(A(1)); }
static void sh_SetListRefCon(PPC *c) { List *l = L(A(0)); if (l) ST32(HP(l->h) + 60, A(1)); }
static void sh_GetListRefCon(PPC *c) { List *l = L(A(0)); RET(l ? LD32(HP(l->h) + 60) : 0); }
static void sh_GetListActive(PPC *c) { List *l = L(A(0)); RET(l && l->active); }

// the guest may change the selection flags in the ListRec directly
__attribute__((unused)) static void pull(List *l) { l->selFlags = (int8_t)LD8(HP(l->h) + 36); }

static void sh_LClickWrapper(PPC *c)
{
	List *l = L(A(2));
	if (l)
		pull(l);
	sh_LClick(c);
}

static const ShimDef listshims[] = {
	S(LNew), S(LDispose), S(LAddRow), S(LAddColumn), S(LDelRow), S(LSetCell), S(LAddToCell), S(LGetCell),
	S(LCellSize), S(LSize), S(LScroll), S(LSetDrawingMode), S(LUpdate), S(LDraw), S(LActivate), S(LSetSelect),
	S(LGetSelect), S(LNextCell), S(LLastClick), {"LClick", sh_LClickWrapper}, S(GetListViewBounds),
	S(GetListVerticalScrollBar), S(GetListHorizontalScrollBar), S(SetListSelectionFlags), S(GetListSelectionFlags),
	S(GetListDataBounds), S(GetListVisibleCells), S(GetListCellSize), S(SetListRefCon), S(GetListRefCon),
	S(GetListActive),
};
REGISTER(listshims)
