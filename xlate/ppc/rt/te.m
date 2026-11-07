// The text engine and TextEdit (see te.h).
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include "te.h"
#include "win.h"
#include "hmap.h"

void ev_drop_mouseups(void);
void scrap_put(uint32_t type, const void *d, uint32_t n);
int scrap_get(uint32_t type, void **out, uint32_t *n);

static unichar mac2uni[256];

static void init_tables(void)
{
	static int done;
	if (done)
		return;
	done = 1;
	for (int i = 0; i < 256; i++) {
		uint8_t b = (uint8_t)i;
		CFStringRef s = CFStringCreateWithBytes(NULL, &b, 1, kCFStringEncodingMacRoman, false);
		mac2uni[i] = s && CFStringGetLength(s) ? CFStringGetCharacterAtIndex(s, 0) : '?';
		if (s)
			CFRelease(s);
	}
}

// ---- style metrics -------------------------------------------------------------------------------

typedef struct { double adv[256]; int asc, desc, lead; } Metrics;
static NSMutableDictionary *metrics_cache;

static Metrics *metrics(int font, int size, int face)
{
	init_tables();
	if (size <= 0)
		size = 12;
	NSNumber *key = @(((long)font << 24) ^ ((long)size << 8) ^ face);
	if (!metrics_cache)
		metrics_cache = [NSMutableDictionary new];
	NSData *d = metrics_cache[key];
	if (d)
		return (Metrics *)d.bytes;
	NSMutableData *md = [NSMutableData dataWithLength:sizeof(Metrics)];
	Metrics *m = md.mutableBytes;
	CTFontRef f = qd_font(font, size, face);
	CGGlyph g[256];
	CGSize a[256];
	unichar u[256];
	for (int i = 0; i < 256; i++)
		u[i] = mac2uni[i];
	u[9] = ' ';
	for (int i = 0; i < 256; i++) {
		if (!CTFontGetGlyphsForCharacters(f, &u[i], &g[i], 1))
			g[i] = 0;
	}
	CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, g, a, 256);
	for (int i = 0; i < 256; i++)
		m->adv[i] = g[i] ? a[i].width : 0;
	m->adv[9] = m->adv[' '] * 4;
	m->adv[13] = 0;
	if (face & 0x20)
		for (int i = 0; i < 256; i++)
			m->adv[i] -= 1;
	if (face & 0x40)
		for (int i = 0; i < 256; i++)
			m->adv[i] += 1;
	m->asc = (int)ceil(CTFontGetAscent(f));
	m->desc = (int)ceil(CTFontGetDescent(f));
	m->lead = (int)lround(CTFontGetLeading(f));
	metrics_cache[key] = md;
	return m;
}

void te_style_metrics(TRun *r, int *asc, int *desc, int *lead)
{
	Metrics *m = metrics(r->font, r->size, r->face);
	*asc = m->asc;
	*desc = m->desc;
	*lead = m->lead;
}

// ---- runs ----------------------------------------------------------------------------------------

static TRun base_style(TEng *e)
{
	TRun r = {0, (int16_t)e->font, (int16_t)(e->size ? e->size : 12), (uint8_t)e->face, e->color};
	return r;
}

static int run_at(TEng *e, int off)
{
	int lo = 0, hi = e->nruns - 1;
	while (lo < hi) {
		int m = (lo + hi + 1) / 2;
		if (e->runs[m].start <= off)
			lo = m;
		else
			hi = m - 1;
	}
	return lo;
}

TRun te_style_at(TEng *e, int off)
{
	if (!e->nruns)
		return base_style(e);
	return e->runs[run_at(e, off)];
}

static void runs_reserve(TEng *e, int n)
{
	if (n > e->capruns) {
		e->capruns = n * 2;
		e->runs = realloc(e->runs, e->capruns * sizeof *e->runs);
	}
}

static int same_style(const TRun *a, const TRun *b)
{
	return a->font == b->font && a->size == b->size && a->face == b->face && !memcmp(&a->color, &b->color, sizeof a->color);
}

static void runs_normalize(TEng *e)
{
	if (!e->nruns) {
		runs_reserve(e, 1);
		e->runs[0] = base_style(e);
		e->nruns = 1;
	}
	e->runs[0].start = 0;
	int k = 0;
	for (int i = 1; i < e->nruns; i++) {
		if (e->runs[i].start >= e->n && e->n > 0)
			continue;
		if (e->runs[i].start <= e->runs[k].start) {
			e->runs[k] = (TRun){e->runs[k].start, e->runs[i].font, e->runs[i].size, e->runs[i].face, e->runs[i].color};
			continue;
		}
		if (same_style(&e->runs[i], &e->runs[k]))
			continue;
		e->runs[++k] = e->runs[i];
	}
	e->nruns = k + 1;
}

// split so that a run starts at off
static int runs_split(TEng *e, int off)
{
	int i = run_at(e, off);
	if (e->runs[i].start == off)
		return i;
	runs_reserve(e, e->nruns + 1);
	memmove(e->runs + i + 2, e->runs + i + 1, (e->nruns - i - 1) * sizeof *e->runs);
	e->runs[i + 1] = e->runs[i];
	e->runs[i + 1].start = off;
	e->nruns++;
	return i + 1;
}

// ---- layout ---------------------------------------------------------------------------------------

static double char_adv(TEng *e, int off, int *ri)
{
	while (*ri + 1 < e->nruns && e->runs[*ri + 1].start <= off)
		(*ri)++;
	TRun *r = &e->runs[*ri];
	Metrics *m = metrics(r->font, r->size, r->face);
	uint8_t ch = e->password ? 0xa5 : e->t[off];
	return m->adv[ch];
}

static void lines_reserve(TEng *e, int n)
{
	if (n + 2 > e->capl) {
		e->capl = (n + 2) * 2;
		e->ls = realloc(e->ls, e->capl * sizeof(int));
		e->lh = realloc(e->lh, e->capl * sizeof(int));
		e->la = realloc(e->la, e->capl * sizeof(int));
	}
}

static void line_metrics(TEng *e, int l)
{
	int a = e->ls[l], b = e->ls[l + 1];
	int asc = 0, desc = 0, lead = 0;
	int ri = run_at(e, a);
	do {
		int as, de, le;
		te_style_metrics(&e->runs[ri], &as, &de, &le);
		if (as > asc)
			asc = as;
		if (de > desc)
			desc = de;
		if (le > lead)
			lead = le;
		ri++;
	} while (ri < e->nruns && e->runs[ri].start < b);
	if (!e->styled) {
		TRun br = base_style(e);
		te_style_metrics(&br, &asc, &desc, &lead);
	}
	e->la[l] = asc;
	e->lh[l] = asc + desc + lead;
}

