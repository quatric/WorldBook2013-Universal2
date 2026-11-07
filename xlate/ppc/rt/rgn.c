// QuickDraw regions (see rgn.h).
#include "rgn.h"
#include "hmap.h"
#include <math.h>

Rgn *rgn_new(void) { return calloc(1, sizeof(Rgn)); }

void rgn_free(Rgn *g)
{
	if (g) {
		free(g->r);
		free(g);
	}
}

static void push(Rgn *g, QRect r)
{
	if (g->n == g->cap) {
		g->cap = g->cap ? g->cap * 2 : 8;
		g->r = realloc(g->r, g->cap * sizeof *g->r);
	}
	g->r[g->n++] = r;
}

static void bbox(Rgn *g)
{
	QRect b = {0, 0, 0, 0};
	for (int i = 0; i < g->n; i++)
		b = rect_union(b, g->r[i]);
	g->bbox = b;
}

void rgn_set_empty(Rgn *g)
{
	g->n = 0;
	g->bbox = (QRect){0, 0, 0, 0};
}

void rgn_set_rect(Rgn *g, QRect r)
{
	g->n = 0;
	if (!rect_empty(r))
		push(g, r);
	bbox(g);
}

void rgn_copy(Rgn *d, const Rgn *s)
{
	if (d == s)
		return;
	d->n = 0;
	for (int i = 0; i < s->n; i++)
		push(d, s->r[i]);
	d->bbox = s->bbox;
}

int rgn_empty(const Rgn *g) { return g->n == 0; }

void rgn_offset(Rgn *g, int dh, int dv)
{
	for (int i = 0; i < g->n; i++)
		g->r[i] = rect_off(g->r[i], dh, dv);
	if (g->n)
		g->bbox = rect_off(g->bbox, dh, dv);
}

// ---- building -------------------------------------------------------------------

typedef struct { int y0, y1, n; int16_t xs[512]; } Band;

static void emit_band(Rgn *g, int y0, int y1, const int16_t *xs, int n)
{
	for (int i = 0; i + 1 < n; i += 2)
		push(g, (QRect){(int16_t)y0, xs[i], (int16_t)y1, xs[i + 1]});
}

// a band builder that merges vertically adjacent bands with equal intervals
typedef struct { Rgn *g; int y0, y1, n; int16_t xs[1024]; int open; } BB;

static void bb_flush(BB *b)
{
	if (b->open && b->n)
		emit_band(b->g, b->y0, b->y1, b->xs, b->n);
	b->open = 0;
}

static void bb_band(BB *b, int y0, int y1, const int16_t *xs, int n)
{
	if (n > 1024)
		n = 1024;
	if (b->open && b->y1 == y0 && b->n == n && !memcmp(b->xs, xs, n * 2)) {
		b->y1 = y1;
		return;
	}
	bb_flush(b);
	if (!n)
		return;
	b->open = 1;
	b->y0 = y0;
	b->y1 = y1;
	b->n = n;
	memcpy(b->xs, xs, n * 2);
}

void rb_begin(RgnBuild *b, Rgn *g)
{
	(void)b;
	b->g = g;
	g->n = 0;
	b->n = -1;
}

// RgnBuild keeps a BB in its xs storage
static BB *bbof(RgnBuild *b)
{
	static BB bb;   // regions are built on the main thread only
	return &bb;
}

void rb_row(RgnBuild *b, int y, const int16_t *xs, int n)
{
	BB *bb = bbof(b);
	if (b->n == -1) {
		bb->g = b->g;
		bb->open = 0;
		b->n = 0;
	}
	bb_band(bb, y, y + 1, xs, n);
}

void rb_end(RgnBuild *b)
{
	BB *bb = bbof(b);
	if (b->n != -1)
		bb_flush(bb);
	bbox(b->g);
}

// ---- boolean operations -----------------------------------------------------------

typedef struct { int y0, y1, i, n; } BandIx;

static int bands(const Rgn *g, BandIx *out, int max)
{
	int k = 0;
	for (int i = 0; i < g->n && k < max;) {
		int j = i;
		while (j < g->n && g->r[j].top == g->r[i].top)
			j++;
		out[k++] = (BandIx){g->r[i].top, g->r[i].bottom, i, j - i};
		i = j;
	}
	return k;
}

