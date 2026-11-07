// QuickDraw pictures (see pict.h).
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "pict.h"

typedef struct {
	const uint8_t *d;
	uint32_t n, i;
	int v2;
} Rd;

static int ok(Rd *r, uint32_t k) { return r->i + k <= r->n; }
static uint8_t u8(Rd *r) { return ok(r, 1) ? r->d[r->i++] : 0; }
static uint16_t u16(Rd *r)
{
	if (!ok(r, 2)) {
		r->i = r->n;
		return 0;
	}
	uint16_t v = (uint16_t)(r->d[r->i] << 8 | r->d[r->i + 1]);
	r->i += 2;
	return v;
}
static uint32_t u32(Rd *r) { uint32_t a = u16(r); return a << 16 | u16(r); }
static QRect rrect(Rd *r)
{
	QRect q;
	q.top = (int16_t)u16(r);
	q.left = (int16_t)u16(r);
	q.bottom = (int16_t)u16(r);
	q.right = (int16_t)u16(r);
	return q;
}
static QPoint rpt(Rd *r)
{
	QPoint p;
	p.v = (int16_t)u16(r);
	p.h = (int16_t)u16(r);
	return p;
}
static void skip(Rd *r, uint32_t k) { r->i = r->i + k > r->n ? r->n : r->i + k; }

// a region in picture data: size, bbox, and the inversion-point data (we use the box,
// and full region data when it is a plain rectangle)
static void rrgn(Rd *r, Rgn *g)
{
	uint16_t size = u16(r);
	QRect b = rrect(r);
	rgn_set_rect(g, b);
	if (size > 10) {
		// decode the classic region format: per line v, then pairs of h, ended by 0x7fff
		uint32_t end = r->i + size - 10;
		Rgn acc = {{0, 0, 0, 0}, 0, 0, NULL};
		int16_t cur[512];
		int ncur = 0;
		int16_t lasty = b.top;
		RgnBuild rb;
		Rgn out = {{0, 0, 0, 0}, 0, 0, NULL};
		rb_begin(&rb, &out);
		while (r->i + 2 <= end) {
			int16_t y = (int16_t)u16(r);
			if (y == 0x7fff)
				break;
			for (int yy = lasty; yy < y && ncur; yy++)
				rb_row(&rb, yy, cur, ncur);
			lasty = y;
			// toggle the inversion points of this line
			while (r->i + 2 <= end) {
				int16_t x = (int16_t)u16(r);
				if (x == 0x7fff)
					break;
				int k;
				for (k = 0; k < ncur && cur[k] < x; k++)
					;
				if (k < ncur && cur[k] == x) {
					memmove(cur + k, cur + k + 1, (ncur - k - 1) * 2);
					ncur--;
				} else if (ncur < 510) {
					memmove(cur + k + 1, cur + k, (ncur - k) * 2);
					cur[k] = x;
					ncur++;
				}
			}
		}
		rb_end(&rb);
		r->i = end;
		if (out.n) {
			rgn_copy(g, &out);
		}
		free(out.r);
		free(acc.r);
	}
}

// ---- pixel data ------------------------------------------------------------------------------------

static int unpack_bits(Rd *r, uint8_t *out, int want, int unit)
{
	int k = 0;
	while (k < want && ok(r, 1)) {
		int8_t f = (int8_t)u8(r);
		if (f >= 0) {
			int n = (f + 1) * unit;
			for (int i = 0; i < n && ok(r, 1); i++) {
				uint8_t b = u8(r);
				if (k < want)
					out[k] = b;
				k++;
			}
		} else if (f != -128) {
			int n = (-f + 1);
			uint8_t v[2] = {u8(r), unit == 2 ? u8(r) : 0};
			for (int i = 0; i < n; i++)
				for (int j = 0; j < unit; j++) {
					if (k < want)
						out[k] = v[j];
					k++;
				}
		}
	}
	return k;
}

static void rd_rows(Rd *r, int rowBytes, int h, int packType, int pixelSize, uint8_t *dst)
{
	for (int y = 0; y < h && ok(r, 1); y++) {
		uint8_t *row = dst + (size_t)y * rowBytes;
		if (rowBytes < 8 || packType == 1) {
			for (int i = 0; i < rowBytes; i++)
				row[i] = u8(r);
			continue;
		}
		if (pixelSize == 32 && packType == 2) {
			// RGB triples, unpacked
			for (int i = 0; i < rowBytes / 4; i++) {
				row[4 * i] = 0xff;
				row[4 * i + 1] = u8(r);
				row[4 * i + 2] = u8(r);
				row[4 * i + 3] = u8(r);
			}
			continue;
		}
		int bc = rowBytes > 250 ? u16(r) : u8(r);
		Rd sub = {r->d, r->i + bc, r->i, 0};
		if (pixelSize == 16 && packType == 3)
			unpack_bits(&sub, row, rowBytes, 2);
		else
			unpack_bits(&sub, row, rowBytes, 1);
		r->i += bc;
	}
}