void te_layout(TEng *e)
{
	runs_normalize(e);
	double width = e->dest.right - e->dest.left;
	int nl = 0;
	lines_reserve(e, 1);
	e->ls[0] = 0;
	int i = 0, ri = 0;
	while (i < e->n) {
		int start = i, lastbreak = -1;
		double w = 0;
		while (i < e->n) {
			uint8_t ch = e->t[i];
			if (ch == 13) {
				i++;
				break;
			}
			double a = char_adv(e, i, &ri);
			if (e->wrap && w + a > width && i > start && ch != ' ') {
				if (lastbreak > start)
					i = lastbreak;
				break;
			}
			w += a;
			i++;
			if (ch == ' ' || ch == '-' || ch == 9)
				lastbreak = i;
		}
		nl++;
		lines_reserve(e, nl);
		e->ls[nl] = i;
		if (i < e->n || (i > 0 && e->t[i - 1] == 13))
			;
		ri = run_at(e, i < e->n ? i : (e->n ? e->n - 1 : 0));
	}
	// an empty last line after a return, or an empty text, still has a line
	if (nl == 0 || (e->n && e->t[e->n - 1] == 13)) {
		nl++;
		lines_reserve(e, nl);
		e->ls[nl] = e->n;
	}
	e->nl = nl;
	for (int l = 0; l < nl; l++)
		line_metrics(e, l);
	TRun br = base_style(e);
	int a, d, ld;
	te_style_metrics(&br, &a, &d, &ld);
	e->lineHeight = a + d + ld;
	e->fontAscent = a;
}

int te_line_of(TEng *e, int off)
{
	for (int l = 0; l < e->nl; l++)
		if (off < e->ls[l + 1] || l == e->nl - 1)
			return l;
	return e->nl - 1;
}

int te_height(TEng *e, int a, int b)
{
	int h = 0;
	if (a > b) {
		int t = a;
		a = b;
		b = t;
	}
	for (int l = a; l <= b && l < e->nl; l++)
		if (l >= 0)
			h += e->lh[l];
	return h;
}

int te_total_height(TEng *e) { return te_height(e, 0, e->nl - 1); }

static int line_top(TEng *e, int l)
{
	int y = e->dest.top;
	for (int k = 0; k < l && k < e->nl; k++)
		y += e->lh[k];
	return y;
}

double te_line_width(TEng *e, int l)
{
	int a = e->ls[l], b = e->ls[l + 1];
	while (b > a && (e->t[b - 1] == 13 || e->t[b - 1] == ' '))
		b--;
	double w = 0;
	int ri = run_at(e, a);
	for (int i = a; i < b; i++)
		w += char_adv(e, i, &ri);
	return w;
}

static double line_x0(TEng *e, int l)
{
	double w = te_line_width(e, l), avail = e->dest.right - e->dest.left;
	if (e->just == 1)
		return e->dest.left + (avail - w) / 2;
	if (e->just == -1)
		return e->dest.right - w;
	return e->dest.left;
}

static double x_of(TEng *e, int l, int off)
{
	double x = line_x0(e, l);
	int ri = run_at(e, e->ls[l]);
	for (int i = e->ls[l]; i < off && i < e->ls[l + 1]; i++)
		x += char_adv(e, i, &ri);
	return x;
}

QPoint te_point(TEng *e, int off)
{
	int l = te_line_of(e, off);
	QPoint p = {(int16_t)(line_top(e, l) + e->lh[l]), (int16_t)lround(x_of(e, l, off))};
	return p;
}

int te_offset_at(TEng *e, QPoint pt)
{
	int y = e->dest.top, l = 0;
	if (pt.v < y)
		l = 0;
	else {
		for (l = 0; l < e->nl; l++) {
			if (pt.v < y + e->lh[l])
				break;
			y += e->lh[l];
		}
		if (l >= e->nl)
			l = e->nl - 1;
	}
	int a = e->ls[l], b = e->ls[l + 1];
	if (b > a && e->t[b - 1] == 13)
		b--;
	double x = line_x0(e, l);
	int ri = run_at(e, a);
	for (int i = a; i < b; i++) {
		double w = char_adv(e, i, &ri);
		if (pt.h < x + w / 2)
			return i;
		x += w;
	}
	// a soft-wrapped line ends before its trailing space
	if (b == e->ls[l + 1] && l < e->nl - 1 && b > a && e->t[b - 1] == ' ')
		return b - 1 > a ? b - 1 : b;
	return b;
}

// ---- drawing ----------------------------------------------------------------------------------------

static void draw_segment(CGContextRef cg, TEng *e, const uint8_t *s, int n, TRun *r, double x, double y)
{
	if (n <= 0)
		return;
	uint8_t *tmp = NULL;
	if (e->password) {
		tmp = malloc(n);
		memset(tmp, 0xa5, n);
		s = tmp;
	}
	// tabs as spaces
	uint8_t buf[512];
	const uint8_t *src = s;
	if (n <= (int)sizeof buf && memchr(s, 9, n)) {
		memcpy(buf, s, n);
		for (int i = 0; i < n; i++)
			if (buf[i] == 9)
				buf[i] = ' ';
		src = buf;
	}
	CFStringRef str = CFStringCreateWithBytes(NULL, src, n, kCFStringEncodingMacRoman, false);
	free(tmp);
	if (!str)
		return;
	CTFontRef f = qd_font(r->font, r->size, r->face);
	CGFloat col[4] = {r->color.r / 65535.0, r->color.g / 65535.0, r->color.b / 65535.0, 1};
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGColorRef color = CGColorCreate(cs, col);
	CGColorSpaceRelease(cs);
	NSMutableDictionary *at = [NSMutableDictionary dictionaryWithDictionary:@{(id)kCTFontAttributeName: (id)f,
		(id)kCTForegroundColorAttributeName: (id)color, (id)kCTKernAttributeName: @0, (id)kCTLigatureAttributeName: @0}];
	if ((r->face & 1) && !(CTFontGetSymbolicTraits(f) & kCTFontBoldTrait))
		at[(id)kCTStrokeWidthAttributeName] = @(-3.0);
	if (r->face & 4)
		at[(id)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, (CFDictionaryRef)at);
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CGContextSetTextPosition(cg, x, y);
	CTLineDraw(line, cg);
	CFRelease(line);
	CFRelease(as);
	CFRelease(str);
	CGColorRelease(color);
}