static int cmp16(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }

static int combine(const int16_t *a, int na, const int16_t *b, int nb, int op, int16_t *out)
{
	int i = 0, j = 0, ina = 0, inb = 0, n = 0, prev = 0;
	while (i < na || j < nb) {
		int x;
		if (j >= nb || (i < na && a[i] <= b[j]))
			x = a[i];
		else
			x = b[j];
		while (i < na && a[i] == x) {
			ina = !ina;
			i++;
		}
		while (j < nb && b[j] == x) {
			inb = !inb;
			j++;
		}
		int in;
		switch (op) {
		case RGN_UNION: in = ina || inb; break;
		case RGN_SECT: in = ina && inb; break;
		case RGN_DIFF: in = ina && !inb; break;
		default: in = ina != inb; break;
		}
		if (in != prev) {
			if (n && out[n - 1] == x)
				n--;   // a zero-width gap: join
			else
				out[n++] = (int16_t)x;
			prev = in;
		}
	}
	return n;
}

void rgn_op(Rgn *d, const Rgn *a, const Rgn *b, int op)
{
	// quick cases
	if (op == RGN_SECT && (rgn_empty(a) || rgn_empty(b))) {
		rgn_set_empty(d);
		return;
	}
	if ((op == RGN_UNION || op == RGN_XOR || op == RGN_DIFF) && rgn_empty(b)) {
		rgn_copy(d, a);
		return;
	}
	if ((op == RGN_UNION || op == RGN_XOR) && rgn_empty(a)) {
		rgn_copy(d, b);
		return;
	}
	if (op == RGN_SECT && a->n == 1 && b->n == 1) {
		QRect r = rect_sect(a->r[0], b->r[0]);
		rgn_set_rect(d, r);
		return;
	}
	int maxb = a->n + b->n + 2;
	BandIx *ba = malloc(sizeof(BandIx) * (a->n + 1)), *bb = malloc(sizeof(BandIx) * (b->n + 1));
	int nba = bands(a, ba, a->n + 1), nbb = bands(b, bb, b->n + 1);
	int *ys = malloc(sizeof(int) * 2 * (nba + nbb) + 4);
	int ny = 0;
	for (int i = 0; i < nba; i++) {
		ys[ny++] = ba[i].y0;
		ys[ny++] = ba[i].y1;
	}
	for (int i = 0; i < nbb; i++) {
		ys[ny++] = bb[i].y0;
		ys[ny++] = bb[i].y1;
	}
	qsort(ys, ny, sizeof(int), cmp16);
	int u = 0;
	for (int i = 0; i < ny; i++)
		if (!u || ys[u - 1] != ys[i])
			ys[u++] = ys[i];
	ny = u;
	Rgn out = {{0, 0, 0, 0}, 0, 0, NULL};
	BB build;
	build.g = &out;
	build.open = 0;
	int ia = 0, ib = 0;
	int16_t xa[2048], xb[2048], xr[4096];
	(void)maxb;
	for (int k = 0; k + 1 < ny; k++) {
		int y0 = ys[k], y1 = ys[k + 1];
		while (ia < nba && ba[ia].y1 <= y0)
			ia++;
		while (ib < nbb && bb[ib].y1 <= y0)
			ib++;
		int na = 0, nb = 0;
		if (ia < nba && ba[ia].y0 <= y0)
			for (int t = 0; t < ba[ia].n && na < 2046; t++) {
				xa[na++] = a->r[ba[ia].i + t].left;
				xa[na++] = a->r[ba[ia].i + t].right;
			}
		if (ib < nbb && bb[ib].y0 <= y0)
			for (int t = 0; t < bb[ib].n && nb < 2046; t++) {
				xb[nb++] = b->r[bb[ib].i + t].left;
				xb[nb++] = b->r[bb[ib].i + t].right;
			}
		int nr = combine(xa, na, xb, nb, op, xr);
		if (nr > 1024)
			nr = 1024;
		bb_band(&build, y0, y1, xr, nr);
	}
	bb_flush(&build);
	free(ba);
	free(bb);
	free(ys);
	free(d->r);
	d->r = out.r;
	d->n = out.n;
	d->cap = out.cap;
	bbox(d);
}

void rgn_sect_rect(Rgn *g, QRect r)
{
	Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&t, r);
	rgn_op(g, g, &t, RGN_SECT);
	free(t.r);
}