// read a BitsRect/PackBitsRect/DirectBitsRect and draw it
static void pixdata(Port *p, Rd *r, int op, QPoint off, double sx, double sy, QRect frame)
{
	int direct = op == 0x9a || op == 0x9b;
	if (direct)
		skip(r, 4);   // baseAddr
	uint16_t rb = u16(r);
	int pixmap = (rb & 0x8000) != 0;
	int rowBytes = rb & 0x3fff;
	QRect bounds = rrect(r);
	int pixelSize = 1, packType = 0, cmpCount = 1;
	uint32_t ctab[256];
	for (int i = 0; i < 256; i++)
		ctab[i] = i ? PIXV(0, 0, 0) : PIXV(255, 255, 255);
	if (pixmap) {
		skip(r, 2);   // pmVersion
		packType = u16(r);
		skip(r, 4 + 4 + 4);   // packSize, hRes, vRes
		skip(r, 2);           // pixelType
		pixelSize = u16(r);
		cmpCount = u16(r);
		skip(r, 2 + 4 + 4 + 4);   // cmpSize, planeBytes, pmTable, pmReserved
		if (!direct) {
			skip(r, 4);   // ctSeed
			uint16_t flags = u16(r);
			int n = (int16_t)u16(r) + 1;
			for (int i = 0; i < n; i++) {
				uint16_t idx = u16(r);
				uint16_t cr = u16(r), cg = u16(r), cb = u16(r);
				int k = (flags & 0x8000) ? i : idx;
				if (k >= 0 && k < 256)
					ctab[k] = PIXV(cr >> 8, cg >> 8, cb >> 8);
			}
		}
	}
	QRect sr = rrect(r), dr = rrect(r);
	int mode = (int16_t)u16(r);
	Rgn mask = {{0, 0, 0, 0}, 0, 0, NULL};
	int has_mask = op == 0x91 || op == 0x99 || op == 0x9b;
	if (has_mask)
		rrgn(r, &mask);
	int w = bounds.right - bounds.left, h = bounds.bottom - bounds.top;
	if (w <= 0 || h <= 0 || rowBytes <= 0) {
		free(mask.r);
		return;
	}
	if (op == 0x90 || op == 0x91)
		packType = 1;   // BitsRect: not packed
	if (pixelSize == 32 && packType == 0)
		packType = 4;
	int planeRow = rowBytes;
	if (pixelSize == 32 && packType == 4)
		planeRow = w * cmpCount;
	uint8_t *raw = calloc((size_t)planeRow * h + 16, 1);
	if (pixelSize == 32 && packType == 4) {
		for (int y = 0; y < h && ok(r, 1); y++) {
			int bc = rowBytes > 250 ? u16(r) : u8(r);
			Rd sub = {r->d, r->i + bc, r->i, 0};
			unpack_bits(&sub, raw + (size_t)y * planeRow, planeRow, 1);
			r->i += bc;
		}
	} else
		rd_rows(r, rowBytes, h, packType, pixelSize, raw);
	if (r->i & 1)
		r->i++;
	// to 32-bit pixels
	uint32_t *px = malloc(sizeof(uint32_t) * w * h);
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			uint8_t *row = raw + (size_t)y * planeRow;
			uint32_t v;
			switch (pixelSize) {
			case 32:
				if (packType == 4) {
					int o = cmpCount == 4 ? w : 0;
					v = PIXV(row[o + x], row[o + w + x], row[o + 2 * w + x]);
				} else
					v = PIXV(row[4 * x + 1], row[4 * x + 2], row[4 * x + 3]);
				break;
			case 16: {
				uint16_t s = (uint16_t)(row[2 * x] << 8 | row[2 * x + 1]);
				int rr = (s >> 10) & 31, gg = (s >> 5) & 31, bb = s & 31;
				v = PIXV(rr << 3 | rr >> 2, gg << 3 | gg >> 2, bb << 3 | bb >> 2);
				break;
			}
			case 8: v = ctab[row[x]]; break;
			case 4: v = ctab[(row[x / 2] >> (x & 1 ? 0 : 4)) & 15]; break;
			case 2: v = ctab[(row[x / 4] >> (6 - 2 * (x & 3))) & 3]; break;
			default: {
				int bit = (row[x / 8] >> (7 - (x & 7))) & 1;
				v = pixmap ? ctab[bit] : (bit ? rgb_pix(p->fg) : rgb_pix(p->bg));
				break;
			}
			}
			px[y * w + x] = v;
		}
	free(raw);
	// destination in port coordinates
	QRect d = {(int16_t)(off.v + lround((dr.top - frame.top) * sy)), (int16_t)(off.h + lround((dr.left - frame.left) * sx)),
		(int16_t)(off.v + lround((dr.bottom - frame.top) * sy)), (int16_t)(off.h + lround((dr.right - frame.left) * sx))};
	Rgn c = {{0, 0, 0, 0}, 0, 0, NULL};
	qd_clip_region(p, &c);
	rgn_sect_rect(&c, d);
	if (has_mask) {
		rgn_offset(&mask, 0, 0);
		Rgn m2 = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_copy(&m2, &mask);
		QRect fs = frame;
		QRect ds = {(int16_t)off.v, (int16_t)off.h, (int16_t)(off.v + lround((frame.bottom - frame.top) * sy)), (int16_t)(off.h + lround((frame.right - frame.left) * sx))};
		rgn_map(&m2, fs, ds);
		rgn_op(&c, &c, &m2, RGN_SECT);
		free(m2.r);
	}
	int sw = sr.right - sr.left, sh = sr.bottom - sr.top, dw = d.right - d.left, dh = d.bottom - d.top;
	uint32_t bg = rgb_pix(p->bg);
	for (int i = 0; i < c.n && sw > 0 && sh > 0 && dw > 0 && dh > 0; i++) {
		QRect q = c.r[i];
		for (int y = q.top; y < q.bottom; y++) {
			int syy = sr.top + (y - d.top) * sh / dh - bounds.top;
			if (syy < 0 || syy >= h)
				continue;
			uint32_t *dst = PIXP(p, q.left, y);
			for (int x = q.left; x < q.right; x++, dst++) {
				int sxx = sr.left + (x - d.left) * sw / dw - bounds.left;
				if (sxx < 0 || sxx >= w)
					continue;
				uint32_t v = px[syy * w + sxx];
				if ((mode == 36 || mode == 1) && (v | 0xff) == (mode == 36 ? bg : PIXV(255, 255, 255)))
					continue;
				*dst = v;
			}
		}
	}
	if (c.n)
		qd_dirty(p, c.bbox);
	free(c.r);
	free(px);
	free(mask.r);
}