void te_draw(TEng *e, const Rgn *area)
{
	Port *p = e->port;
	if (!p || !p->pix)
		return;
	Rgn saveclip = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_copy(&saveclip, p->clip);
	rgn_sect_rect(p->clip, e->view);
	if (area)
		rgn_op(p->clip, p->clip, area, RGN_SECT);
	CGContextRef cg = qd_cg_begin(p);
	CGContextSetShouldSmoothFonts(cg, false);
	int y = e->dest.top;
	int s0 = e->selStart < e->selEnd ? e->selStart : e->selEnd, s1 = e->selStart < e->selEnd ? e->selEnd : e->selStart;
	RGB16 hil = p->hilite;
	RGB16 bgc = e->has_bg ? e->bg : p->bg;
	for (int l = 0; l < e->nl; l++) {
		int h = e->lh[l];
		if (y + h <= e->view.top) {
			y += h;
			continue;
		}
		if (y >= e->view.bottom)
			break;
		// erase the line across the view
		CGContextSetRGBFillColor(cg, bgc.r / 65535.0, bgc.g / 65535.0, bgc.b / 65535.0, 1);
		CGContextFillRect(cg, CGRectMake(e->view.left, y, e->view.right - e->view.left, h));
		int a = e->ls[l], b = e->ls[l + 1];
		// selection
		if (s1 > s0 && s0 <= b && s1 >= a && (e->active || e->outline_hilite)) {
			int sa = s0 > a ? s0 : a, sb = s1 < b ? s1 : b;
			double xa = x_of(e, l, sa), xb = s1 > b || (s1 == b && b > a && e->t[b - 1] == 13) ? e->dest.right : x_of(e, l, sb);
			if (s1 >= b && l < e->nl - 1)
				xb = e->dest.right;
			if (xb > xa || (s1 > b)) {
				CGRect hr = CGRectMake(xa, y, xb - xa, h);
				if (e->active) {
					CGContextSetRGBFillColor(cg, hil.r / 65535.0, hil.g / 65535.0, hil.b / 65535.0, 1);
					CGContextFillRect(cg, hr);
				} else {
					CGContextSetRGBStrokeColor(cg, hil.r / 65535.0 * 0.8, hil.g / 65535.0 * 0.8, hil.b / 65535.0 * 0.8, 1);
					CGContextStrokeRect(cg, CGRectInset(hr, 0.5, 0.5));
				}
			}
		}
		// text, run by run
		double x = line_x0(e, l);
		int base = y + e->la[l];
		int i = a;
		int ri = run_at(e, a);
		int end = b;
		while (end > a && e->t[end - 1] == 13)
			end--;
		while (i < end) {
			int rend = ri + 1 < e->nruns ? e->runs[ri + 1].start : e->n;
			if (rend > end)
				rend = end;
			if (rend <= i) {
				ri++;
				continue;
			}
			TRun *r = &e->runs[ri];
			draw_segment(cg, e, e->t + i, rend - i, r, x, base);
			int k = ri;
			for (int c = i; c < rend; c++)
				x += char_adv(e, c, &k);
			i = rend;
			ri++;
		}
		y += h;
	}
	// below the last line
	if (y < e->view.bottom) {
		CGContextSetRGBFillColor(cg, bgc.r / 65535.0, bgc.g / 65535.0, bgc.b / 65535.0, 1);
		CGContextFillRect(cg, CGRectMake(e->view.left, y, e->view.right - e->view.left, e->view.bottom - y));
	}
	// caret
	if (e->active && s0 == s1 && e->caret_vis && !e->readonly) {
		int l = te_line_of(e, s0);
		double x = floor(x_of(e, l, s0));
		int ty = line_top(e, l);
		CGContextSetRGBFillColor(cg, 0, 0, 0, 1);
		CGContextFillRect(cg, CGRectMake(x, ty, 1, e->lh[l]));
	}
	qd_cg_end(p);
	rgn_copy(p->clip, &saveclip);
	free(saveclip.r);
	qd_dirty(p, e->view);
}

static void redraw(TEng *e)
{
	te_draw(e, NULL);
	if (e->on_change)
		e->on_change(e);
}

// ---- editing -------------------------------------------------------------------------------------------

TEng *te_create(Port *port, QRect dest, QRect view, int styled)
{
	TEng *e = calloc(1, sizeof *e);
	e->port = port;
	e->dest = dest;
	e->view = view;
	e->styled = styled;
	e->wrap = 1;
	e->autoview = 1;
	e->font = port ? port->txFont : 0;
	e->size = port && port->txSize ? port->txSize : 12;
	e->face = port ? port->txFace : 0;
	e->color = port ? port->fg : (RGB16){0, 0, 0};
	e->cap = 256;
	e->t = malloc(e->cap);
	e->caret_vis = 1;
	te_layout(e);
	return e;
}

void te_dispose(TEng *e)
{
	if (!e)
		return;
	free(e->t);
	free(e->runs);
	free(e->ls);
	free(e->lh);
	free(e->la);
	free(e->u_t);
	free(e->u_runs);
	free(e);
}

static void reserve(TEng *e, int n)
{
	if (n > e->cap) {
		e->cap = n * 2;
		e->t = realloc(e->t, e->cap);
	}
}

void te_set_text(TEng *e, const void *s, int n)
{
	reserve(e, n + 1);
	memcpy(e->t, s, n);
	e->n = n;
	TRun first = e->nruns ? e->runs[0] : base_style(e);
	e->nruns = 1;
	runs_reserve(e, 1);
	e->runs[0] = first;
	e->runs[0].start = 0;
	e->selStart = e->selEnd = e->anchor = n;
	e->has_undo = 0;
	te_layout(e);
}

void te_set_select(TEng *e, int a, int b)
{
	if (a < 0)
		a = 0;
	if (b < 0)
		b = 0;
	if (a > e->n)
		a = e->n;
	if (b > e->n)
		b = e->n;
	if (a > b) {
		int t = a;
		a = b;
		b = t;
	}
	e->selStart = a;
	e->selEnd = b;
	e->anchor = a;
	e->has_null_style = 0;
}