// erosion (d > 0) or dilation (d < 0) by a rectangle
void rgn_inset(Rgn *g, int dh, int dv)
{
	if (rgn_empty(g))
		return;
	if (g->n == 1) {
		QRect r = g->r[0];
		r.left += dh;
		r.right -= dh;
		r.top += dv;
		r.bottom -= dv;
		rgn_set_rect(g, r);
		return;
	}
	if (dh) {
		Rgn h = {{0, 0, 0, 0}, 0, 0, NULL};
		BB b;
		b.g = &h;
		b.open = 0;
		BandIx *bs = malloc(sizeof(BandIx) * (g->n + 1));
		int nb = bands(g, bs, g->n + 1);
		for (int k = 0; k < nb; k++) {
			int16_t xs[2048], out[2048];
			int n = 0;
			for (int t = 0; t < bs[k].n && n < 2046; t++) {
				int l = g->r[bs[k].i + t].left + dh, r = g->r[bs[k].i + t].right - dh;
				if (r > l) {
					xs[n++] = (int16_t)l;
					xs[n++] = (int16_t)r;
				}
			}
			// dilation can make neighbours overlap: union them
			int m = combine(xs, 0, NULL, 0, RGN_UNION, out);
			(void)m;
			int no = 0;
			for (int i = 0; i < n; i += 2) {
				if (no && out[no - 1] >= xs[i]) {
					if (xs[i + 1] > out[no - 1])
						out[no - 1] = xs[i + 1];
				} else {
					out[no++] = xs[i];
					out[no++] = xs[i + 1];
				}
			}
			bb_band(&b, bs[k].y0, bs[k].y1, out, no);
		}
		bb_flush(&b);
		free(bs);
		free(g->r);
		g->r = h.r;
		g->n = h.n;
		g->cap = h.cap;
		bbox(g);
	}
	if (dv) {
		Rgn acc = {{0, 0, 0, 0}, 0, 0, NULL}, t = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_copy(&acc, g);
		int n = dv > 0 ? dv : -dv;
		for (int s = -n; s <= n; s++) {
			if (!s)
				continue;
			rgn_copy(&t, g);
			rgn_offset(&t, 0, s);
			rgn_op(&acc, &acc, &t, dv > 0 ? RGN_SECT : RGN_UNION);
		}
		free(g->r);
		g->r = acc.r;
		g->n = acc.n;
		g->cap = acc.cap;
		bbox(g);
		free(t.r);
	}
}

int rgn_contains(const Rgn *g, int h, int v)
{
	if (h < g->bbox.left || h >= g->bbox.right || v < g->bbox.top || v >= g->bbox.bottom)
		return 0;
	for (int i = 0; i < g->n; i++) {
		const QRect *r = &g->r[i];
		if (v >= r->top && v < r->bottom && h >= r->left && h < r->right)
			return 1;
	}
	return 0;
}

int rgn_rect_in(const Rgn *g, QRect r)
{
	for (int i = 0; i < g->n; i++)
		if (!rect_empty(rect_sect(g->r[i], r)))
			return 1;
	return 0;
}

int rgn_equal(const Rgn *a, const Rgn *b)
{
	return a->n == b->n && !memcmp(a->r, b->r, a->n * sizeof(QRect));
}

static int16_t mapc(int v, int s0, int s1, int d0, int d1)
{
	if (s1 == s0)
		return (int16_t)d0;
	return (int16_t)(d0 + (int)lround((double)(v - s0) * (d1 - d0) / (s1 - s0)));
}

void rgn_map(Rgn *g, QRect s, QRect d)
{
	for (int i = 0; i < g->n; i++) {
		QRect *r = &g->r[i];
		r->left = mapc(r->left, s.left, s.right, d.left, d.right);
		r->right = mapc(r->right, s.left, s.right, d.left, d.right);
		r->top = mapc(r->top, s.top, s.bottom, d.top, d.bottom);
		r->bottom = mapc(r->bottom, s.top, s.bottom, d.top, d.bottom);
	}
	Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_op(&t, g, &t, RGN_UNION);
	bbox(g);
	free(t.r);
}

// ---- shapes ----------------------------------------------------------------------