// QuickTime-compressed picture data (opcode 0x8200): a JPEG and its placement
static void qt_image(Port *p, Rd *r, uint32_t size, QPoint off, double sx, double sy, QRect frame)
{
	uint32_t start = r->i;
	skip(r, 2);   // version
	// matrix: 3x3 Fixed/Fract
	int32_t m[9];
	for (int i = 0; i < 9; i++)
		m[i] = (int32_t)u32(r);
	uint32_t matteSize = u32(r);
	skip(r, 8);   // matteRect
	skip(r, 2);   // mode
	QRect sr = rrect(r);
	skip(r, 4);   // accuracy
	uint32_t maskSize = u32(r);
	skip(r, matteSize ? matteSize : 0);
	skip(r, maskSize);
	uint32_t idp = r->i;
	uint32_t idSize = u32(r);
	uint32_t codec = u32(r);
	r->i = idp + 44;
	uint32_t dataSize = u32(r);
	r->i = idp + idSize;
	if (ok(r, dataSize) && (codec == 'jpeg' || codec == 'png ' || codec == 'tiff' || codec == 'gif ')) {
		NSData *dat = [NSData dataWithBytes:r->d + r->i length:dataSize];
		CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)dat, NULL);
		CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
		if (img) {
			double a = m[0] / 65536.0, d = m[4] / 65536.0, tx = m[6] / 65536.0, ty = m[7] / 65536.0;
			QRect pr = {(int16_t)(sr.top * d + ty), (int16_t)(sr.left * a + tx), (int16_t)(sr.bottom * d + ty), (int16_t)(sr.right * a + tx)};
			QRect dst = {(int16_t)(off.v + lround((pr.top - frame.top) * sy)), (int16_t)(off.h + lround((pr.left - frame.left) * sx)),
				(int16_t)(off.v + lround((pr.bottom - frame.top) * sy)), (int16_t)(off.h + lround((pr.right - frame.left) * sx))};
			qd_draw_image(p, img, dst);
			CGImageRelease(img);
		}
		if (src)
			CFRelease(src);
	} else if (codec)
		ppc_log("PICT: QuickTime codec '%.4s' not drawn", (char *)&(uint32_t){__builtin_bswap32(codec)});
	r->i = start + size;
}

