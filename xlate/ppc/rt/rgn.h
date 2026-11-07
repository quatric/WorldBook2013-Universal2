// QuickDraw regions: banded lists of rectangles (y-x sorted, no overlaps).
#ifndef RGN_H
#define RGN_H
#include "ppcrt.h"

typedef struct Rgn {
	QRect bbox;
	int n, cap;
	QRect *r;
} Rgn;

Rgn *rgn_new(void);
void rgn_free(Rgn *g);
void rgn_set_empty(Rgn *g);
void rgn_set_rect(Rgn *g, QRect r);
void rgn_copy(Rgn *d, const Rgn *s);
int rgn_empty(const Rgn *g);
void rgn_offset(Rgn *g, int dh, int dv);
enum { RGN_UNION, RGN_SECT, RGN_DIFF, RGN_XOR };
void rgn_op(Rgn *d, const Rgn *a, const Rgn *b, int op);
void rgn_inset(Rgn *g, int dh, int dv);
int rgn_contains(const Rgn *g, int h, int v);
int rgn_rect_in(const Rgn *g, QRect r);
int rgn_equal(const Rgn *a, const Rgn *b);
void rgn_sect_rect(Rgn *g, QRect r);
void rgn_map(Rgn *g, QRect src, QRect dst);

// building regions row by row (rows in increasing y; each row's intervals sorted)
typedef struct { Rgn *g; int y; int n; int16_t xs[512]; } RgnBuild;
void rb_begin(RgnBuild *b, Rgn *g);
void rb_row(RgnBuild *b, int y, const int16_t *xs, int n);   // n endpoints (pairs)
void rb_end(RgnBuild *b);

// shapes
void rgn_oval(Rgn *g, QRect r);
void rgn_roundrect(Rgn *g, QRect r, int ow, int oh);
void rgn_arc(Rgn *g, QRect r, int start, int arc);
void rgn_poly(Rgn *g, const QPoint *pts, int n);
void rgn_line(Rgn *g, QPoint a, QPoint b, int pw, int ph);
void rgn_frame(Rgn *frame, const Rgn *shape, int pw, int ph);   // the shape minus the shape inset by the pen

static inline int rect_empty(QRect r) { return r.bottom <= r.top || r.right <= r.left; }
static inline QRect rect_sect(QRect a, QRect b)
{
	QRect r = {a.top > b.top ? a.top : b.top, a.left > b.left ? a.left : b.left,
		a.bottom < b.bottom ? a.bottom : b.bottom, a.right < b.right ? a.right : b.right};
	if (rect_empty(r))
		r = (QRect){0, 0, 0, 0};
	return r;
}
static inline QRect rect_union(QRect a, QRect b)
{
	if (rect_empty(a))
		return b;
	if (rect_empty(b))
		return a;
	QRect r = {a.top < b.top ? a.top : b.top, a.left < b.left ? a.left : b.left,
		a.bottom > b.bottom ? a.bottom : b.bottom, a.right > b.right ? a.right : b.right};
	return r;
}
static inline QRect rect_off(QRect r, int dh, int dv)
{
	r.left += dh; r.right += dh; r.top += dv; r.bottom += dv;
	return r;
}

// guest RgnHandles: a handle with rgnSize and rgnBBox, and the host region
Rgn *RGN(uint32_t h);              // the region of a guest handle (NULL if none)
uint32_t rgn_handle(Rgn **out);    // a new guest region
void rgn_sync(uint32_t h);         // write size and bounding box to the guest handle
void rgn_dispose(uint32_t h);

#endif