void rgn_oval(Rgn *g, QRect r)
{
	RgnBuild b;
	rb_begin(&b, g);
	double cx = (r.left + r.right) / 2.0, cy = (r.top + r.bottom) / 2.0;
	double a = (r.right - r.left) / 2.0, bb = (r.bottom - r.top) / 2.0;
	if (a > 0 && bb > 0)
		for (int y = r.top; y < r.bottom; y++) {
			double dy = (y + 0.5 - cy) / bb;
			double t = 1 - dy * dy;
			if (t < 0)
				continue;
			double w = a * sqrt(t);
			int16_t xs[2] = {(int16_t)floor(cx - w + 0.5), (int16_t)floor(cx + w + 0.5)};
			if (xs[1] > xs[0])
				rb_row(&b, y, xs, 2);
		}
	rb_end(&b);
}

void rgn_roundrect(Rgn *g, QRect r, int ow, int oh)
{
	int w = r.right - r.left, h = r.bottom - r.top;
	if (ow > w)
		ow = w;
	if (oh > h)
		oh = h;
	if (ow <= 0 || oh <= 0) {
		rgn_set_rect(g, r);
		return;
	}
	RgnBuild b;
	rb_begin(&b, g);
	double a = ow / 2.0, bb = oh / 2.0;
	for (int y = r.top; y < r.bottom; y++) {
		double dy = 0;
		if (y < r.top + bb)
			dy = (r.top + bb) - (y + 0.5);
		else if (y >= r.bottom - bb)
			dy = (y + 0.5) - (r.bottom - bb);
		double inset = 0;
		if (dy > 0) {
			double t = 1 - (dy / bb) * (dy / bb);
			inset = t > 0 ? a - a * sqrt(t) : a;
		}
		int16_t xs[2] = {(int16_t)(r.left + floor(inset + 0.5)), (int16_t)(r.right - floor(inset + 0.5))};
		if (xs[1] > xs[0])
			rb_row(&b, y, xs, 2);
	}
	rb_end(&b);
}

void rgn_arc(Rgn *g, QRect r, int start, int arc)
{
	if (arc < 0) {
		start += arc;
		arc = -arc;
	}
	if (arc >= 360) {
		rgn_oval(g, r);
		return;
	}
	start = ((start % 360) + 360) % 360;
	RgnBuild b;
	rb_begin(&b, g);
	double cx = (r.left + r.right) / 2.0, cy = (r.top + r.bottom) / 2.0;
	double a = (r.right - r.left) / 2.0, bb = (r.bottom - r.top) / 2.0;
	if (a > 0 && bb > 0)
		for (int y = r.top; y < r.bottom; y++) {
			double dy = (y + 0.5 - cy) / bb;
			double t = 1 - dy * dy;
			if (t < 0)
				continue;
			double w = a * sqrt(t);
			int x0 = (int)floor(cx - w + 0.5), x1 = (int)floor(cx + w + 0.5);
			int16_t xs[512];
			int n = 0, in = 0;
			for (int x = x0; x < x1; x++) {
				double nx = (x + 0.5 - cx) / a, ny = (cy - (y + 0.5)) / bb;
				double ang = atan2(nx, ny) * 180.0 / M_PI;
				if (ang < 0)
					ang += 360;
				double rel = ang - start;
				if (rel < 0)
					rel += 360;
				int on = rel < arc;
				if (on != in && n < 510) {
					xs[n++] = (int16_t)x;
					in = on;
				}
			}
			if (in)
				xs[n++] = (int16_t)x1;
			if (n)
				rb_row(&b, y, xs, n);
		}
	rb_end(&b);
}