// ---- the interpreter -------------------------------------------------------------------------------------

typedef struct {
	QPoint pnLoc, pnSize;
	int pnMode, txFont, txFace, txMode, txSize, spExtra;
	uint8_t pnPat[8], bkPat[8], fillPat[8];
	RGB16 fg, bg;
	Rgn clip;
} Saved;

static QRect xr(QRect q, QPoint off, double sx, double sy, QRect f)
{
	return (QRect){(int16_t)(off.v + lround((q.top - f.top) * sy)), (int16_t)(off.h + lround((q.left - f.left) * sx)),
		(int16_t)(off.v + lround((q.bottom - f.top) * sy)), (int16_t)(off.h + lround((q.right - f.left) * sx))};
}
static QPoint xp(QPoint q, QPoint off, double sx, double sy, QRect f)
{
	return (QPoint){(int16_t)(off.v + lround((q.v - f.top) * sy)), (int16_t)(off.h + lround((q.h - f.left) * sx))};
}

void pict_draw(Port *p, const uint8_t *data, uint32_t len, QRect dst)
{
	if (!p || !p->pix || len < 12)
		return;
	Rd r = {data, len, 2, 0};
	QRect frame = rrect(&r);
	double sx = frame.right > frame.left ? (double)(dst.right - dst.left) / (frame.right - frame.left) : 1;
	double sy = frame.bottom > frame.top ? (double)(dst.bottom - dst.top) / (frame.bottom - frame.top) : 1;
	QPoint off = {dst.top, dst.left};
	Saved s;
	s.pnLoc = p->pnLoc;
	s.pnSize = p->pnSize;
	s.pnMode = p->pnMode;
	s.txFont = p->txFont;
	s.txFace = p->txFace;
	s.txMode = p->txMode;
	s.txSize = p->txSize;
	s.spExtra = p->spExtra;
	memcpy(s.pnPat, p->pnPat, 8);
	memcpy(s.bkPat, p->bkPat, 8);
	memcpy(s.fillPat, p->fillPat, 8);
	s.fg = p->fg;
	s.bg = p->bg;
	memset(&s.clip, 0, sizeof s.clip);
	rgn_copy(&s.clip, p->clip);
	p->pnLoc = (QPoint){0, 0};
	p->pnSize = (QPoint){1, 1};
	p->pnMode = 8;
	memset(p->pnPat, 0xff, 8);
	memset(p->fillPat, 0xff, 8);
	memset(p->bkPat, 0, 8);
	p->txFont = 0;
	p->txFace = 0;
	p->txMode = 1;
	p->txSize = 0;
	p->fg = (RGB16){0, 0, 0};
	p->bg = (RGB16){0xffff, 0xffff, 0xffff};
	rgn_sect_rect(p->clip, dst);
	QRect lastRect = {0, 0, 0, 0}, lastOval = {0, 0, 0, 0}, lastRRect = {0, 0, 0, 0}, lastArc = {0, 0, 0, 0};
	QPoint ovSize = {0, 0};
	int16_t arcStart = 0, arcAngle = 0;
	QPoint textOrigin = {0, 0};
	// version
	if (r.i + 2 <= len && data[r.i] == 0x11 && data[r.i + 1] == 0x01) {
		r.i += 2;
		r.v2 = 0;
	} else if (r.i + 4 <= len && data[r.i] == 0 && data[r.i + 1] == 0x11 && data[r.i + 2] == 0x02) {
		r.i += 4;
		r.v2 = 1;
	}
	int guard = 0;
	while (ok(&r, 1) && guard++ < 200000) {
		if (r.v2 && (r.i & 1))
			r.i++;
		uint16_t op = r.v2 ? u16(&r) : u8(&r);
		Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
		int verb = -1;
		switch (op) {
		case 0x0000: break;
		case 0x0001: {
			Rgn c = {{0, 0, 0, 0}, 0, 0, NULL};
			rrgn(&r, &c);
			QRect cb = c.n ? c.bbox : (QRect){0, 0, 0, 0};
			rgn_set_rect(p->clip, xr(cb, off, sx, sy, frame));
			rgn_op(p->clip, p->clip, &s.clip, RGN_SECT);
			rgn_sect_rect(p->clip, dst);
			free(c.r);
			break;
		}
		case 0x0002: for (int i = 0; i < 8; i++) p->bkPat[i] = u8(&r); break;
		case 0x0003: p->txFont = (int16_t)u16(&r); break;
		case 0x0004: p->txFace = u8(&r); break;
		case 0x0005: p->txMode = (int16_t)u16(&r); break;
		case 0x0006: p->spExtra = (int32_t)u32(&r); break;
		case 0x0007: p->pnSize = rpt(&r); break;
		case 0x0008: p->pnMode = (int16_t)u16(&r); break;
		case 0x0009: for (int i = 0; i < 8; i++) p->pnPat[i] = u8(&r); break;
		case 0x000a: for (int i = 0; i < 8; i++) p->fillPat[i] = u8(&r); break;
		case 0x000b: ovSize = rpt(&r); break;
		case 0x000c: skip(&r, 4); break;
		case 0x000d: p->txSize = (int16_t)lround((int16_t)u16(&r) * sy); break;
		case 0x000e: {
			uint32_t k = u32(&r);
			extern void qd_classic_color(int32_t k, RGB16 *out);
			qd_classic_color((int32_t)k, &p->fg);
			break;
		}
		case 0x000f: {
			uint32_t k = u32(&r);
			extern void qd_classic_color(int32_t k, RGB16 *out);
			qd_classic_color((int32_t)k, &p->bg);
			break;
		}
		case 0x0010: skip(&r, 8); break;
		case 0x0011: skip(&r, r.v2 ? 2 : 1); break;
		case 0x0012: case 0x0013: case 0x0014: {
			// PixPat: type, pattern; for type 1 (full color) a pixmap follows: draw with the old-style pattern
			uint16_t type = u16(&r);
			uint8_t pat[8];
			for (int i = 0; i < 8; i++)
				pat[i] = u8(&r);
			if (type == 1) {
				// pixmap record and data: skip it
				skip(&r, 4);   // baseAddr placeholder
				uint16_t rb = u16(&r) & 0x3fff;
				QRect b = rrect(&r);
				skip(&r, 2 + 2 + 4 + 4 + 4 + 2);
				int ps = u16(&r);
				skip(&r, 2 + 2 + 4 + 4 + 4);
				skip(&r, 4);
				u16(&r);
				int n = (int16_t)u16(&r) + 1;
				skip(&r, 8 * n);
				uint8_t *tmp = malloc((size_t)rb * (b.bottom - b.top) + 16);
				rd_rows(&r, rb, b.bottom - b.top, 0, ps, tmp);
				free(tmp);
			} else if (type == 2)
				skip(&r, 6);   // RGB
			uint8_t *t = op == 0x12 ? p->bkPat : op == 0x13 ? p->pnPat : p->fillPat;
			memcpy(t, pat, 8);
			break;
		}
		case 0x0015: case 0x0016: skip(&r, 2); break;
		case 0x0017: case 0x0018: case 0x0019: break;
		case 0x001a: p->fg = (RGB16){u16(&r), u16(&r), u16(&r)}; break;
		case 0x001b: p->bg = (RGB16){u16(&r), u16(&r), u16(&r)}; break;
		case 0x001c: break;
		case 0x001d: p->hilite = (RGB16){u16(&r), u16(&r), u16(&r)}; break;
		case 0x001e: break;
		case 0x001f: p->op = (RGB16){u16(&r), u16(&r), u16(&r)}; break;
		case 0x0020: case 0x0021: case 0x0022: case 0x0023: {
			QPoint a = p->pnLoc, b;
			if (op == 0x20) {
				a = rpt(&r);
				b = rpt(&r);
				a = xp(a, off, sx, sy, frame);
				b = xp(b, off, sx, sy, frame);
			} else if (op == 0x21) {
				b = xp(rpt(&r), off, sx, sy, frame);
			} else if (op == 0x22) {
				a = xp(rpt(&r), off, sx, sy, frame);
				int8_t dh = (int8_t)u8(&r), dv = (int8_t)u8(&r);
				b = (QPoint){(int16_t)(a.v + lround(dv * sy)), (int16_t)(a.h + lround(dh * sx))};
			} else {
				int8_t dh = (int8_t)u8(&r), dv = (int8_t)u8(&r);
				b = (QPoint){(int16_t)(a.v + lround(dv * sy)), (int16_t)(a.h + lround(dh * sx))};
			}
			rgn_line(&g, a, b, p->pnSize.h, p->pnSize.v);
			qd_fill(p, &g, qd_pen(p));
			p->pnLoc = b;
			break;
		}
		case 0x0028: case 0x0029: case 0x002a: case 0x002b: {
			if (op == 0x28)
				textOrigin = rpt(&r);
			else if (op == 0x29)
				textOrigin.h += (int8_t)u8(&r);
			else if (op == 0x2a)
				textOrigin.v += (int8_t)u8(&r);
			else {
				if (r.v2)
					skip(&r, 2);
				textOrigin.h += u8(&r);
				textOrigin.v += u8(&r);
			}
			int n = u8(&r);
			if (ok(&r, n)) {
				p->pnLoc = xp(textOrigin, off, sx, sy, frame);
				qd_text_draw(p, r.d + r.i, n);
			}
			skip(&r, n);
			break;
		}
		case 0x002c: {
			uint16_t l = u16(&r);
			uint32_t e = r.i + l;
			int16_t num = (int16_t)u16(&r);
			int nl = u8(&r);
			if (ok(&r, nl)) {
				NSString *nm = mac_ns(r.d + r.i, nl);
				(void)num;
				p->txFont = qd_font_num(nm);
			}
			r.i = e;
			break;
		}
		case 0x0030: case 0x0031: case 0x0032: case 0x0033: case 0x0034:
			lastRect = rrect(&r);
			/* fallthrough */
		case 0x0038: case 0x0039: case 0x003a: case 0x003b: case 0x003c:
			rgn_set_rect(&g, xr(lastRect, off, sx, sy, frame));
			verb = op & 7;
			break;
		case 0x0040: case 0x0041: case 0x0042: case 0x0043: case 0x0044:
			lastRRect = rrect(&r);
			/* fallthrough */
		case 0x0048: case 0x0049: case 0x004a: case 0x004b: case 0x004c:
			rgn_roundrect(&g, xr(lastRRect, off, sx, sy, frame), (int)lround(ovSize.h * sx), (int)lround(ovSize.v * sy));
			verb = op & 7;
			break;
		case 0x0050: case 0x0051: case 0x0052: case 0x0053: case 0x0054:
			lastOval = rrect(&r);
			/* fallthrough */
		case 0x0058: case 0x0059: case 0x005a: case 0x005b: case 0x005c:
			rgn_oval(&g, xr(lastOval, off, sx, sy, frame));
			verb = op & 7;
			break;
		case 0x0060: case 0x0061: case 0x0062: case 0x0063: case 0x0064:
			lastArc = rrect(&r);
			/* fallthrough */
		case 0x0068: case 0x0069: case 0x006a: case 0x006b: case 0x006c:
			arcStart = (int16_t)u16(&r);
			arcAngle = (int16_t)u16(&r);
			if ((op & 7) == 0) {
				Rgn o = {{0, 0, 0, 0}, 0, 0, NULL}, w = {{0, 0, 0, 0}, 0, 0, NULL};
				QRect ar = xr(lastArc, off, sx, sy, frame);
				rgn_oval(&o, ar);
				rgn_frame(&g, &o, p->pnSize.h, p->pnSize.v);
				rgn_arc(&w, ar, arcStart, arcAngle);
				rgn_op(&g, &g, &w, RGN_SECT);
				qd_fill(p, &g, qd_pen(p));
				free(o.r);
				free(w.r);
			} else {
				rgn_arc(&g, xr(lastArc, off, sx, sy, frame), arcStart, arcAngle);
				verb = op & 7;
			}
			break;
		case 0x0070: case 0x0071: case 0x0072: case 0x0073: case 0x0074: {
			uint16_t size = u16(&r);
			skip(&r, 8);
			int n = (size - 10) / 4;
			QPoint *pts = malloc(sizeof(QPoint) * (n + 1));
			for (int i = 0; i < n; i++)
				pts[i] = xp(rpt(&r), off, sx, sy, frame);
			if ((op & 7) == 0) {
				for (int i = 1; i < n; i++) {
					Rgn l = {{0, 0, 0, 0}, 0, 0, NULL};
					rgn_line(&l, pts[i - 1], pts[i], p->pnSize.h, p->pnSize.v);
					qd_fill(p, &l, qd_pen(p));
					free(l.r);
				}
			} else {
				rgn_poly(&g, pts, n);
				verb = op & 7;
			}
			free(pts);
			break;
		}
		case 0x0078: case 0x0079: case 0x007a: case 0x007b: case 0x007c: break;
		case 0x0080: case 0x0081: case 0x0082: case 0x0083: case 0x0084: {
			Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
			rrgn(&r, &t);
			QRect fs = frame, ds = {(int16_t)off.v, (int16_t)off.h, (int16_t)(off.v + lround((frame.bottom - frame.top) * sy)),
				(int16_t)(off.h + lround((frame.right - frame.left) * sx))};
			rgn_map(&t, fs, ds);
			rgn_copy(&g, &t);
			free(t.r);
			verb = op & 7;
			break;
		}
		case 0x0088: case 0x0089: case 0x008a: case 0x008b: case 0x008c: break;
		case 0x0090: case 0x0091: case 0x0098: case 0x0099: case 0x009a: case 0x009b:
			pixdata(p, &r, op, off, sx, sy, frame);
			break;
		case 0x00a0: skip(&r, 2); break;
		case 0x00a1: {
			skip(&r, 2);
			uint16_t l = u16(&r);
			skip(&r, l);
			break;
		}
		case 0x00ff: r.i = r.n; break;
		case 0x0c00: skip(&r, 24); break;
		case 0x8200: {
			uint32_t size = u32(&r);
			qt_image(p, &r, size, off, sx, sy, frame);
			break;
		}
		case 0x8201: { uint32_t size = u32(&r); skip(&r, size); break; }
		default:
			if (!r.v2) {
				ppc_log("PICT v1 opcode %02x: stop", op);
				r.i = r.n;
			} else if ((op >= 0x24 && op <= 0x27) || op == 0x2d || op == 0x2e || op == 0x2f || (op >= 0x92 && op <= 0x97) ||
				(op >= 0x9c && op <= 0x9f) || (op >= 0xa2 && op <= 0xaf)) {
				skip(&r, u16(&r));
			} else if ((op >= 0x35 && op <= 0x37) || (op >= 0x45 && op <= 0x47) || (op >= 0x55 && op <= 0x57)) {
				skip(&r, 8);
			} else if (op >= 0x65 && op <= 0x67) {
				skip(&r, 12);
			} else if (op >= 0x6d && op <= 0x6f) {
				skip(&r, 4);
			} else if ((op >= 0x75 && op <= 0x77) || (op >= 0x85 && op <= 0x87)) {
				skip(&r, u16(&r) - 2);
			} else if (op >= 0xd0 && op <= 0xfe) {
				skip(&r, u32(&r));
			} else if (op >= 0x100 && op <= 0x7fff) {
				skip(&r, (op >> 8) * 2);
			} else if (op >= 0x8100) {
				skip(&r, u32(&r));
			}
			break;
		}
		if (verb >= 0) {
			switch (verb) {
			case 0: {
				Rgn f = {{0, 0, 0, 0}, 0, 0, NULL};
				rgn_frame(&f, &g, p->pnSize.h, p->pnSize.v);
				qd_fill(p, &f, qd_pen(p));
				free(f.r);
				break;
			}
			case 1: qd_fill(p, &g, qd_pen(p)); break;
			case 2: qd_fill(p, &g, qd_back(p)); break;
			case 3: {
				static const uint8_t black[8] = {255, 255, 255, 255, 255, 255, 255, 255};
				qd_fill(p, &g, (Paint){black, p->fg, p->bg, 10});
				break;
			}
			case 4: qd_fill(p, &g, (Paint){p->fillPat, p->fg, p->bg, 8}); break;
			}
		}
		free(g.r);
	}
	p->pnLoc = s.pnLoc;
	p->pnSize = s.pnSize;
	p->pnMode = s.pnMode;
	p->txFont = s.txFont;
	p->txFace = s.txFace;
	p->txMode = s.txMode;
	p->txSize = s.txSize;
	p->spExtra = s.spExtra;
	memcpy(p->pnPat, s.pnPat, 8);
	memcpy(p->bkPat, s.bkPat, 8);
	memcpy(p->fillPat, s.fillPat, 8);
	p->fg = s.fg;
	p->bg = s.bg;
	rgn_copy(p->clip, &s.clip);
	free(s.clip.r);
}