void te_snapshot(TEng *e)
{
	free(e->u_t);
	free(e->u_runs);
	e->u_t = malloc(e->n + 1);
	memcpy(e->u_t, e->t, e->n);
	e->u_n = e->n;
	e->u_runs = malloc(sizeof(TRun) * (e->nruns + 1));
	memcpy(e->u_runs, e->runs, sizeof(TRun) * e->nruns);
	e->u_nruns = e->nruns;
	e->u_sel0 = e->selStart;
	e->u_sel1 = e->selEnd;
	e->has_undo = 1;
	e->redo = 0;
}

void te_undo(TEng *e)
{
	if (!e->has_undo)
		return;
	uint8_t *t = e->u_t;
	int n = e->u_n;
	TRun *r = e->u_runs;
	int nr = e->u_nruns, s0 = e->u_sel0, s1 = e->u_sel1;
	// keep the current state for redo
	e->u_t = e->t;
	e->u_n = e->n;
	e->u_runs = e->runs;
	e->u_nruns = e->nruns;
	e->u_sel0 = e->selStart;
	e->u_sel1 = e->selEnd;
	e->t = t;
	e->n = n;
	e->cap = n + 1;
	e->runs = r;
	e->nruns = nr;
	e->capruns = nr;
	e->selStart = s0;
	e->selEnd = s1;
	e->redo = !e->redo;
	e->typing = 0;
	te_layout(e);
	redraw(e);
}

// delete [a, b)
static void del_range(TEng *e, int a, int b)
{
	if (b <= a)
		return;
	memmove(e->t + a, e->t + b, e->n - b);
	e->n -= b - a;
	for (int i = 0; i < e->nruns; i++) {
		if (e->runs[i].start >= b)
			e->runs[i].start -= b - a;
		else if (e->runs[i].start > a)
			e->runs[i].start = a;
	}
	runs_normalize(e);
}

void te_delete_sel(TEng *e)
{
	int a = e->selStart, b = e->selEnd;
	if (a == b)
		return;
	TRun keep = te_style_at(e, a);
	del_range(e, a, b);
	e->selStart = e->selEnd = e->anchor = a;
	// typing goes on in the style of the deleted text
	e->null_style = keep;
	e->has_null_style = 1;
	te_layout(e);
}

void te_insert(TEng *e, const uint8_t *s, int n, const TRun *runs, int nruns)
{
	if (n <= 0)
		return;
	int at = e->selStart;
	TRun style = e->has_null_style ? e->null_style : te_style_at(e, at > 0 ? at - 1 : 0);
	reserve(e, e->n + n + 1);
	memmove(e->t + at + n, e->t + at, e->n - at);
	memcpy(e->t + at, s, n);
	e->n += n;
	// shift runs after the insertion point
	for (int i = 0; i < e->nruns; i++)
		if (e->runs[i].start > at || (e->runs[i].start == at && at > 0))
			e->runs[i].start += n;
	if (e->styled) {
		// the inserted text: given runs, or the current style
		int k = runs_split(e, at);
		(void)k;
		runs_reserve(e, e->nruns + (nruns > 0 ? nruns : 1) + 1);
		// find the run index of position at and insert new runs there
		int idx = run_at(e, at);
		if (e->runs[idx].start != at)
			idx++;
		int add = nruns > 0 ? nruns : 1;
		memmove(e->runs + idx + add, e->runs + idx, (e->nruns - idx) * sizeof(TRun));
		for (int i = 0; i < add; i++) {
			e->runs[idx + i] = nruns > 0 ? runs[i] : style;
			e->runs[idx + i].start = at + (nruns > 0 ? runs[i].start : 0);
		}
		e->nruns += add;
		// the text after keeps its own style
		if (at + n < e->n) {
			int after = idx + add;
			if (after >= e->nruns || e->runs[after].start != at + n) {
				TRun prev = te_style_at(e, at + n);
				(void)prev;
			}
		}
	}
	e->selStart = e->selEnd = e->anchor = at + n;
	e->has_null_style = 0;
	te_layout(e);
}

void te_sel_view(TEng *e)
{
	int off = e->selEnd;
	int l = te_line_of(e, off);
	int top = line_top(e, l), bot = top + e->lh[l];
	int dv = 0;
	if (top < e->view.top)
		dv = e->view.top - top;
	else if (bot > e->view.bottom)
		dv = e->view.bottom - bot;
	int dh = 0;
	if (!e->wrap) {
		double x = x_of(e, l, off);
		if (x < e->view.left)
			dh = (int)(e->view.left - x) + 20;
		else if (x > e->view.right - 2)
			dh = (int)(e->view.right - 2 - x) - 20;
		if (dh && e->dest.left + dh > e->view.left)
			dh = e->view.left - e->dest.left;
	}
	if (dv || dh)
		te_scroll(e, dh, dv);
}

void te_scroll(TEng *e, int dh, int dv)
{
	e->dest = rect_off(e->dest, dh, dv);
	te_draw(e, NULL);
}

static int word_start(TEng *e, int i)
{
	while (i > 0 && isalnum(e->t[i - 1]))
		i--;
	return i;
}
static int word_end(TEng *e, int i)
{
	while (i < e->n && isalnum(e->t[i]))
		i++;
	return i;
}