static int cmpd(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

void rgn_poly(Rgn *g, const QPoint *p, int n)
{
	RgnBuild b;
	rb_begin(&b, g);
	if (n < 3) {
		rb_end(&b);
		return;
	}
	int top = p[0].v, bot = p[0].v;
	for (int i = 1; i < n; i++) {
		if (p[i].v < top)
			top = p[i].v;
		if (p[i].v > bot)
			bot = p[i].v;
	}
	double *xs = malloc(sizeof(double) * (n + 1));
	for (int y = top; y < bot; y++) {
		double yc = y + 0.5;
		int k = 0;
		for (int i = 0; i < n; i++) {
			QPoint a = p[i], c = p[(i + 1) % n];
			if ((a.v <= yc && c.v > yc) || (c.v <= yc && a.v > yc))
				xs[k++] = a.h + (yc - a.v) * (c.h - a.h) / (double)(c.v - a.v);
		}
		qsort(xs, k, sizeof(double), cmpd);
		int16_t row[512];
		int m = 0;
		for (int i = 0; i + 1 < k && m < 510; i += 2) {
			int16_t x0 = (int16_t)ceil(xs[i] - 0.5), x1 = (int16_t)ceil(xs[i + 1] - 0.5);
			if (x1 <= x0)
				continue;
			if (m && row[m - 1] >= x0) {
				if (x1 > row[m - 1])
					row[m - 1] = x1;
			} else {
				row[m++] = x0;
				row[m++] = x1;
			}
		}
		if (m)
			rb_row(&b, y, row, m);
	}
	free(xs);
	rb_end(&b);
}

void rgn_line(Rgn *g, QPoint a, QPoint c, int pw, int ph)
{
	RgnBuild b;
	rb_begin(&b, g);
	if (pw <= 0 || ph <= 0) {
		rb_end(&b);
		return;
	}
	int y0 = a.v < c.v ? a.v : c.v, y1 = (a.v > c.v ? a.v : c.v) + ph;
	int rows = y1 - y0;
	int *lo = malloc(sizeof(int) * rows), *hi = malloc(sizeof(int) * rows);
	for (int i = 0; i < rows; i++) {
		lo[i] = 1 << 30;
		hi[i] = -(1 << 30);
	}
	int dx = abs(c.h - a.h), dy = abs(c.v - a.v), sx = a.h < c.h ? 1 : -1, sy = a.v < c.v ? 1 : -1;
	int err = dx - dy, x = a.h, y = a.v;
	for (;;) {
		for (int r = 0; r < ph; r++) {
			int i = y + r - y0;
			if (x < lo[i])
				lo[i] = x;
			if (x + pw > hi[i])
				hi[i] = x + pw;
		}
		if (x == c.h && y == c.v)
			break;
		int e2 = 2 * err;
		if (e2 > -dy) {
			err -= dy;
			x += sx;
		}
		if (e2 < dx) {
			err += dx;
			y += sy;
		}
	}
	for (int i = 0; i < rows; i++)
		if (hi[i] > lo[i]) {
			int16_t xs[2] = {(int16_t)lo[i], (int16_t)hi[i]};
			rb_row(&b, y0 + i, xs, 2);
		}
	free(lo);
	free(hi);
	rb_end(&b);
}

void rgn_frame(Rgn *frame, const Rgn *shape, int pw, int ph)
{
	Rgn in = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_copy(&in, shape);
	rgn_inset(&in, pw, ph);
	rgn_op(frame, shape, &in, RGN_DIFF);
	free(in.r);
}

// ---- guest region handles ------------------------------------------------------------

static HMap rgns;

Rgn *RGN(uint32_t h)
{
	Rgn *g = hm_get(&rgns, h);
	if (!g && is_handle(h) && HSize(h) >= 10) {
		// a region the guest made itself (from a resource or a copy): its bounding box
		g = rgn_new();
		uint32_t p = HP(h);
		rgn_set_rect(g, RECT(p + 2));
		hm_put(&rgns, h, g);
	}
	return g;
}

void rgn_sync(uint32_t h)
{
	Rgn *g = hm_get(&rgns, h);
	if (!g || !is_handle(h))
		return;
	if (HSize(h) < 10)
		HSetSize(h, 10);
	uint32_t p = HP(h);
	ST16(p, g->n <= 1 ? 10 : 10 + 4 * (g->n < 1000 ? g->n : 1000));
	PUTRECT(p + 2, g->n ? g->bbox : (QRect){0, 0, 0, 0});
}

uint32_t rgn_handle(Rgn **out)
{
	uint32_t h = NewHandleClearG(10);
	Rgn *g = rgn_new();
	hm_put(&rgns, h, g);
	rgn_sync(h);
	if (out)
		*out = g;
	return h;
}

void rgn_dispose(uint32_t h)
{
	Rgn *g = hm_get(&rgns, h);
	if (g) {
		hm_del(&rgns, h);
		rgn_free(g);
	}
	DisposeHandleG(h);
}