CGImageRef pict_image(const uint8_t *data, uint32_t len)
{
	if (len < 10)
		return NULL;
	QRect f = {(int16_t)(data[2] << 8 | data[3]), (int16_t)(data[4] << 8 | data[5]), (int16_t)(data[6] << 8 | data[7]),
		(int16_t)(data[8] << 8 | data[9])};
	int w = f.right - f.left, h = f.bottom - f.top;
	if (w <= 0 || h <= 0 || w > 8000 || h > 8000)
		return NULL;
	Port *p = port_new(0, 0, (QRect){0, 0, (int16_t)h, (int16_t)w}, 1);
	pict_draw(p, data, len, (QRect){0, 0, (int16_t)h, (int16_t)w});
	CGContextRef cg = qd_cg_begin(p);
	qd_cg_end(p);
	CGImageRef img = CGBitmapContextCreateImage(cg);
	gfree(p->pix);
	port_free(p);
	return img;
}

// ---- recording ------------------------------------------------------------------------------------------

static QDPict *recording;

void pict_mirror_fill(Port *p, const Rgn *shape, Paint pt)
{
	QDPict *pic = p->rec_pic;
	p->rec_pic = NULL;
	qd_fill(pic->shadow, shape, pt);
	p->rec_pic = pic;
}

void pict_mirror_text(Port *p, const uint8_t *s, int n)
{
	QDPict *pic = p->rec_pic;
	Port *sh = pic->shadow;
	sh->txFont = p->txFont;
	sh->txFace = p->txFace;
	sh->txSize = p->txSize;
	sh->txMode = p->txMode;
	sh->fg = p->fg;
	sh->bg = p->bg;
	sh->spExtra = p->spExtra;
	sh->pnLoc = p->pnLoc;
	qd_text_draw(sh, s, n);
}