void te_key(TEng *e, uint8_t ch, uint16_t mods)
{
	int shift = (mods & 0x200) != 0, cmd = (mods & 0x100) != 0, opt = (mods & 0x800) != 0;
	e->caret_vis = 1;
	e->caret_tick = ev_ticks();
	if (ch >= 28 && ch <= 31) {
		int pos = e->selStart == e->anchor ? e->selEnd : e->selStart;
		int l = te_line_of(e, pos);
		if (ch == 28) {
			if (!shift && e->selStart != e->selEnd)
				pos = e->selStart;
			else if (cmd)
				pos = e->ls[l];
			else if (opt)
				pos = word_start(e, pos > 0 ? pos - 1 : 0);
			else if (pos > 0)
				pos--;
		} else if (ch == 29) {
			if (!shift && e->selStart != e->selEnd)
				pos = e->selEnd;
			else if (cmd) {
				pos = e->ls[l + 1];
				if (pos > e->ls[l] && e->t[pos - 1] == 13)
					pos--;
			} else if (opt)
				pos = word_end(e, pos < e->n ? pos + 1 : pos);
			else if (pos < e->n)
				pos++;
		} else {
			QPoint p = te_point(e, pos);
			if (ch == 30) {
				if (l == 0)
					pos = 0;
				else {
					p.v = (int16_t)(line_top(e, l - 1) + 1);
					pos = te_offset_at(e, p);
				}
			} else {
				if (l >= e->nl - 1)
					pos = e->n;
				else {
					p.v = (int16_t)(line_top(e, l + 1) + 1);
					pos = te_offset_at(e, p);
				}
			}
		}
		if (shift) {
			int a = e->anchor;
			e->selStart = a < pos ? a : pos;
			e->selEnd = a < pos ? pos : a;
		} else {
			e->selStart = e->selEnd = e->anchor = pos;
		}
		e->typing = 0;
		if (e->autoview)
			te_sel_view(e);
		te_draw(e, NULL);
		return;
	}
	if (e->readonly)
		return;
	if (ch == 8) {
		if (!e->typing)
			te_snapshot(e);
		e->typing = 1;
		if (e->selStart == e->selEnd && e->selStart > 0)
			e->selStart--;
		te_delete_sel(e);
	} else if (ch == 127) {
		if (!e->typing)
			te_snapshot(e);
		e->typing = 1;
		if (e->selStart == e->selEnd && e->selEnd < e->n)
			e->selEnd++;
		te_delete_sel(e);
	} else if (ch >= 32 || ch == 13 || ch == 9) {
		if (!e->typing)
			te_snapshot(e);
		e->typing = 1;
		TRun ns = e->has_null_style ? e->null_style : te_style_at(e, e->selStart > 0 ? e->selStart - 1 : 0);
		int had = e->has_null_style;
		te_delete_sel(e);
		e->null_style = ns;
		e->has_null_style = had || e->styled;
		te_insert(e, &ch, 1, NULL, 0);
	} else
		return;
	if (e->autoview)
		te_sel_view(e);
	redraw(e);
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

void te_click(TEng *e, QPoint pt, int extend)
{
	int off = te_offset_at(e, pt);
	uint32_t now = ev_ticks();
	if (now - e->click_tick < (uint32_t)(NSEvent.doubleClickInterval * 60) && abs(off - e->click_off) <= 1)
		e->click_count++;
	else
		e->click_count = 1;
	e->click_tick = now;
	e->click_off = off;
	e->typing = 0;
	int a0 = off, b0 = off;
	if (e->click_count == 2) {
		a0 = word_start(e, off);
		b0 = word_end(e, off);
	} else if (e->click_count >= 3) {
		int l = te_line_of(e, off);
		a0 = e->ls[l];
		b0 = e->ls[l + 1];
	}
	if (extend) {
		int a = e->anchor;
		e->selStart = a < off ? a : off;
		e->selEnd = a < off ? off : a;
	} else {
		e->selStart = a0;
		e->selEnd = b0;
		e->anchor = a0;
	}
	e->has_null_style = 0;
	e->caret_vis = 1;
	te_draw(e, NULL);
	win_flush_all();
	while (ev_button_down()) {
		ev_pump(0.015);
		QPoint m = mouse_local(e->port);
		// scrolling while dragging outside the view
		if (m.v < e->view.top && e->dest.top < e->view.top)
			te_scroll(e, 0, e->lh[0] < e->view.top - e->dest.top ? e->lh[0] : e->view.top - e->dest.top);
		else if (m.v > e->view.bottom && line_top(e, e->nl) > e->view.bottom)
			te_scroll(e, 0, -e->lh[0]);
		int o = te_offset_at(e, m);
		int a = e->anchor, s, t;
		if (e->click_count == 2) {
			s = o < a0 ? word_start(e, o) : a0;
			t = o > b0 ? word_end(e, o) : b0;
		} else {
			s = a < o ? a : o;
			t = a < o ? o : a;
		}
		if (s != e->selStart || t != e->selEnd) {
			e->selStart = s;
			e->selEnd = t;
			te_draw(e, NULL);
		}
	}
	ev_drop_mouseups();
	if (e->on_change)
		e->on_change(e);
}

void te_idle(TEng *e)
{
	if (!e->active || e->selStart != e->selEnd)
		return;
	uint32_t now = ev_ticks();
	if (now - e->caret_tick >= 30) {
		e->caret_tick = now;
		e->caret_vis = !e->caret_vis;
		int l = te_line_of(e, e->selStart);
		int top = line_top(e, l);
		Rgn r = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_set_rect(&r, (QRect){(int16_t)top, e->view.left, (int16_t)(top + e->lh[l]), e->view.right});
		te_draw(e, &r);
		free(r.r);
	}
}

void te_activate(TEng *e, int on)
{
	if (e->active == on)
		return;
	e->active = on;
	e->caret_vis = 1;
	e->caret_tick = ev_ticks();
	te_draw(e, NULL);
}

void te_set_rects(TEng *e, QRect dest, QRect view)
{
	e->dest = dest;
	e->view = view;
	te_layout(e);
}

void te_restyle_all(TEng *e)
{
	for (int i = 0; i < e->nruns; i++) {
		e->runs[i].font = (int16_t)e->font;
		e->runs[i].size = (int16_t)(e->size ? e->size : 12);
		e->runs[i].face = (uint8_t)e->face;
	}
	te_layout(e);
}

// ---- styles ----------------------------------------------------------------------------------------------

static TRun apply_style(TRun r, int mode, int font, int face, int size, RGB16 color)
{
	if (mode & 1)
		r.font = (int16_t)font;
	if (mode & 2) {
		if (mode & 32)
			r.face = (uint8_t)((r.face & face) == face ? (r.face & ~face) : (r.face | face));
		else
			r.face = (uint8_t)face;
	}
	if (mode & 4)
		r.size = (int16_t)size;
	if (mode & 16)
		r.size = (int16_t)(r.size + size);
	if (mode & 8)
		r.color = color;
	return r;
}

void te_set_style(TEng *e, int mode, int font, int face, int size, RGB16 color, int redraw_now)
{
	int a = e->selStart, b = e->selEnd;
	if (!e->styled) {
		TRun r = apply_style(base_style(e), mode, font, face, size, color);
		e->font = r.font;
		e->face = r.face;
		e->size = r.size;
		e->color = r.color;
		te_restyle_all(e);
		for (int i = 0; i < e->nruns; i++)
			e->runs[i].color = r.color;
	} else if (a == b) {
		e->null_style = apply_style(e->has_null_style ? e->null_style : te_style_at(e, a > 0 ? a - 1 : 0), mode, font, face, size, color);
		e->has_null_style = 1;
		return;
	} else {
		runs_split(e, a);
		if (b < e->n)
			runs_split(e, b);
		for (int i = 0; i < e->nruns; i++)
			if (e->runs[i].start >= a && e->runs[i].start < b) {
				int st = e->runs[i].start;
				e->runs[i] = apply_style(e->runs[i], mode, font, face, size, color);
				e->runs[i].start = st;
			}
		te_layout(e);
	}
	if (redraw_now)
		redraw(e);
}

int te_continuous(TEng *e, int *mode, TRun *out)
{
	int a = e->selStart, b = e->selEnd;
	TRun first = a == b ? (e->has_null_style ? e->null_style : te_style_at(e, a > 0 ? a - 1 : 0)) : te_style_at(e, a);
	*out = first;
	if (a == b)
		return 1;
	int all = 1;
	int face_and = first.face;
	for (int i = run_at(e, a); i < e->nruns && e->runs[i].start < b; i++) {
		TRun *r = &e->runs[i];
		if ((*mode & 1) && r->font != first.font) {
			*mode &= ~1;
			all = 0;
		}
		if ((*mode & 4) && r->size != first.size) {
			*mode &= ~4;
			all = 0;
		}
		if ((*mode & 8) && memcmp(&r->color, &first.color, sizeof first.color)) {
			*mode &= ~8;
			all = 0;
		}
		face_and &= r->face;
		if ((*mode & 2) && r->face != first.face)
			all = 0;
	}
	out->face = (uint8_t)face_and;
	return all;
}

// ---- the scrap ------------------------------------------------------------------------------------------------

static NSData *style_scrap(TEng *e, int a, int b)
{
	NSMutableData *d = [NSMutableData data];
	int n = 0;
	int i0 = run_at(e, a);
	for (int i = i0; i < e->nruns && (e->runs[i].start < b || i == i0); i++)
		n++;
	uint8_t h[2] = {(uint8_t)(n >> 8), (uint8_t)n};
	[d appendBytes:h length:2];
	for (int i = i0; i < i0 + n; i++) {
		TRun *r = &e->runs[i];
		int start = r->start > a ? r->start - a : 0;
		int asc, desc, lead;
		te_style_metrics(r, &asc, &desc, &lead);
		uint8_t el[20] = {(uint8_t)(start >> 24), (uint8_t)(start >> 16), (uint8_t)(start >> 8), (uint8_t)start,
			(uint8_t)((asc + desc + lead) >> 8), (uint8_t)(asc + desc + lead), (uint8_t)(asc >> 8), (uint8_t)asc,
			(uint8_t)(r->font >> 8), (uint8_t)r->font, r->face, 0, (uint8_t)(r->size >> 8), (uint8_t)r->size,
			(uint8_t)(r->color.r >> 8), (uint8_t)r->color.r, (uint8_t)(r->color.g >> 8), (uint8_t)r->color.g,
			(uint8_t)(r->color.b >> 8), (uint8_t)r->color.b};
		[d appendBytes:el length:20];
	}
	return d;
}

static int parse_style_scrap(const uint8_t *d, uint32_t len, TRun **out)
{
	if (len < 2)
		return 0;
	int n = d[0] << 8 | d[1];
	if (2 + 20 * (uint32_t)n > len)
		n = (int)((len - 2) / 20);
	TRun *r = calloc(n ? n : 1, sizeof *r);
	for (int i = 0; i < n; i++) {
		const uint8_t *e = d + 2 + 20 * i;
		r[i].start = (int)((uint32_t)e[0] << 24 | e[1] << 16 | e[2] << 8 | e[3]);
		r[i].font = (int16_t)(e[8] << 8 | e[9]);
		r[i].face = e[10];
		r[i].size = (int16_t)(e[12] << 8 | e[13]);
		r[i].color = (RGB16){(uint16_t)(e[14] << 8 | e[15]), (uint16_t)(e[16] << 8 | e[17]), (uint16_t)(e[18] << 8 | e[19])};
	}
	*out = r;
	return n;
}

void te_copy(TEng *e)
{
	int a = e->selStart, b = e->selEnd;
	if (b <= a)
		return;
	scrap_put('TEXT', e->t + a, b - a);
	if (e->styled) {
		NSData *s = style_scrap(e, a, b);
		scrap_put('styl', s.bytes, (uint32_t)s.length);
	}
}

void te_paste(TEng *e)
{
	void *t;
	uint32_t n;
	if (!scrap_get('TEXT', &t, &n))
		return;
	TRun *runs = NULL;
	int nruns = 0;
	void *s;
	uint32_t sn;
	if (e->styled && scrap_get('styl', &s, &sn)) {
		nruns = parse_style_scrap(s, sn, &runs);
		free(s);
	}
	te_snapshot(e);
	te_delete_sel(e);
	te_insert(e, t, (int)n, runs, nruns);
	free(runs);
	free(t);
	e->typing = 0;
	if (e->autoview)
		te_sel_view(e);
	redraw(e);
}

// ---- TextEdit: guest TERecs ------------------------------------------------------------------------------------

static HMap tes;   // TEHandle -> TEng

static void push_rec(TEng *e)
{
	uint32_t h = e->teh;
	if (!h || !is_handle(h))
		return;
	uint32_t need = 96 + 2 * (e->nl + 1);
	if (HSize(h) < need)
		HSetSize(h, need);
	uint32_t r = HP(h);
	PUTRECT(r, e->dest);
	PUTRECT(r + 8, e->view);
	ST16(r + 24, e->styled ? 0xffff : e->lineHeight);
	ST16(r + 26, e->styled ? 0xffff : e->fontAscent);
	QPoint sp = te_point(e, e->selStart);
	STPT(r + 28, sp);
	ST16(r + 32, e->selStart);
	ST16(r + 34, e->selEnd);
	ST16(r + 36, e->active);
	ST16(r + 56, e->caret_vis);
	ST16(r + 58, e->just);
	ST16(r + 60, e->n);
	uint32_t ht = LD32(r + 62);
	if (!ht) {
		ht = NewHandleG(e->n);
		ST32(r + 62, ht);
	}
	HSetSize(ht, e->n);
	if (e->n)
		memcpy(G(HP(ht)), e->t, e->n);
	ST16(r + 72, e->wrap ? 0 : 0xffff);
	if (!e->styled) {
		ST16(r + 74, e->font);
		ST8(r + 76, e->face);
		ST16(r + 80, e->size);
	} else
		ST16(r + 80, 0xffff);
	ST16(r + 78, 1);
	ST32(r + 82, e->port ? e->port->tok : 0);
	ST16(r + 94, e->nl);
	for (int l = 0; l <= e->nl; l++)
		ST16(r + 96 + 2 * l, e->ls[l]);
}

static void on_change(TEng *e) { push_rec(e); }

// what the guest may have changed directly in its TERec
static void pull_rec(TEng *e)
{
	uint32_t h = e->teh;
	if (!h || !is_handle(h))
		return;
	uint32_t r = HP(h);
	QRect d = RECT(r), v = RECT(r + 8);
	int relayout = 0;
	if (memcmp(&d, &e->dest, sizeof d)) {
		relayout = d.right - d.left != e->dest.right - e->dest.left;
		e->dest = d;
	}
	e->view = v;
	int s0 = (int16_t)LD16(r + 32), s1 = (int16_t)LD16(r + 34);
	int just = (int16_t)LD16(r + 58);
	if (just != e->just) {
		e->just = just;
	}
	e->wrap = (int16_t)LD16(r + 72) >= 0;
	if (!e->styled) {
		int f = (int16_t)LD16(r + 74), sz = (int16_t)LD16(r + 80), fc = LD8(r + 76);
		if (f != e->font || sz != e->size || fc != e->face) {
			e->font = f;
			e->size = sz;
			e->face = fc;
			te_restyle_all(e);
		}
	}
	uint32_t ht = LD32(r + 62);
	int len = (int16_t)LD16(r + 60);
	if (len < 0)
		len = 0;
	if (ht && is_handle(ht) && ((uint32_t)len != (uint32_t)e->n || (len && memcmp(G(HP(ht)), e->t, len)))) {
		if ((uint32_t)len > HSize(ht))
			len = (int)HSize(ht);
		reserve(e, len + 1);
		memcpy(e->t, G(HP(ht)), len);
		int oldn = e->n;
		e->n = len;
		if (len < oldn)
			for (int i = 0; i < e->nruns; i++)
				if (e->runs[i].start > len)
					e->runs[i].start = len;
		relayout = 1;
	}
	if (relayout)
		te_layout(e);
	if (s0 >= 0 && s0 <= e->n)
		e->selStart = s0;
	if (s1 >= 0 && s1 <= e->n)
		e->selEnd = s1;
}

uint32_t te_handle(TEng *e)
{
	if (!e->teh) {
		e->teh = NewHandleClearG(96 + 2 * (e->nl + 1));
		hm_put(&tes, e->teh, e);
		e->on_change = on_change;
		push_rec(e);
	}
	return e->teh;
}

static TEng *TE(uint32_t h)
{
	TEng *e = hm_get(&tes, h);
	if (e)
		pull_rec(e);
	return e;
}

static uint32_t te_new_common(PPC *c, int styled)
{
	Port *p = qd_port;
	TEng *e = te_create(p, RECT(A(0)), RECT(A(1)), styled);
	return te_handle(e);
}
static void sh_TENew(PPC *c) { RET(te_new_common(c, 0)); }
static void sh_TEStyleNew(PPC *c) { RET(te_new_common(c, 1)); }
static void sh_TEDispose(PPC *c)
{
	TEng *e = TE(A(0));
	if (!e)
		return;
	hm_del(&tes, A(0));
	uint32_t ht = LD32(HP(A(0)) + 62);
	DisposeHandleG(ht);
	DisposeHandleG(A(0));
	te_dispose(e);
}
static void sh_TESetText(PPC *c)
{
	// TESetText(text, length, teH)
	TEng *e = TE(A(2));
	if (!e)
		return;
	te_set_text(e, G(A(0)), (int32_t)A(1));
	push_rec(e);
}
static void sh_TEGetText(PPC *c) { TEng *e = TE(A(0)); if (e) push_rec(e); RET(e ? LD32(HP(A(0)) + 62) : 0); }
static void sh_TECalText(PPC *c) { TEng *e = TE(A(0)); if (e) { te_layout(e); push_rec(e); } }
static void sh_TEUpdate(PPC *c)
{
	// TEUpdate(const Rect *rUpdate, teH)
	TEng *e = TE(A(1));
	if (!e)
		return;
	e->port = qd_port ? qd_port : e->port;
	Rgn r = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&r, RECT(A(0)));
	te_draw(e, &r);
	free(r.r);
}
static void sh_TEClick(PPC *c)
{
	// TEClick(Point, Boolean extend, teH)
	TEng *e = TE(A(2));
	if (!e)
		return;
	te_click(e, PT(A(0)), A(1) & 0xff);
	push_rec(e);
}
static void sh_TEKey(PPC *c)
{
	TEng *e = TE(A(1));
	if (!e)
		return;
	te_key(e, (uint8_t)A(0), ev_last.modifiers);
	push_rec(e);
}
static void sh_TEIdle(PPC *c) { TEng *e = TE(A(0)); if (e) { te_idle(e); push_rec(e); } }
static void sh_TEActivate(PPC *c) { TEng *e = TE(A(0)); if (e) { te_activate(e, 1); push_rec(e); } }
static void sh_TEDeactivate(PPC *c) { TEng *e = TE(A(0)); if (e) { te_activate(e, 0); push_rec(e); } }
static void sh_TESetSelect(PPC *c)
{
	TEng *e = TE(A(2));
	if (!e)
		return;
	te_set_select(e, (int32_t)A(0), (int32_t)A(1));
	te_draw(e, NULL);
	push_rec(e);
}
static void sh_TEInsert(PPC *c)
{
	// TEInsert(text, length, teH): at the selection start, the selection unchanged... (inserted before)
	TEng *e = TE(A(2));
	if (!e)
		return;
	int s0 = e->selStart, s1 = e->selEnd, n = (int32_t)A(1);
	e->selEnd = e->selStart;
	te_insert(e, G(A(0)), n, NULL, 0);
	e->selStart = s0 + n;
	e->selEnd = s1 + n;
	te_draw(e, NULL);
	push_rec(e);
}
static void sh_TEStyleInsert(PPC *c)
{
	// TEStyleInsert(text, length, StScrpHandle, teH)
	TEng *e = TE(A(3));
	if (!e)
		return;
	TRun *runs = NULL;
	int nruns = 0;
	if (A(2) && is_handle(A(2)))
		nruns = parse_style_scrap(G(HP(A(2))), HSize(A(2)), &runs);
	int s0 = e->selStart, s1 = e->selEnd, n = (int32_t)A(1);
	e->selEnd = e->selStart;
	te_insert(e, G(A(0)), n, runs, nruns);
	free(runs);
	e->selStart = s0 + n;
	e->selEnd = s1 + n;
	te_draw(e, NULL);
	push_rec(e);
}
static void sh_TEDelete(PPC *c)
{
	TEng *e = TE(A(0));
	if (!e)
		return;
	te_delete_sel(e);
	if (e->autoview)
		te_sel_view(e);
	te_draw(e, NULL);
	push_rec(e);
}
static void sh_TECopy(PPC *c) { TEng *e = TE(A(0)); if (e) te_copy(e); }
static void sh_TEToScrap(PPC *c) { RET(0); }   // the private scrap is the system one
static void sh_TEGetStyleScrapHandle(PPC *c)
{
	TEng *e = TE(A(0));
	if (!e) {
		RET(0);
		return;
	}
	NSData *d = style_scrap(e, e->selStart, e->selEnd);
	RET(NewHandleFrom(d.bytes, (uint32_t)d.length));
}
static void sh_TEUseStyleScrap(PPC *c)
{
	// TEUseStyleScrap(rangeStart, rangeEnd, newStyles, fRedraw, teH)
	TEng *e = TE(A(4));
	if (!e || !A(2) || !is_handle(A(2)))
		return;
	TRun *runs;
	int n = parse_style_scrap(G(HP(A(2))), HSize(A(2)), &runs);
	int a = (int32_t)A(0), b = (int32_t)A(1);
	int s0 = e->selStart, s1 = e->selEnd;
	for (int i = 0; i < n; i++) {
		int ra = a + runs[i].start, rb = i + 1 < n ? a + runs[i + 1].start : b;
		if (rb > b)
			rb = b;
		e->selStart = ra;
		e->selEnd = rb;
		te_set_style(e, 15, runs[i].font, runs[i].face, runs[i].size, runs[i].color, 0);
	}
	free(runs);
	e->selStart = s0;
	e->selEnd = s1;
	if (A(3) & 0xff)
		te_draw(e, NULL);
	push_rec(e);
}
static void sh_TESetStyle(PPC *c)
{
	// TESetStyle(mode, const TextStyle *, fRedraw, teH)
	TEng *e = TE(A(3));
	if (!e)
		return;
	uint32_t s = A(1);
	RGB16 col = {(uint16_t)LD16(s + 6), (uint16_t)LD16(s + 8), (uint16_t)LD16(s + 10)};
	te_set_style(e, (int16_t)A(0), (int16_t)LD16(s), LD8(s + 2), (int16_t)LD16(s + 4), col, A(2) & 0xff);
	push_rec(e);
}
static void sh_TEContinuousStyle(PPC *c)
{
	// TEContinuousStyle(short *mode, TextStyle *, teH)
	TEng *e = TE(A(2));
	if (!e) {
		RET(0);
		return;
	}
	int mode = (int16_t)LD16(A(0));
	TRun r;
	int all = te_continuous(e, &mode, &r);
	ST16(A(0), mode);
	uint32_t s = A(1);
	ST16(s, r.font);
	ST8(s + 2, r.face);
	ST16(s + 4, r.size);
	ST16(s + 6, r.color.r);
	ST16(s + 8, r.color.g);
	ST16(s + 10, r.color.b);
	RET(all);
}
static void sh_TEGetStyle(PPC *c)
{
	// TEGetStyle(offset, TextStyle *, short *lineHeight, short *fontAscent, teH)
	TEng *e = TE(A(4));
	if (!e)
		return;
	TRun r = te_style_at(e, (int16_t)A(0));
	uint32_t s = A(1);
	ST16(s, r.font);
	ST8(s + 2, r.face);
	ST16(s + 4, r.size);
	ST16(s + 6, r.color.r);
	ST16(s + 8, r.color.g);
	ST16(s + 10, r.color.b);
	int l = te_line_of(e, (int16_t)A(0));
	if (A(2))
		ST16(A(2), e->lh[l]);
	if (A(3))
		ST16(A(3), e->la[l]);
}
static void sh_TEGetHeight(PPC *c)
{
	// TEGetHeight(endLine, startLine, teH): lines are 1-based
	TEng *e = TE(A(2));
	RET(e ? te_height(e, (int32_t)A(1) - 1, (int32_t)A(0) - 1) : 0);
}
static void sh_TEGetPoint(PPC *c) { TEng *e = TE(A(1)); RET(e ? PTV(te_point(e, (int16_t)A(0))) : 0); }
static void sh_TESetAlignment(PPC *c) { TEng *e = TE(A(1)); if (e) { e->just = (int16_t)A(0); push_rec(e); } }
static void sh_TESelView(PPC *c) { TEng *e = TE(A(0)); if (e) { te_sel_view(e); push_rec(e); } }
static void sh_TEFeatureFlag(PPC *c)
{
	// TEFeatureFlag(feature, action, teH): teFAutoScroll 0, teFOutlineHilite 2
	TEng *e = TE(A(2));
	int f = (int16_t)A(0), act = (int16_t)A(1);
	if (!e) {
		RET(0);
		return;
	}
	int *bit = f == 2 ? &e->outline_hilite : f == 0 ? &e->autoview : NULL;
	int old = bit ? *bit : 0;
	if (bit && act >= 0)
		*bit = act;
	RET(old);
}

void te_idle_all(void)
{
	for (uint32_t i = 0; i < tes.cap; i++)
		if (tes.k[i] && tes.k[i] != 0xffffffffu) {
			TEng *e = tes.v[i];
			(void)e;
		}
}

static const ShimDef teshims[] = {
	S(TENew), S(TEStyleNew), S(TEDispose), S(TESetText), S(TEGetText), S(TECalText), S(TEUpdate), S(TEClick),
	S(TEKey), S(TEIdle), S(TEActivate), S(TEDeactivate), S(TESetSelect), S(TEInsert), S(TEStyleInsert),
	S(TEDelete), S(TECopy), S(TEToScrap), S(TEGetStyleScrapHandle), S(TEUseStyleScrap), S(TESetStyle),
	S(TEContinuousStyle), S(TEGetStyle), S(TEGetHeight), S(TEGetPoint), S(TESetAlignment), S(TESelView),
	S(TEFeatureFlag),
};
REGISTER(teshims)