void pict_mirror_copybits(Port *p, uint32_t src, QRect sr, QRect dr, int mode, Rgn *mask)
{
	QDPict *pic = p->rec_pic;
	p->rec_pic = NULL;
	Port *save = qd_port;
	qd_port = pic->shadow;
	qd_copybits(src, pic->shadow->pixmap_ptr, sr, dr, mode, mask);
	qd_port = save;
	p->rec_pic = pic;
}

static void sh_OpenPicture(PPC *c)
{
	Port *p = qd_port;
	QRect f = RECT(A(0));
	QDPict *pic = calloc(1, sizeof *pic);
	pic->frame = f;
	pic->shadow = port_new(0, 0, f, 1);
	pic->h = NewHandleClearG(10);
	ST16(HP(pic->h), 10);
	PUTRECT(HP(pic->h) + 2, f);
	if (p)
		p->rec_pic = pic;
	recording = pic;
	RET(pic->h);
}

static void put16(NSMutableData *d, uint16_t v) { uint8_t b[2] = {v >> 8, (uint8_t)v}; [d appendBytes:b length:2]; }
static void put32(NSMutableData *d, uint32_t v) { put16(d, v >> 16); put16(d, (uint16_t)v); }

static void sh_ClosePicture(PPC *c)
{
	Port *p = qd_port;
	QDPict *pic = recording;
	if (!pic)
		return;
	if (p && p->rec_pic == pic)
		p->rec_pic = NULL;
	recording = NULL;
	QRect f = pic->frame;
	int w = f.right - f.left, h = f.bottom - f.top;
	NSMutableData *d = [NSMutableData data];
	put16(d, 0);
	put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right);
	put16(d, 0x0011); put16(d, 0x02ff);
	put16(d, 0x0c00); put16(d, 0xfffe); put16(d, 0); put32(d, 0x00480000); put32(d, 0x00480000);
	put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right); put32(d, 0);
	put16(d, 0x001e);
	put16(d, 0x0001); put16(d, 10); put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right);
	// DirectBitsRect, unpacked 32-bit
	put16(d, 0x009a);
	put32(d, 0xff);
	int rb = w * 4;
	put16(d, 0x8000 | rb);
	put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right);
	put16(d, 0); put16(d, 1); put32(d, 0); put32(d, 0x00480000); put32(d, 0x00480000);
	put16(d, 16); put16(d, 32); put16(d, 3); put16(d, 8); put32(d, 0); put32(d, 0); put32(d, 0);
	put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right);
	put16(d, f.top); put16(d, f.left); put16(d, f.bottom); put16(d, f.right);
	put16(d, 0);
	Port *sh = pic->shadow;
	for (int y = 0; y < h; y++)
		[d appendBytes:G(sh->pix + y * sh->rowBytes) length:rb];
	if (d.length & 1)
		[d appendBytes:"" length:1];
	put16(d, 0x00ff);
	uint8_t *b = d.mutableBytes;
	uint16_t sz = d.length > 0xffff ? 0xffff : (uint16_t)d.length;
	b[0] = sz >> 8;
	b[1] = (uint8_t)sz;
	HSetSize(pic->h, (uint32_t)d.length);
	memcpy(G(HP(pic->h)), d.bytes, d.length);
	gfree(sh->pix);
	port_free(sh);
	free(pic);
}

static void sh_KillPicture(PPC *c) { DisposeHandleG(A(0)); }

static void sh_DrawPicture(PPC *c)
{
	uint32_t h = A(0);
	if (!is_handle(h) || !HP(h) || !qd_port)
		return;
	pict_draw(qd_port, G(HP(h)), HSize(h), RECT(A(1)));
}

static const ShimDef pictshims[] = {S(OpenPicture), S(ClosePicture), S(KillPicture), S(DrawPicture)};
REGISTER(pictshims)
