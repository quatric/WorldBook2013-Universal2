// QuickDraw (see qd.h): ports, GWorlds, drawing, regions, text, CopyBits,
// cursors, devices.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include "qd.h"
#include "hmap.h"
#include "win.h"
#include "pict.h"

Port *qd_port;
static Port *screen_port;   // the port of the whole screen (GetWMgrPort-like default)
int qd_menubar_height = 22;
static int16_t qd_err;
static HMap ports_by_pix;   // pixmap pointer -> Port

enum { TAG_PORT = 'port' };

// ---- screen ---------------------------------------------------------------------

static double main_h(void) { return NSScreen.screens.count ? NSScreen.screens[0].frame.size.height : 900; }
int qd_global_y(double y) { return (int)lround(main_h() - y); }
double qd_cocoa_y(int v) { return main_h() - v; }

QRect qd_screen_rect(void)
{
	NSRect f = NSScreen.screens.count ? NSScreen.screens[0].frame : NSMakeRect(0, 0, 1440, 900);
	return (QRect){0, 0, (int16_t)f.size.height, (int16_t)f.size.width};
}

// ---- ports ----------------------------------------------------------------------------

static void pixmap_write(Port *p)
{
	uint32_t pm = HP(p->pixmap);
	if (p->shadow) {
		ST32(pm, p->shadow);
		ST16(pm + 4, 0x8000 | (p->srow & 0x3fff));
		PUTRECT(pm + 6, p->bounds);
		ST16(pm + 14, 0);
		ST16(pm + 16, 0);
		ST32(pm + 18, 0);
		ST32(pm + 22, 72 << 16);
		ST32(pm + 26, 72 << 16);
		ST16(pm + 30, p->sdepth == 16 ? 16 : 0);
		ST16(pm + 32, p->sdepth);
		ST16(pm + 34, p->sdepth == 16 ? 3 : 1);
		ST16(pm + 36, p->sdepth == 16 ? 5 : p->sdepth);
		ST32(pm + 38, 0);
		ST32(pm + 42, p->sctab);
		ST32(pm + 46, 0);
		return;
	}
	ST32(pm, p->pix);
	ST16(pm + 4, 0x8000 | (p->rowBytes & 0x3fff));
	PUTRECT(pm + 6, p->bounds);
	ST16(pm + 14, 0);           // pmVersion
	ST16(pm + 16, 0);           // packType
	ST32(pm + 18, 0);
	ST32(pm + 22, 72 << 16);    // hRes
	ST32(pm + 26, 72 << 16);
	ST16(pm + 30, 16);          // RGBDirect
	ST16(pm + 32, 32);          // pixelSize
	ST16(pm + 34, 3);           // cmpCount
	ST16(pm + 36, 8);           // cmpSize
	ST32(pm + 38, 'ARGB');      // pixelFormat (Carbon)
	ST32(pm + 42, 0);
	ST32(pm + 46, 0);
}

void port_sync_pixmap(Port *p) { pixmap_write(p); }

static void port_tok_write(Port *p)
{
	// the CGrafPort fields some code reads: portPixMap (+2), portRect (+16)
	ST16(p->tok, 0xc000);
	ST32(p->tok + 2, p->pixmap);
	PUTRECT(p->tok + 16, p->portRect);
}

Port *port_new(uint32_t pix, int32_t rowBytes, QRect bounds, int own)
{
	Port *p = calloc(1, sizeof *p);
	int w = bounds.right - bounds.left, h = bounds.bottom - bounds.top;
	if (!pix && own) {
		rowBytes = ((w > 0 ? w : 1) * 4 + 15) & ~15;
		pix = gmalloc((uint32_t)(rowBytes * (h > 0 ? h : 1)));
		uint32_t *px = G(pix);
		for (int i = 0; i < rowBytes / 4 * (h > 0 ? h : 1); i++)
			px[i] = PIXV(255, 255, 255);
	}
	p->pix = pix;
	p->rowBytes = rowBytes;
	p->bounds = bounds;
	p->portRect = bounds;
	p->vis = rgn_new();
	p->clip = rgn_new();
	rgn_set_rect(p->vis, bounds);
	rgn_set_rect(p->clip, (QRect){-32767, -32767, 32767, 32767});
	p->pnSize = (QPoint){1, 1};
	p->pnMode = 8;
	memset(p->pnPat, 0xff, 8);
	memset(p->fillPat, 0xff, 8);
	memset(p->bkPat, 0, 8);
	p->fg = (RGB16){0, 0, 0};
	p->bg = (RGB16){0xffff, 0xffff, 0xffff};
	p->hilite = (RGB16){0xb5b5, 0xd5d5, 0xffff};
	p->op = (RGB16){0x8000, 0x8000, 0x8000};
	p->txFont = 0;
	p->txSize = 0;
	p->txMode = 1;
	p->pixmap = NewHandleClearG(50);
	p->pixmap_ptr = HP(p->pixmap);
	pixmap_write(p);
	p->tok = tok_new(p, 108, TAG_PORT);
	port_tok_write(p);
	hm_put(&ports_by_pix, p->pixmap_ptr, p);
	return p;
}

void port_free(Port *p)
{
	if (!p)
		return;
	if (qd_port == p)
		qd_port = screen_port;
	if (p->cg)
		CGContextRelease(p->cg);
	hm_del(&ports_by_pix, p->pixmap_ptr);
	rgn_free(p->vis);
	rgn_free(p->clip);
	DisposeHandleG(p->pixmap);
	tok_free(p->tok);
	free(p);
}

void port_resize(Port *p, QRect r)
{
	int w = r.right - r.left, h = r.bottom - r.top;
	int rb = ((w > 0 ? w : 1) * 4 + 15) & ~15;
	uint32_t np = gmalloc((uint32_t)(rb * (h > 0 ? h : 1)));
	uint32_t *px = G(np);
	for (int i = 0; i < rb / 4 * (h > 0 ? h : 1); i++)
		px[i] = rgb_pix(p->bg);
	// keep the old contents where they overlap
	int ow = p->bounds.right - p->bounds.left, oh = p->bounds.bottom - p->bounds.top;
	for (int y = 0; y < h && y < oh; y++)
		memcpy(G(np + y * rb), G(p->pix + y * p->rowBytes), 4 * (w < ow ? w : ow));
	gfree(p->pix);
	p->pix = np;
	p->rowBytes = rb;
	int dh = r.left - p->bounds.left, dv = r.top - p->bounds.top;
	(void)dh;
	(void)dv;
	p->bounds = r;
	p->portRect = r;
	rgn_set_rect(p->vis, r);
	pixmap_write(p);
	port_tok_write(p);
}

Port *PORT(uint32_t tok)
{
	if (!tok)
		return NULL;
	Port *p = tok_get(tok, TAG_PORT);
	if (!p) {
		// a WindowRef where a port was meant
		Win *w = WIN(tok);
		if (w)
			return w->port;
	}
	return p;
}

// ---- clipping and painting ----------------------------------------------------------

void qd_clip_region(Port *p, Rgn *out)
{
	rgn_op(out, p->clip, p->vis, RGN_SECT);
	rgn_sect_rect(out, p->bounds);
}

void qd_dirty(Port *p, QRect r)
{
	if (p->shadow)
		p->shadow_state = 0;
	if (p->win)
		win_dirty(p->win, r);
}

Paint qd_pen(Port *p) { return (Paint){p->pnPat, p->fg, p->bg, p->pnMode}; }
Paint qd_back(Port *p) { return (Paint){p->bkPat, p->bg, p->bg, 8}; }
Paint qd_solid(Port *p, const uint8_t *pat) { return (Paint){pat, p->fg, p->bg, 8}; }

static inline uint32_t invert(uint32_t v) { return v ^ 0xffffff00u; }

static void fill_span(Port *p, int y, int x0, int x1, Paint *pt, uint32_t fg, uint32_t bg, int solid)
{
	uint32_t *row = PIXP(p, x0, y);
	int by = (y - p->bounds.top) & 7;
	uint8_t bits = pt->pat[by];
	int mode = pt->mode;
	if (solid && (mode == 8)) {
		for (int x = x0; x < x1; x++)
			*row++ = fg;
		return;
	}
	uint32_t hil = rgb_pix(p->hilite);
	for (int x = x0; x < x1; x++, row++) {
		int bit = (bits >> (7 - ((x - p->bounds.left) & 7))) & 1;
		switch (mode) {
		case 8: *row = bit ? fg : bg; break;                       // patCopy
		case 9: if (bit) *row = fg; break;                         // patOr
		case 10: if (bit) *row = invert(*row); break;              // patXor
		case 11: if (bit) *row = bg; break;                        // patBic
		case 12: *row = bit ? bg : fg; break;
		case 13: if (!bit) *row = fg; break;
		case 14: if (!bit) *row = invert(*row); break;
		case 15: if (!bit) *row = bg; break;
		case 50:                                                    // hilite
			if (bit) {
				if (*row == bg)
					*row = hil;
				else if (*row == hil)
					*row = bg;
			}
			break;
		case 32: {   // blend
			if (bit) {
				uint32_t d = *row;
				int r = (((d >> 8) & 255) + ((fg >> 8) & 255)) / 2, g = (((d >> 16) & 255) + ((fg >> 16) & 255)) / 2,
				    b = (((d >> 24) & 255) + ((fg >> 24) & 255)) / 2;
				*row = PIXV(r, g, b);
			}
			break;
		}
		default: if (bit) *row = fg; else if (mode < 8 || mode == 36) {} else *row = bg; break;
		}
	}
}

void qd_fill(Port *p, const Rgn *shape, Paint pt)
{
	if (!p || !p->pix)
		return;
	if (p->rec_pic)
		pict_mirror_fill(p, shape, pt);
	Rgn c = {{0, 0, 0, 0}, 0, 0, NULL};
	qd_clip_region(p, &c);
	rgn_op(&c, &c, shape, RGN_SECT);
	uint32_t fg = rgb_pix(pt.fg), bg = rgb_pix(pt.bg);
	int solid = 1;
	for (int i = 0; i < 8; i++)
		if (pt.pat[i] != 0xff)
			solid = 0;
	for (int i = 0; i < c.n; i++) {
		QRect r = c.r[i];
		for (int y = r.top; y < r.bottom; y++)
			fill_span(p, y, r.left, r.right, &pt, fg, bg, solid);
	}
	if (c.n)
		qd_dirty(p, c.bbox);
	free(c.r);
}

void qd_fill_rect(Port *p, QRect r, Paint pt)
{
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&g, r);
	qd_fill(p, &g, pt);
	free(g.r);
}

// ---- Core Graphics over a port ------------------------------------------------------------

CGContextRef qd_cg_begin(Port *p)
{
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	if (!p->cg || p->cg_pix != p->pix || (int)CGBitmapContextGetWidth(p->cg) != w || (int)CGBitmapContextGetHeight(p->cg) != h) {
		if (p->cg)
			CGContextRelease(p->cg);
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		p->cg = CGBitmapContextCreate(G(p->pix), w > 0 ? w : 1, h > 0 ? h : 1, 8, p->rowBytes, cs,
			kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big);
		CGColorSpaceRelease(cs);
		p->cg_pix = p->pix;
	}
	CGContextRef cg = p->cg;
	CGContextSaveGState(cg);
	CGContextTranslateCTM(cg, -p->bounds.left, h + p->bounds.top);
	CGContextScaleCTM(cg, 1, -1);
	Rgn c = {{0, 0, 0, 0}, 0, 0, NULL};
	qd_clip_region(p, &c);
	if (c.n) {
		CGRect *rs = malloc(sizeof(CGRect) * c.n);
		for (int i = 0; i < c.n; i++)
			rs[i] = CGRectMake(c.r[i].left, c.r[i].top, c.r[i].right - c.r[i].left, c.r[i].bottom - c.r[i].top);
		CGContextClipToRects(cg, rs, c.n);
		free(rs);
	} else
		CGContextClipToRect(cg, CGRectZero);
	free(c.r);
	CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));
	return cg;
}

void qd_cg_end(Port *p)
{
	CGContextRestoreGState(p->cg);
}

// ---- fonts and text --------------------------------------------------------------------------

typedef struct { int num; const char *name; const char *host; } FontMap;
static const FontMap fonts[] = {
	{0, "Chicago", "Lucida Grande"}, {1, "Geneva", "Geneva"}, {2, "New York", "Times"}, {3, "Geneva", "Geneva"},
	{4, "Monaco", "Monaco"}, {5, "Venice", "Zapfino"}, {6, "London", "Times"}, {7, "Athens", "Times"},
	{8, "San Francisco", "Geneva"}, {9, "Toronto", "Geneva"}, {11, "Cairo", "Zapf Dingbats"}, {12, "Los Angeles", "Geneva"},
	{13, "Zapf Dingbats", "Zapf Dingbats"}, {14, "Bookman", "Bookman Old Style"}, {16, "Palatino", "Palatino"},
	{18, "Zapf Chancery", "Zapf Chancery"}, {20, "Times", "Times"}, {21, "Helvetica", "Helvetica"},
	{22, "Courier", "Courier"}, {23, "Symbol", "Symbol"}, {33, "Avant Garde", "Avenir"},
	{34, "New Century Schlbk", "New Century Schoolbook"}, {1024, "Charcoal", "Lucida Grande"},
	{2001, "Lucida Grande", "Lucida Grande"}, {2002, "Arial", "Arial"}, {2003, "Verdana", "Verdana"},
	{2004, "Times New Roman", "Times New Roman"}, {2005, "Georgia", "Georgia"}, {2006, "Trebuchet MS", "Trebuchet MS"},
	{2007, "Comic Sans MS", "Comic Sans MS"}, {2008, "Gadget", "Lucida Grande"}, {2009, "Textile", "Lucida Grande"},
	{2010, "Capitals", "Times"}, {2011, "Sand", "Lucida Grande"}, {2012, "Techno", "Lucida Grande"},
	{2013, "Skia", "Skia"}, {2014, "Impact", "Impact"}, {2015, "Optima", "Optima"}, {2016, "Futura", "Futura"},
	{2017, "Gill Sans", "Gill Sans"}, {2018, "American Typewriter", "American Typewriter"},
	{2019, "Baskerville", "Baskerville"}, {2020, "Didot", "Didot"}, {2021, "Hoefler Text", "Hoefler Text"},
	{2022, "Lucida Grande Bold", "Lucida Grande"}, {2023, "Arial Black", "Arial Black"},
};
static NSMutableArray *extra_fonts;   // numbers 3000 + i

NSString *qd_font_name(int num)
{
	for (size_t i = 0; i < sizeof fonts / sizeof *fonts; i++)
		if (fonts[i].num == num)
			return @(fonts[i].name);
	if (num >= 3000 && extra_fonts && num - 3000 < (int)extra_fonts.count)
		return extra_fonts[num - 3000];
	return @"Geneva";
}

int qd_font_num(NSString *name)
{
	for (size_t i = 0; i < sizeof fonts / sizeof *fonts; i++)
		if ([name caseInsensitiveCompare:@(fonts[i].name)] == NSOrderedSame)
			return fonts[i].num;
	if (!extra_fonts)
		extra_fonts = [NSMutableArray new];
	for (NSUInteger i = 0; i < extra_fonts.count; i++)
		if ([name caseInsensitiveCompare:extra_fonts[i]] == NSOrderedSame)
			return 3000 + (int)i;
	[extra_fonts addObject:[[name copy] autorelease]];
	return 3000 + (int)extra_fonts.count - 1;
}

static NSString *host_font(int num)
{
	for (size_t i = 0; i < sizeof fonts / sizeof *fonts; i++)
		if (fonts[i].num == num)
			return @(fonts[i].host);
	return qd_font_name(num);
}

static NSMutableDictionary *font_cache;

CTFontRef qd_font(int num, int size, int face)
{
	if (size <= 0)
		size = 12;
	face &= 0x63;   // bold, italic, condense, extend matter for the face; underline etc. are drawn
	NSNumber *key = @((num << 16) ^ (size << 8) ^ face);
	if (!font_cache)
		font_cache = [NSMutableDictionary new];
	id f = font_cache[key];
	if (f)
		return (CTFontRef)f;
	NSString *name = host_font(num);
	CTFontRef base = CTFontCreateWithName((CFStringRef)name, size, NULL);
	if (!base)
		base = CTFontCreateWithName(CFSTR("Geneva"), size, NULL);
	CTFontSymbolicTraits tr = 0;
	if (face & 1)
		tr |= kCTFontBoldTrait;
	if (face & 2)
		tr |= kCTFontItalicTrait;
	CTFontRef font = base;
	if (tr) {
		CTFontRef t = CTFontCreateCopyWithSymbolicTraits(base, size, NULL, tr, tr);
		if (!t && (face & 1) && (face & 2))
			t = CTFontCreateCopyWithSymbolicTraits(base, size, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
		if (!t && (face & 2)) {
			CGAffineTransform sk = CGAffineTransformMake(1, 0, 0.2, 1, 0, 0);
			t = CTFontCreateCopyWithAttributes(base, size, &sk, NULL);
		}
		if (t) {
			CFRelease(base);
			font = t;
		}
	}
	font_cache[key] = (id)font;
	CFRelease(font);
	return (CTFontRef)font_cache[key];
}

static int port_size(Port *p) { return p->txSize ? p->txSize : 12; }

static CTLineRef make_line(Port *p, const uint8_t *s, int n, CGColorRef color)
{
	CFStringRef str = CFStringCreateWithBytes(NULL, s, n, kCFStringEncodingMacRoman, false);
	if (!str)
		str = CFSTR("");
	CTFontRef font = qd_font(p->txFont, port_size(p), p->txFace);
	NSMutableDictionary *at = [NSMutableDictionary dictionaryWithObject:(id)font forKey:(id)kCTFontAttributeName];
	if (color)
		at[(id)kCTForegroundColorAttributeName] = (id)color;
	else
		at[(id)kCTForegroundColorFromContextAttributeName] = @YES;
	double kern = 0;
	if (p->txFace & 0x20)
		kern -= 1;   // condense
	if (p->txFace & 0x40)
		kern += 1;   // extend
	if ((p->txFace & 1) && !(CTFontGetSymbolicTraits(font) & kCTFontBoldTrait))
		at[(id)kCTStrokeWidthAttributeName] = @(-3.0);
	if (kern)
		at[(id)kCTKernAttributeName] = @(kern);
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, (CFDictionaryRef)at);
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CFRelease(as);
	CFRelease(str);
	return line;
}

double qd_text_width(Port *p, const uint8_t *s, int n)
{
	if (n <= 0)
		return 0;
	CTLineRef line = make_line(p, s, n, NULL);
	double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	int spaces = 0;
	if (p->spExtra)
		for (int i = 0; i < n; i++)
			spaces += s[i] == ' ';
	return w + spaces * (p->spExtra / 65536.0);
}

void qd_font_info(Port *p, int *ascent, int *descent, int *widMax, int *leading)
{
	CTFontRef f = qd_font(p->txFont, port_size(p), p->txFace);
	*ascent = (int)ceil(CTFontGetAscent(f));
	*descent = (int)ceil(CTFontGetDescent(f));
	*leading = (int)lround(CTFontGetLeading(f));
	CGRect bb = CTFontGetBoundingBox(f);
	*widMax = (int)ceil(bb.size.width);
	if (*widMax > port_size(p) * 2)
		*widMax = port_size(p) * 2;
}

void qd_text_draw(Port *p, const uint8_t *s, int n)
{
	if (n <= 0)
		return;
	if (p->rec_pic)
		pict_mirror_text(p, s, n);
	double w = qd_text_width(p, s, n);
	int x = p->pnLoc.h, y = p->pnLoc.v;
	if (p->pix && !p->rec_rgn) {
		CGContextRef cg = qd_cg_begin(p);
		int asc, desc, wid, lead;
		qd_font_info(p, &asc, &desc, &wid, &lead);
		RGB16 col = p->fg;
		int mode = p->txMode;
		if (mode == 0 || mode == 8) {   // srcCopy: the background behind the text
			CGContextSetRGBFillColor(cg, p->bg.r / 65535.0, p->bg.g / 65535.0, p->bg.b / 65535.0, 1);
			CGContextFillRect(cg, CGRectMake(x, y - asc, w, asc + desc));
		}
		if (mode == 3 || mode == 11)
			col = p->bg;
		CGFloat r = col.r / 65535.0, g = col.g / 65535.0, b = col.b / 65535.0;
		if (mode == 49) {   // grayishTextOr: disabled text
			r = (r + 2 * (p->bg.r / 65535.0)) / 3;
			g = (g + 2 * (p->bg.g / 65535.0)) / 3;
			b = (b + 2 * (p->bg.b / 65535.0)) / 3;
		}
		CGContextSetRGBFillColor(cg, r, g, b, 1);
		CGContextSetRGBStrokeColor(cg, r, g, b, 1);
		CGContextSetShouldSmoothFonts(cg, false);
		CTLineRef line = make_line(p, s, n, NULL);
		if (p->spExtra) {
			// spread the extra space over the spaces: draw word by word
			double sx = x;
			int i0 = 0;
			for (int i = 0; i <= n; i++)
				if (i == n || s[i] == ' ') {
					if (i > i0) {
						CTLineRef l2 = make_line(p, s + i0, i - i0, NULL);
						CGContextSetTextPosition(cg, sx, y);
						CTLineDraw(l2, cg);
						sx += CTLineGetTypographicBounds(l2, NULL, NULL, NULL);
						CFRelease(l2);
					}
					if (i < n)
						sx += qd_text_width(p, (const uint8_t *)" ", 1);
					i0 = i + 1;
				}
		} else {
			CGContextSetTextPosition(cg, x, y);
			CTLineDraw(line, cg);
		}
		CFRelease(line);
		if (p->txFace & 4) {   // underline
			CGContextFillRect(cg, CGRectMake(x, y + 1, w, 1));
		}
		qd_cg_end(p);
		qd_dirty(p, (QRect){(int16_t)(y - asc - 2), (int16_t)(x - 2), (int16_t)(y + desc + 2), (int16_t)(x + w + 4)});
	}
	p->pnLoc.h = (int16_t)lround(x + w);
}

// ---- pixels of any guest BitMap / PixMap ---------------------------------------------------------

typedef struct {
	uint32_t base;
	int rowBytes, depth, pixmap;
	QRect bounds;
	uint32_t ctab[256];
	int ctab_n;
} BM;

static void read_ctab(uint32_t cth, BM *b)
{
	b->ctab_n = 0;
	if (b->depth <= 8) {
		// defaults: the system palettes
		int n = 1 << b->depth;
		for (int i = 0; i < n; i++) {
			if (b->depth == 1)
				b->ctab[i] = i ? PIXV(0, 0, 0) : PIXV(255, 255, 255);
			else if (b->depth == 8) {
				extern const uint8_t mac_clut8[256][3];
				b->ctab[i] = PIXV(mac_clut8[i][0], mac_clut8[i][1], mac_clut8[i][2]);
			} else if (b->depth == 4) {
				extern const uint8_t mac_clut4[16][3];
				b->ctab[i] = PIXV(mac_clut4[i][0], mac_clut4[i][1], mac_clut4[i][2]);
			} else {
				int v = 255 - i * 255 / (n - 1);
				b->ctab[i] = PIXV(v, v, v);
			}
		}
		b->ctab_n = n;
	}
	if (!cth || !is_handle(cth) || !HP(cth))
		return;
	uint32_t ct = HP(cth);
	int n = (int16_t)LD16(ct + 6) + 1;
	int flags = LD16(ct + 4);
	for (int i = 0; i < n && i < 256; i++) {
		uint32_t e = ct + 8 + 8 * i;
		int idx = (flags & 0x8000) ? i : LD16(e);
		if (idx < 0 || idx > 255)
			continue;
		b->ctab[idx] = PIXV(LD16(e + 2) >> 8, LD16(e + 4) >> 8, LD16(e + 6) >> 8);
	}
}

static void read_bm(uint32_t a, BM *b)
{
	memset(b, 0, sizeof *b);
	b->base = LD32(a);
	int rb = LD16(a + 4);
	b->pixmap = (rb & 0x8000) != 0;
	b->rowBytes = rb & 0x3fff;
	b->bounds = RECT(a + 6);
	if (b->pixmap) {
		b->depth = LD16(a + 32);
		read_ctab(LD32(a + 42), b);
	} else {
		b->depth = 1;
		read_ctab(0, b);
	}
	if (!b->depth)
		b->depth = 1;
}

static inline uint32_t bm_get(BM *b, int x, int y)
{
	uint32_t row = b->base + (uint32_t)((y - b->bounds.top) * b->rowBytes);
	int bx = x - b->bounds.left;
	switch (b->depth) {
	case 32: return *(const uint32_t *)G(row + 4 * bx) | 0xff;
	case 16: {
		uint32_t v = LD16(row + 2 * bx);
		int r = (v >> 10) & 31, g = (v >> 5) & 31, bl = v & 31;
		return PIXV(r << 3 | r >> 2, g << 3 | g >> 2, bl << 3 | bl >> 2);
	}
	case 8: return b->ctab[LD8(row + bx)];
	case 4: return b->ctab[(LD8(row + bx / 2) >> (bx & 1 ? 0 : 4)) & 15];
	case 2: return b->ctab[(LD8(row + bx / 4) >> (6 - 2 * (bx & 3))) & 3];
	default: return b->ctab[(LD8(row + bx / 8) >> (7 - (bx & 7))) & 1];
	}
}

// 1 for "black" (set) pixels of a mask or a 1-bit source
static inline int bm_bit(BM *b, int x, int y)
{
	if (b->depth == 1) {
		uint32_t row = b->base + (uint32_t)((y - b->bounds.top) * b->rowBytes);
		int bx = x - b->bounds.left;
		return (LD8(row + bx / 8) >> (7 - (bx & 7))) & 1;
	}
	uint32_t v = bm_get(b, x, y);
	return ((v >> 8) & 255) + ((v >> 16) & 255) + ((v >> 24) & 255) < 384;
}

static Port *port_of_bits(uint32_t bits)
{
	Port *p = hm_get(&ports_by_pix, bits);
	if (p)
		return p;
	return NULL;
}

// ---- low-depth GWorlds ----------------------------------------------------------------------------------

static uint8_t nearest(BM *b, uint32_t v)
{
	int r = (v >> 8) & 255, g = (v >> 16) & 255, bl = (v >> 24) & 255;
	int best = 0, bd = 1 << 30;
	for (int i = 0; i < b->ctab_n; i++) {
		uint32_t c = b->ctab[i];
		int dr = r - (int)((c >> 8) & 255), dg = g - (int)((c >> 16) & 255), db = bl - (int)((c >> 24) & 255);
		int d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
		if (d < bd) {
			bd = d;
			best = i;
			if (!d)
				break;
		}
	}
	return (uint8_t)best;
}

static void shadow_pull(Port *p)
{
	// pix -> shadow
	BM b;
	read_bm(p->pixmap_ptr, &b);
	static uint8_t cache[32768];
	static uint32_t cache_key;
	uint32_t key = (uint32_t)b.depth << 24 ^ (b.ctab_n ? b.ctab[b.ctab_n - 1] ^ b.ctab[1] * 31 : 0) ^ p->sctab;
	if (key != cache_key && b.depth <= 8) {
		cache_key = key;
		for (int i = 0; i < 32768; i++) {
			int r = (i >> 10) & 31, g = (i >> 5) & 31, bl = i & 31;
			cache[i] = nearest(&b, PIXV(r << 3 | r >> 2, g << 3 | g >> 2, bl << 3 | bl >> 2));
		}
	}
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	for (int y = 0; y < h; y++) {
		const uint32_t *src = G(p->pix + (uint32_t)(y * p->rowBytes));
		uint32_t row = p->shadow + (uint32_t)(y * p->srow);
		if (p->sdepth == 16) {
			for (int x = 0; x < w; x++) {
				uint32_t v = src[x];
				ST16(row + 2 * x, (uint16_t)(((v >> 11) & 31) << 10 | ((v >> 19) & 31) << 5 | ((v >> 27) & 31)));
			}
			continue;
		}
		memset(G(row), 0, p->srow);
		for (int x = 0; x < w; x++) {
			uint32_t v = src[x];
			int k = cache[((v >> 11) & 31) << 10 | ((v >> 19) & 31) << 5 | ((v >> 27) & 31)];
			switch (p->sdepth) {
			case 8: ST8(row + x, k); break;
			case 4: ST8(row + x / 2, LD8(row + x / 2) | (k & 15) << (x & 1 ? 0 : 4)); break;
			case 2: ST8(row + x / 4, LD8(row + x / 4) | (k & 3) << (6 - 2 * (x & 3))); break;
			default: ST8(row + x / 8, LD8(row + x / 8) | (k & 1) << (7 - (x & 7))); break;
			}
		}
	}
}

static void shadow_push(Port *p)
{
	// shadow -> pix
	BM b;
	read_bm(p->pixmap_ptr, &b);
	int w = p->bounds.right - p->bounds.left, h = p->bounds.bottom - p->bounds.top;
	for (int y = 0; y < h; y++) {
		uint32_t *dst = G(p->pix + (uint32_t)(y * p->rowBytes));
		for (int x = 0; x < w; x++)
			dst[x] = bm_get(&b, x + b.bounds.left, y + b.bounds.top);
	}
}

void port_shadow_sync(Port *p, int for_guest)
{
	if (!p || !p->shadow)
		return;
	if (for_guest) {
		if (p->shadow_state == 0)
			shadow_pull(p);
		p->shadow_state = 2;
	} else if (p->shadow_state == 2) {
		shadow_push(p);
		p->shadow_state = 1;
	}
}

// the pixels of a port as a 32-bit BM (QuickDraw's own buffer)
static void port_bm(Port *p, BM *b)
{
	memset(b, 0, sizeof *b);
	b->base = p->pix;
	b->rowBytes = p->rowBytes;
	b->depth = 32;
	b->pixmap = 1;
	b->bounds = p->bounds;
}

void qd_copybits(uint32_t src, uint32_t dst, QRect sr, QRect dr, int mode, Rgn *mask)
{
	BM s, d;
	read_bm(src, &s);
	read_bm(dst, &d);
	Port *sp = port_of_bits(src);
	if (sp && sp->shadow) {
		port_shadow_sync(sp, 0);
		port_bm(sp, &s);
	}
	Port *dp = port_of_bits(dst);
	if (dp && dp->shadow) {
		port_shadow_sync(dp, 0);
		port_bm(dp, &d);
	}
	if (!dp)
		for (int i = 0; i < 1 && !dp; i++) {
			// a copy of the current port's PixMap
			if (qd_port && d.base == qd_port->pix)
				dp = qd_port;
		}
	if (dp && dp->rec_pic)
		pict_mirror_copybits(dp, src, sr, dr, mode, mask);
	if (d.depth != 32 && d.depth != 1) {
		ppc_log("CopyBits to a %d-bit destination", d.depth);
		return;
	}
	Rgn c = {{0, 0, 0, 0}, 0, 0, NULL};
	if (dp && dp == qd_port)
		qd_clip_region(dp, &c);
	else
		rgn_set_rect(&c, d.bounds);
	rgn_sect_rect(&c, d.bounds);
	rgn_sect_rect(&c, dr);
	if (mask)
		rgn_op(&c, &c, mask, RGN_SECT);
	int sw = sr.right - sr.left, sh = sr.bottom - sr.top, dw = dr.right - dr.left, dh = dr.bottom - dr.top;
	if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) {
		free(c.r);
		return;
	}
	Port *cp = qd_port;
	uint32_t fg = cp ? rgb_pix(cp->fg) : PIXV(0, 0, 0), bg = cp ? rgb_pix(cp->bg) : PIXV(255, 255, 255);
	int colorize = s.depth == 1 && cp && (fg != PIXV(0, 0, 0) || bg != PIXV(255, 255, 255));
	mode &= ~64;   // ditherCopy
	for (int i = 0; i < c.n; i++) {
		QRect r = c.r[i];
		for (int y = r.top; y < r.bottom; y++) {
			int sy = sr.top + (int)((int64_t)(y - dr.top) * sh / dh);
			if (sy < s.bounds.top || sy >= s.bounds.bottom)
				continue;
			for (int x = r.left; x < r.right; x++) {
				int sx = sr.left + (int)((int64_t)(x - dr.left) * sw / dw);
				if (sx < s.bounds.left || sx >= s.bounds.right)
					continue;
				uint32_t v = bm_get(&s, sx, sy);
				if (colorize)
					v = bm_bit(&s, sx, sy) ? fg : bg;
				if (d.depth == 1) {
					uint32_t a = d.base + (uint32_t)((y - d.bounds.top) * d.rowBytes) + (x - d.bounds.left) / 8;
					int bit = 7 - ((x - d.bounds.left) & 7);
					int on = ((v >> 8) & 255) + ((v >> 16) & 255) + ((v >> 24) & 255) < 384;
					ST8(a, on ? (LD8(a) | (1 << bit)) : (LD8(a) & ~(1 << bit)));
					continue;
				}
				uint32_t *dpx = (uint32_t *)G(d.base + (uint32_t)((y - d.bounds.top) * d.rowBytes + (x - d.bounds.left) * 4));
				int white = (v | 0xff) == PIXV(255, 255, 255);
				switch (mode) {
				case 0: *dpx = v; break;                                   // srcCopy
				case 1: if (!white) *dpx = s.depth == 1 ? fg : v; break;    // srcOr
				case 2: if (!white) *dpx = invert(*dpx); break;            // srcXor
				case 3: if (!white) *dpx = bg; break;                      // srcBic
				case 4: *dpx = invert(v); break;                           // notSrcCopy
				case 5: if (white) *dpx = fg; break;
				case 6: if (white) *dpx = invert(*dpx); break;
				case 7: if (white) *dpx = bg; break;
				case 36: if ((v | 0xff) != (bg | 0xff)) *dpx = v; break;   // transparent
				case 32: {                                                 // blend
					uint32_t o = *dpx;
					*dpx = PIXV((((o >> 8) & 255) + ((v >> 8) & 255)) / 2, (((o >> 16) & 255) + ((v >> 16) & 255)) / 2,
						(((o >> 24) & 255) + ((v >> 24) & 255)) / 2);
					break;
				}
				case 50: if (!white && *dpx == bg) *dpx = rgb_pix(cp ? cp->hilite : (RGB16){0xb5b5, 0xd5d5, 0xffff}); break;
				default: *dpx = v; break;
				}
			}
		}
	}
	if (dp && c.n)
		qd_dirty(dp, c.bbox);
	free(c.r);
}

void qd_draw_image(Port *p, CGImageRef img, QRect dst)
{
	CGContextRef cg = qd_cg_begin(p);
	CGContextSaveGState(cg);
	CGContextTranslateCTM(cg, dst.left, dst.bottom);
	CGContextScaleCTM(cg, 1, -1);
	CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
	CGContextDrawImage(cg, CGRectMake(0, 0, dst.right - dst.left, dst.bottom - dst.top), img);
	CGContextRestoreGState(cg);
	qd_cg_end(p);
	qd_dirty(p, dst);
}

// ---- shims: ports ------------------------------------------------------------------------------

#define CUR (qd_port)

static void sh_GetPort(PPC *c) { if (A(0)) ST32(A(0), CUR ? CUR->tok : 0); }
static void sh_SetPort(PPC *c)
{
	Port *p = PORT(A(0));
	if (p)
		qd_port = p;
}
static void sh_GetPortBounds(PPC *c)
{
	Port *p = PORT(A(0));
	if (p && A(1))
		PUTRECT(A(1), p->portRect);
	RET(A(1));
}
static void sh_SetPortBounds(PPC *c)
{
	Port *p = PORT(A(0));
	if (p) {
		p->portRect = RECT(A(1));
		port_tok_write(p);
	}
}
static void sh_GetPortVisibleRegion(PPC *c)
{
	Port *p = PORT(A(0));
	Rgn *g = RGN(A(1));
	if (p && g) {
		rgn_copy(g, p->vis);
		rgn_sync(A(1));
	}
	RET(A(1));
}
static void sh_SetPortVisibleRegion(PPC *c)
{
	Port *p = PORT(A(0));
	Rgn *g = RGN(A(1));
	if (p && g)
		rgn_copy(p->vis, g);
}
static void sh_GetPortPixMap(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->pixmap : 0); }
static void sh_GetPortBitMapForCopyBits(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->pixmap_ptr : 0); }
static void sh_GetPortTextFont(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->txFont : 0); }
static void sh_GetPortTextSize(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->txSize : 0); }
static void sh_GetPortTextFace(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->txFace : 0); }
static void sh_GetPortTextMode(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->txMode : 0); }
static void sh_GetPortGrafProcs(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->grafProcs : 0); }
static void sh_SetPortGrafProcs(PPC *c) { Port *p = PORT(A(0)); if (p) p->grafProcs = A(1); }
static void sh_IsPortRegionBeingDefined(PPC *c) { Port *p = PORT(A(0)); RET(p && p->rec_rgn); }
static void sh_QDFlushPortBuffer(PPC *c) { Port *p = PORT(A(0)); if (p && p->win) win_flush(p->win); }
static void sh_QDError(PPC *c) { RET((int32_t)qd_err); }
static void sh_QDDone(PPC *c) { RET(1); }
static void sh_LockPortBits(PPC *c) { RET(0); }

static void sh_SetOrigin(PPC *c)
{
	Port *p = CUR;
	if (!p)
		return;
	int h = (int16_t)A(0), v = (int16_t)A(1);
	int dh = h - p->portRect.left, dv = v - p->portRect.top;
	p->portRect = rect_off(p->portRect, dh, dv);
	p->bounds = rect_off(p->bounds, dh, dv);
	rgn_offset(p->vis, dh, dv);
	pixmap_write(p);
	port_tok_write(p);
}

static void sh_ClipRect(PPC *c) { if (CUR) rgn_set_rect(CUR->clip, RECT(A(0))); }
static void sh_SetClip(PPC *c) { Rgn *g = RGN(A(0)); if (CUR && g) rgn_copy(CUR->clip, g); }
static void sh_GetClip(PPC *c)
{
	Rgn *g = RGN(A(0));
	if (CUR && g) {
		rgn_copy(g, CUR->clip);
		rgn_sync(A(0));
	}
}

static void sh_GlobalToLocal(PPC *c)
{
	if (!CUR)
		return;
	QPoint p = LDPT(A(0));
	QPoint o = CUR->win ? win_origin(CUR->win) : (QPoint){0, 0};
	p.h = (int16_t)(p.h - o.h + CUR->portRect.left);
	p.v = (int16_t)(p.v - o.v + CUR->portRect.top);
	STPT(A(0), p);
}
static void sh_LocalToGlobal(PPC *c)
{
	if (!CUR)
		return;
	QPoint p = LDPT(A(0));
	QPoint o = CUR->win ? win_origin(CUR->win) : (QPoint){0, 0};
	p.h = (int16_t)(p.h + o.h - CUR->portRect.left);
	p.v = (int16_t)(p.v + o.v - CUR->portRect.top);
	STPT(A(0), p);
}

// ---- pen and colors ----------------------------------------------------------------------------

static void sh_MoveTo(PPC *c) { if (CUR) CUR->pnLoc = (QPoint){(int16_t)A(1), (int16_t)A(0)}; rgnrec_move(CUR); }
static void sh_Move(PPC *c) { if (CUR) { CUR->pnLoc.h += (int16_t)A(0); CUR->pnLoc.v += (int16_t)A(1); rgnrec_move(CUR); } }

static void poly_add(QPoint p);
static uint32_t poly_open;

static void line_to(Port *p, QPoint to)
{
	QPoint from = p->pnLoc;
	p->pnLoc = to;
	if (poly_open) {
		// a polygon being recorded: its first point is where the first line starts
		if (HSize(poly_open) <= 10)
			poly_add(from);
		poly_add(to);
	}
	if (p->rec_rgn) {
		rgnrec_line(p, to);
		return;
	}
	if (p->pnVis < 0)
		return;
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_line(&g, from, to, p->pnSize.h, p->pnSize.v);
	qd_fill(p, &g, qd_pen(p));
	free(g.r);
}
static void sh_LineTo(PPC *c) { if (CUR) line_to(CUR, (QPoint){(int16_t)A(1), (int16_t)A(0)}); }
static void sh_Line(PPC *c) { if (CUR) line_to(CUR, (QPoint){(int16_t)(CUR->pnLoc.v + (int16_t)A(1)), (int16_t)(CUR->pnLoc.h + (int16_t)A(0))}); }
static void sh_PenSize(PPC *c) { if (CUR) CUR->pnSize = (QPoint){(int16_t)A(1), (int16_t)A(0)}; }
static void sh_PenMode(PPC *c) { if (CUR) CUR->pnMode = (int16_t)A(0); }
static void sh_PenPat(PPC *c) { if (CUR && A(0)) memcpy(CUR->pnPat, G(A(0)), 8); }
static void sh_BackPat(PPC *c) { if (CUR && A(0)) memcpy(CUR->bkPat, G(A(0)), 8); }
static void sh_PenNormal(PPC *c)
{
	if (!CUR)
		return;
	CUR->pnSize = (QPoint){1, 1};
	CUR->pnMode = 8;
	memset(CUR->pnPat, 0xff, 8);
}
static void sh_HidePen(PPC *c) { if (CUR) CUR->pnVis--; }
static void sh_ShowPen(PPC *c) { if (CUR) CUR->pnVis++; }
// PenState: pnLoc, pnSize, pnMode, pnPat
static void sh_GetPenState(PPC *c)
{
	if (!CUR)
		return;
	uint32_t a = A(0);
	STPT(a, CUR->pnLoc);
	STPT(a + 4, CUR->pnSize);
	ST16(a + 8, CUR->pnMode);
	memcpy(G(a + 10), CUR->pnPat, 8);
}
static void sh_SetPenState(PPC *c)
{
	if (!CUR)
		return;
	uint32_t a = A(0);
	CUR->pnLoc = LDPT(a);
	CUR->pnSize = LDPT(a + 4);
	CUR->pnMode = (int16_t)LD16(a + 8);
	memcpy(CUR->pnPat, G(a + 10), 8);
}

static RGB16 LDRGB(uint32_t a) { return (RGB16){(uint16_t)LD16(a), (uint16_t)LD16(a + 2), (uint16_t)LD16(a + 4)}; }
static void STRGB(uint32_t a, RGB16 c) { ST16(a, c.r); ST16(a + 2, c.g); ST16(a + 4, c.b); }
static void sh_RGBForeColor(PPC *c) { if (CUR) CUR->fg = LDRGB(A(0)); }
static void sh_RGBBackColor(PPC *c) { if (CUR) CUR->bg = LDRGB(A(0)); }
static void sh_GetForeColor(PPC *c) { if (CUR) STRGB(A(0), CUR->fg); }
static void sh_GetBackColor(PPC *c) { if (CUR) STRGB(A(0), CUR->bg); }
static void sh_OpColor(PPC *c) { if (CUR) CUR->op = LDRGB(A(0)); }
static void sh_InvertColor(PPC *c) { RGB16 v = LDRGB(A(0)); STRGB(A(0), (RGB16){(uint16_t)~v.r, (uint16_t)~v.g, (uint16_t)~v.b}); }
static RGB16 classic_color(int32_t k)
{
	switch (k) {
	case 33: return (RGB16){0, 0, 0};                // blackColor
	case 30: return (RGB16){0xffff, 0xffff, 0xffff}; // whiteColor
	case 205: return (RGB16){0xdd6b, 0x08c2, 0x06a2}; // redColor
	case 341: return (RGB16){0x0000, 0x8000, 0x11b0}; // greenColor
	case 409: return (RGB16){0x0000, 0x0000, 0xd400}; // blueColor
	case 273: return (RGB16){0x0241, 0xab54, 0xeafe}; // cyanColor
	case 137: return (RGB16){0xf2d7, 0x0856, 0x84ec}; // magentaColor
	case 69: return (RGB16){0xfc00, 0xf37d, 0x052f};  // yellowColor
	}
	return (RGB16){0, 0, 0};
}
static void sh_ForeColor(PPC *c) { if (CUR) CUR->fg = classic_color((int32_t)A(0)); }
static void sh_BackColor(PPC *c) { if (CUR) CUR->bg = classic_color((int32_t)A(0)); }
static void sh_GetGray(PPC *c)
{
	// GetGray(device, backColor, foreColor) -> the midpoint in foreColor
	RGB16 b = LDRGB(A(1)), f = LDRGB(A(2));
	STRGB(A(2), (RGB16){(uint16_t)((b.r + f.r) / 2), (uint16_t)((b.g + f.g) / 2), (uint16_t)((b.b + f.b) / 2)});
	RET(1);
}

// ---- shapes ------------------------------------------------------------------------------------------

static const uint8_t pat_black[8] = {255, 255, 255, 255, 255, 255, 255, 255};

static void frame_shape(Port *p, Rgn *shape)
{
	if (p->pnVis < 0)
		return;
	Rgn f = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_frame(&f, shape, p->pnSize.h, p->pnSize.v);
	qd_fill(p, &f, qd_pen(p));
	free(f.r);
}

enum { V_FRAME, V_PAINT, V_ERASE, V_INVERT, V_FILL };

static void do_shape(Port *p, Rgn *g, int verb, uint32_t pat)
{
	if (!p)
		return;
	if (p->rec_rgn) {
		if (verb == V_FRAME)
			rgnrec_shape(p, g);
		return;
	}
	switch (verb) {
	case V_FRAME: frame_shape(p, g); break;
	case V_PAINT: qd_fill(p, g, qd_pen(p)); break;
	case V_ERASE: qd_fill(p, g, qd_back(p)); break;
	case V_INVERT: qd_fill(p, g, (Paint){pat_black, p->fg, p->bg, 10}); break;
	case V_FILL: {
		uint8_t pt[8];
		memcpy(pt, G(pat), 8);
		qd_fill(p, g, (Paint){pt, p->fg, p->bg, 8});
		break;
	}
	}
}

static void rect_verb(PPC *c, int verb)
{
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&g, RECT(A(0)));
	do_shape(CUR, &g, verb, A(1));
	free(g.r);
}
static void sh_FrameRect(PPC *c) { rect_verb(c, V_FRAME); }
static void sh_PaintRect(PPC *c) { rect_verb(c, V_PAINT); }
static void sh_EraseRect(PPC *c) { rect_verb(c, V_ERASE); }
static void sh_InvertRect(PPC *c) { rect_verb(c, V_INVERT); }
static void sh_FillRect(PPC *c) { rect_verb(c, V_FILL); }

static void oval_verb(PPC *c, int verb)
{
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_oval(&g, RECT(A(0)));
	do_shape(CUR, &g, verb, A(1));
	free(g.r);
}
static void sh_FrameOval(PPC *c) { oval_verb(c, V_FRAME); }
static void sh_EraseOval(PPC *c) { oval_verb(c, V_ERASE); }
static void sh_PaintOval(PPC *c) { oval_verb(c, V_PAINT); }

static void sh_FrameRoundRect(PPC *c)
{
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_roundrect(&g, RECT(A(0)), (int16_t)A(1), (int16_t)A(2));
	do_shape(CUR, &g, V_FRAME, 0);
	free(g.r);
}

static void arc_verb(PPC *c, int verb)
{
	Port *p = CUR;
	if (!p)
		return;
	QRect r = RECT(A(0));
	int start = (int16_t)A(1), arc = (int16_t)A(2);
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	if (verb == V_FRAME) {
		// the arc of the oval's frame
		Rgn o = {{0, 0, 0, 0}, 0, 0, NULL}, w = {{0, 0, 0, 0}, 0, 0, NULL};
		rgn_oval(&o, r);
		rgn_frame(&g, &o, p->pnSize.h, p->pnSize.v);
		rgn_arc(&w, r, start, arc);
		rgn_op(&g, &g, &w, RGN_SECT);
		free(o.r);
		free(w.r);
		if (p->pnVis >= 0 && !p->rec_rgn)
			qd_fill(p, &g, qd_pen(p));
	} else {
		rgn_arc(&g, r, start, arc);
		do_shape(p, &g, verb, A(3));
	}
	free(g.r);
}
static void sh_FrameArc(PPC *c) { arc_verb(c, V_FRAME); }
static void sh_PaintArc(PPC *c) { arc_verb(c, V_PAINT); }
static void sh_FillArc(PPC *c) { arc_verb(c, V_FILL); }

// polygons: PolyHandle = polySize, polyBBox, points
static void sh_OpenPoly(PPC *c)
{
	poly_open = NewHandleClearG(10);
	if (CUR) {
		CUR->pnVis--;
		ST16(HP(poly_open) + 10 - 10, 10);
	}
	RET(poly_open);
}
static void poly_add(QPoint p)
{
	if (!poly_open)
		return;
	uint32_t n = HSize(poly_open);
	HSetSize(poly_open, n + 4);
	STPT(HP(poly_open) + n, p);
	ST16(HP(poly_open), n + 4);
}
static void sh_ClosePoly(PPC *c)
{
	if (!poly_open)
		return;
	uint32_t p = HP(poly_open), n = (HSize(poly_open) - 10) / 4;
	QRect b = {32767, 32767, -32768, -32768};
	for (uint32_t i = 0; i < n; i++) {
		QPoint q = LDPT(p + 10 + 4 * i);
		if (q.v < b.top) b.top = q.v;
		if (q.h < b.left) b.left = q.h;
		if (q.v > b.bottom) b.bottom = q.v;
		if (q.h > b.right) b.right = q.h;
	}
	PUTRECT(p + 2, n ? b : (QRect){0, 0, 0, 0});
	poly_open = 0;
	if (CUR)
		CUR->pnVis++;
}
static void sh_KillPoly(PPC *c) { DisposeHandleG(A(0)); }
static int poly_points(uint32_t h, QPoint **out)
{
	uint32_t n = (HSize(h) - 10) / 4;
	QPoint *pts = malloc(sizeof(QPoint) * (n + 1));
	for (uint32_t i = 0; i < n; i++)
		pts[i] = LDPT(HP(h) + 10 + 4 * i);
	*out = pts;
	return (int)n;
}
static void poly_verb(PPC *c, int verb)
{
	Port *p = CUR;
	if (!p || !is_handle(A(0)))
		return;
	QPoint *pts;
	int n = poly_points(A(0), &pts);
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	if (verb == V_FRAME) {
		QPoint save = p->pnLoc;
		if (n) {
			p->pnLoc = pts[0];
			for (int i = 1; i < n; i++)
				line_to(p, pts[i]);
		}
		p->pnLoc = save;
	} else {
		rgn_poly(&g, pts, n);
		if (ppc_verbose >= 4)
			ppc_log("poly %d pts bbox %d,%d,%d,%d rects %d origin %d,%d clip %d,%d,%d,%d fg %04x%04x%04x", n, g.bbox.top, g.bbox.left, g.bbox.bottom, g.bbox.right, g.n,
				p->portRect.left, p->portRect.top, p->clip->bbox.top, p->clip->bbox.left, p->clip->bbox.bottom, p->clip->bbox.right, p->fg.r, p->fg.g, p->fg.b);
		do_shape(p, &g, verb, A(1));
	}
	free(g.r);
	free(pts);
}
static void sh_FramePoly(PPC *c) { poly_verb(c, V_FRAME); }
static void sh_PaintPoly(PPC *c) { poly_verb(c, V_PAINT); }
static void sh_FillPoly(PPC *c) { poly_verb(c, V_FILL); }

static void rgn_verb(PPC *c, int verb)
{
	Rgn *g = RGN(A(0));
	if (g)
		do_shape(CUR, g, verb, A(1));
}
static void sh_FrameRgn(PPC *c) { rgn_verb(c, V_FRAME); }
static void sh_PaintRgn(PPC *c) { rgn_verb(c, V_PAINT); }
static void sh_EraseRgn(PPC *c) { rgn_verb(c, V_ERASE); }
static void sh_InvertRgn(PPC *c) { rgn_verb(c, V_INVERT); }
static void sh_FillRgn(PPC *c) { rgn_verb(c, V_FILL); }

// ScrollRect(r, dh, dv, updateRgn)
static void sh_ScrollRect(PPC *c)
{
	Port *p = CUR;
	if (!p)
		return;
	QRect r = RECT(A(0));
	int dh = (int16_t)A(1), dv = (int16_t)A(2);
	Rgn clip = {{0, 0, 0, 0}, 0, 0, NULL};
	qd_clip_region(p, &clip);
	rgn_sect_rect(&clip, r);
	QRect src = clip.n ? clip.bbox : (QRect){0, 0, 0, 0};
	QRect moved = rect_sect(rect_off(src, dh, dv), src);
	// copy rows in the right order
	if (!rect_empty(moved)) {
		int w = moved.right - moved.left;
		if (dv > 0)
			for (int y = moved.bottom - 1; y >= moved.top; y--)
				memmove(PIXP(p, moved.left, y), PIXP(p, moved.left - dh, y - dv), 4 * w);
		else
			for (int y = moved.top; y < moved.bottom; y++)
				memmove(PIXP(p, moved.left, y), PIXP(p, moved.left - dh, y - dv), 4 * w);
	}
	Rgn upd = {{0, 0, 0, 0}, 0, 0, NULL};
	Rgn mv = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_set_rect(&upd, src);
	rgn_set_rect(&mv, moved);
	rgn_op(&upd, &upd, &mv, RGN_DIFF);
	qd_fill(p, &upd, qd_back(p));
	qd_dirty(p, src);
	Rgn *u = RGN(A(3));
	if (u) {
		rgn_copy(u, &upd);
		rgn_sync(A(3));
	}
	free(upd.r);
	free(mv.r);
	free(clip.r);
}

// ---- rectangles and points ---------------------------------------------------------------------

static void sh_SetRect(PPC *c) { PUTRECT(A(0), (QRect){(int16_t)A(2), (int16_t)A(1), (int16_t)A(4), (int16_t)A(3)}); }
static void sh_OffsetRect(PPC *c) { PUTRECT(A(0), rect_off(RECT(A(0)), (int16_t)A(1), (int16_t)A(2))); }
static void sh_InsetRect(PPC *c)
{
	QRect r = RECT(A(0));
	int dh = (int16_t)A(1), dv = (int16_t)A(2);
	r.left += dh; r.right -= dh; r.top += dv; r.bottom -= dv;
	if (rect_empty(r))
		r = (QRect){0, 0, 0, 0};
	PUTRECT(A(0), r);
}
static void sh_SectRect(PPC *c)
{
	QRect r = rect_sect(RECT(A(0)), RECT(A(1)));
	PUTRECT(A(2), r);
	RET(!rect_empty(r));
}
static void sh_UnionRect(PPC *c) { PUTRECT(A(2), rect_union(RECT(A(0)), RECT(A(1)))); }
static void sh_EqualRect(PPC *c) { RET(!memcmp(G(A(0)), G(A(1)), 8)); }
static void sh_EmptyRect(PPC *c) { RET(rect_empty(RECT(A(0)))); }
static void sh_PtInRect(PPC *c)
{
	QPoint p = PT(A(0));
	QRect r = RECT(A(1));
	RET(p.h >= r.left && p.h < r.right && p.v >= r.top && p.v < r.bottom);
}
static void sh_PinRect(PPC *c)
{
	QRect r = RECT(A(0));
	QPoint p = PT(A(1));
	if (p.h < r.left) p.h = r.left;
	if (p.h >= r.right) p.h = r.right - 1;
	if (p.v < r.top) p.v = r.top;
	if (p.v >= r.bottom) p.v = r.bottom - 1;
	RET(PTV(p));
}
static void sh_EqualPt(PPC *c) { RET(A(0) == A(1)); }
static int16_t map1(int v, int s0, int s1, int d0, int d1)
{
	return s1 == s0 ? (int16_t)d0 : (int16_t)(d0 + (int)((int64_t)(v - s0) * (d1 - d0) / (s1 - s0)));
}
static void sh_MapRect(PPC *c)
{
	QRect r = RECT(A(0)), s = RECT(A(1)), d = RECT(A(2));
	r.left = map1(r.left, s.left, s.right, d.left, d.right);
	r.right = map1(r.right, s.left, s.right, d.left, d.right);
	r.top = map1(r.top, s.top, s.bottom, d.top, d.bottom);
	r.bottom = map1(r.bottom, s.top, s.bottom, d.top, d.bottom);
	PUTRECT(A(0), r);
}

// ---- regions ------------------------------------------------------------------------------------------

static void sh_NewRgn(PPC *c) { RET(rgn_handle(NULL)); }
static void sh_DisposeRgn(PPC *c) { rgn_dispose(A(0)); }
static void sh_CopyRgn(PPC *c)
{
	Rgn *s = RGN(A(0)), *d = RGN(A(1));
	if (s && d) {
		rgn_copy(d, s);
		rgn_sync(A(1));
	}
}
static void sh_SetEmptyRgn(PPC *c) { Rgn *g = RGN(A(0)); if (g) { rgn_set_empty(g); rgn_sync(A(0)); } }
static void sh_SetRectRgn(PPC *c)
{
	Rgn *g = RGN(A(0));
	if (g) {
		rgn_set_rect(g, (QRect){(int16_t)A(2), (int16_t)A(1), (int16_t)A(4), (int16_t)A(3)});
		rgn_sync(A(0));
	}
}
static void sh_RectRgn(PPC *c) { Rgn *g = RGN(A(0)); if (g) { rgn_set_rect(g, RECT(A(1))); rgn_sync(A(0)); } }
static void sh_OffsetRgn(PPC *c) { Rgn *g = RGN(A(0)); if (g) { rgn_offset(g, (int16_t)A(1), (int16_t)A(2)); rgn_sync(A(0)); } }
static void sh_InsetRgn(PPC *c) { Rgn *g = RGN(A(0)); if (g) { rgn_inset(g, (int16_t)A(1), (int16_t)A(2)); rgn_sync(A(0)); } }
static void rgn_binop(PPC *c, int op)
{
	Rgn *a = RGN(A(0)), *b = RGN(A(1)), *d = RGN(A(2));
	if (a && b && d) {
		rgn_op(d, a, b, op);
		rgn_sync(A(2));
	}
}
static void sh_SectRgn(PPC *c) { rgn_binop(c, RGN_SECT); }
static void sh_UnionRgn(PPC *c) { rgn_binop(c, RGN_UNION); }
static void sh_DiffRgn(PPC *c) { rgn_binop(c, RGN_DIFF); }
static void sh_EmptyRgn(PPC *c) { Rgn *g = RGN(A(0)); RET(!g || rgn_empty(g)); }
static void sh_PtInRgn(PPC *c) { Rgn *g = RGN(A(1)); QPoint p = PT(A(0)); RET(g && rgn_contains(g, p.h, p.v)); }
static void sh_RectInRgn(PPC *c) { Rgn *g = RGN(A(1)); RET(g && rgn_rect_in(g, RECT(A(0)))); }
static void sh_GetRegionBounds(PPC *c)
{
	Rgn *g = RGN(A(0));
	PUTRECT(A(1), g && g->n ? g->bbox : (QRect){0, 0, 0, 0});
	RET(A(1));
}
static void sh_BitMapToRegion(PPC *c)
{
	Rgn *g = RGN(A(0));
	if (!g) {
		RET(-50);
		return;
	}
	BM b;
	read_bm(A(1), &b);
	RgnBuild rb;
	rb_begin(&rb, g);
	for (int y = b.bounds.top; y < b.bounds.bottom; y++) {
		int16_t xs[512];
		int n = 0, in = 0;
		for (int x = b.bounds.left; x < b.bounds.right; x++) {
			int on = bm_bit(&b, x, y);
			if (on != in && n < 510) {
				xs[n++] = (int16_t)x;
				in = on;
			}
		}
		if (in)
			xs[n++] = b.bounds.right;
		if (n)
			rb_row(&rb, y, xs, n);
	}
	rb_end(&rb);
	rgn_sync(A(0));
	RET(0);
}

// region recording: shapes framed are XORed, lines make polygons
typedef struct { QPoint *pts; int n, cap; } Poly;
static struct { uint32_t h; Rgn acc; Poly polys[64]; int npolys; } rr;

void rgnrec_move(Port *p)
{
	if (!p || !p->rec_rgn)
		return;
	if (rr.npolys < 64) {
		Poly *q = &rr.polys[rr.npolys++];
		q->n = 0;
		if (q->cap < 1) {
			q->cap = 16;
			q->pts = realloc(q->pts, sizeof(QPoint) * q->cap);
		}
		q->pts[q->n++] = p->pnLoc;
	}
}

void rgnrec_line(Port *p, QPoint to)
{
	(void)p;
	if (!rr.npolys)
		return;
	Poly *q = &rr.polys[rr.npolys - 1];
	if (q->n == q->cap) {
		q->cap *= 2;
		q->pts = realloc(q->pts, sizeof(QPoint) * q->cap);
	}
	q->pts[q->n++] = to;
}

void rgnrec_shape(Port *p, Rgn *g)
{
	(void)p;
	rgn_op(&rr.acc, &rr.acc, g, RGN_XOR);
}

static void sh_OpenRgn(PPC *c)
{
	if (!CUR)
		return;
	CUR->rec_rgn = 1;
	rgn_set_empty(&rr.acc);
	rr.npolys = 0;
	rgnrec_move(CUR);
}
static void sh_CloseRgn(PPC *c)
{
	Rgn *g = RGN(A(0));
	if (!CUR || !g)
		return;
	CUR->rec_rgn = 0;
	Rgn t = {{0, 0, 0, 0}, 0, 0, NULL};
	rgn_copy(g, &rr.acc);
	for (int i = 0; i < rr.npolys; i++)
		if (rr.polys[i].n > 2) {
			rgn_poly(&t, rr.polys[i].pts, rr.polys[i].n);
			rgn_op(g, g, &t, RGN_XOR);
		}
	free(t.r);
	rr.npolys = 0;
	rgn_sync(A(0));
}

// ---- text ------------------------------------------------------------------------------------------------

static void sh_TextFont(PPC *c) { if (CUR) CUR->txFont = (int16_t)A(0); }
static void sh_TextFace(PPC *c) { if (CUR) CUR->txFace = A(0) & 0x7f; }
static void sh_TextMode(PPC *c) { if (CUR) CUR->txMode = (int16_t)A(0); }
static void sh_TextSize(PPC *c) { if (CUR) CUR->txSize = (int16_t)A(0); }

// the port's text bottleneck: a custom textProc in its grafProcs, or StdText
static Shim std_text_shim;
static void draw_text_via_procs(Port *p, uint32_t buf, int n)
{
	if (p->grafProcs) {
		uint32_t tp = LD32(p->grafProcs);
		if (tp && LD32(tp) < HOSTCB_CODE) {
			uint32_t pt = gmalloc(8);
			ST32(pt, 0x00010001);
			ST32(pt + 4, 0x00010001);
			ppc_cb4(tp, (uint32_t)n, buf, pt, pt + 4);
			gfree(pt);
			return;
		}
	}
	qd_text_draw(p, G(buf), n);
}

static void sh_DrawString(PPC *c)
{
	if (ppc_verbose >= 3 && A(0))
		ppc_log("DrawString '%.*s' at %d,%d", LD8(A(0)), (const char *)G(A(0) + 1), CUR ? CUR->pnLoc.h : 0, CUR ? CUR->pnLoc.v : 0);
	if (CUR && A(0))
		draw_text_via_procs(CUR, A(0) + 1, LD8(A(0)));
}
static void sh_DrawText(PPC *c)
{
	if (ppc_verbose >= 3)
		ppc_log("DrawText '%.*s' at %d,%d", (int16_t)A(2), (const char *)G(A(0) + (int16_t)A(1)), CUR ? CUR->pnLoc.h : 0, CUR ? CUR->pnLoc.v : 0);
	static int bt;
	if (ppc_verbose >= 4 && !bt++)
		ppc_backtrace(c);
	if (CUR)
		draw_text_via_procs(CUR, A(0) + (int16_t)A(1), (int16_t)A(2));
}
static void sh_StdText(PPC *c) { if (CUR) qd_text_draw(CUR, G(A(1)), (int16_t)A(0)); }
static void sh_StdTxMeas(PPC *c)
{
	// StdTxMeas(byteCount, textAddr, numer, denom, info)
	if (!CUR) {
		RET(0);
		return;
	}
	if (A(4)) {
		int a, d, w, l;
		qd_font_info(CUR, &a, &d, &w, &l);
		ST16(A(4), a);
		ST16(A(4) + 2, d);
		ST16(A(4) + 4, w);
		ST16(A(4) + 6, l);
	}
	RET((int)lround(qd_text_width(CUR, G(A(1)), (int16_t)A(0))));
}
static void sh_StringWidth(PPC *c) { RET(CUR && A(0) ? (int)lround(qd_text_width(CUR, G(A(0) + 1), LD8(A(0)))) : 0); }
static void sh_TextWidth(PPC *c) { RET(CUR ? (int)lround(qd_text_width(CUR, G(A(0) + (int16_t)A(1)), (int16_t)A(2))) : 0); }
static void sh_CharWidth(PPC *c) { uint8_t ch = (uint8_t)A(0); RET(CUR ? (int)lround(qd_text_width(CUR, &ch, 1)) : 0); }
static void sh_GetFontInfo(PPC *c)
{
	if (!CUR)
		return;
	int a, d, w, l;
	qd_font_info(CUR, &a, &d, &w, &l);
	ST16(A(0), a);
	ST16(A(0) + 2, d);
	ST16(A(0) + 4, w);
	ST16(A(0) + 6, l);
}
static void sh_GetFNum(PPC *c) { ST16(A(1), qd_font_num(pstr_ns(A(0)))); }
static void sh_GetFontName(PPC *c) { ns_pstr(qd_font_name((int16_t)A(0)), A(1)); }
static void sh_GetSysFont(PPC *c) { RET(0); }
static void sh_GetAppFont(PPC *c) { RET(1); }
static void sh_GetDefFontSize(PPC *c) { RET(12); }
static void sh_SetOutlinePreferred(PPC *c) { (void)c; }
static void sh_FMSwapFont(PPC *c)
{
	// FMSwapFont(FMInput *) -> FMOutput *: ascent/descent etc. of the requested font
	static uint32_t out;
	if (!out)
		out = gcalloc(32);
	uint32_t in = A(0);
	Port tmp = *CUR;
	tmp.txFont = (int16_t)LD16(in);
	tmp.txSize = (int16_t)LD16(in + 2);
	tmp.txFace = LD8(in + 4);
	int a, d, w, l;
	qd_font_info(&tmp, &a, &d, &w, &l);
	ST8(out + 12, a);
	ST8(out + 13, d);
	ST8(out + 14, w);
	ST8(out + 15, l);
	RET(out);
}

// TruncString(width, Str255 theString, truncWhere) -> truncated (1) or not
static void sh_TruncString(PPC *c)
{
	int width = (int16_t)A(0);
	uint32_t s = A(1);
	int where = (int16_t)A(2);   // 0 truncEnd, 1 truncMiddle
	if (!CUR || !s) {
		RET(0);
		return;
	}
	int n = LD8(s);
	uint8_t buf[260];
	memcpy(buf, G(s + 1), n);
	if (qd_text_width(CUR, buf, n) <= width) {
		RET(0);
		return;
	}
	const uint8_t ell = 0xc9;   // … in Mac Roman
	for (int k = n - 1; k >= 0; k--) {
		uint8_t t[260];
		int m;
		if (where == 1) {
			int head = (k + 1) / 2, tail = k - head;
			memcpy(t, buf, head);
			t[head] = ell;
			memcpy(t + head + 1, buf + n - tail, tail);
			m = k + 1;
		} else {
			memcpy(t, buf, k);
			t[k] = ell;
			m = k + 1;
		}
		if (qd_text_width(CUR, t, m) <= width || k == 0) {
			ST8(s, m);
			memcpy(G(s + 1), t, m);
			break;
		}
	}
	RET(1);
}

// ---- GWorlds ---------------------------------------------------------------------------------------------

static Port *gworld_cur;
static uint32_t gdev_main;

static void sh_NewGWorld(PPC *c)
{
	// NewGWorld(GWorldPtr *, depth, Rect *, CTabHandle, GDHandle, flags)
	QRect r = RECT(A(2));
	Port *p = port_new(0, 0, r, 1);
	p->gworld = 1;
	int depth = (int16_t)A(1);
	if (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16) {
		int w = r.right - r.left, h = r.bottom - r.top;
		p->sdepth = depth;
		p->srow = ((w * depth + 31) / 32) * 4;
		p->shadow = gcalloc((uint32_t)(p->srow * (h > 0 ? h : 1)));
		p->sctab = A(3);
		p->shadow_state = 0;
		pixmap_write(p);
	}
	ST32(A(0), p->tok);
	RET(0);
}
static void sh_DisposeGWorld(PPC *c)
{
	Port *p = PORT(A(0));
	if (p && p->gworld) {
		if (p->shadow)
			gfree(p->shadow);
		gfree(p->pix);
		port_free(p);
	}
}
static void sh_GetGWorld(PPC *c)
{
	if (A(0))
		ST32(A(0), CUR ? CUR->tok : 0);
	if (A(1))
		ST32(A(1), gdev_main);
}
static void sh_SetGWorld(PPC *c)
{
	Port *p = PORT(A(0));
	if (p)
		port_shadow_sync(p, 0);
	if (p)
		qd_port = p;
	gworld_cur = p;
}
static void sh_GetGWorldPixMap(PPC *c) { Port *p = PORT(A(0)); RET(p ? p->pixmap : 0); }
static void sh_LockPixels(PPC *c) { RET(1); }
static void sh_GetPixBaseAddr(PPC *c)
{
	Port *p = is_handle(A(0)) ? port_of_bits(HP(A(0))) : NULL;
	if (p && p->shadow)
		port_shadow_sync(p, 1);
	RET(is_handle(A(0)) ? LD32(HP(A(0))) : 0);
}
static void sh_GetPixDepth(PPC *c) { RET(is_handle(A(0)) ? LD16(HP(A(0)) + 32) : 32); }
static void sh_NewGWorldFromPtr(PPC *c)
{
	QRect r = RECT(A(2));
	Port *p = port_new(A(6), (int32_t)(A(7) & 0x3fff), r, 0);
	p->gworld = 2;
	ST32(A(0), p->tok);
	RET(0);
}

// ---- CopyBits ---------------------------------------------------------------------------------------------

static void sh_CopyBits(PPC *c)
{
	qd_copybits(A(0), A(1), RECT(A(2)), RECT(A(3)), (int16_t)A(4), A(5) ? RGN(A(5)) : NULL);
}
static void sh_StdBits(PPC *c)
{
	// StdBits(srcBits, srcRect, dstRect, mode, maskRgn): into the current port
	if (CUR)
		qd_copybits(A(0), CUR->pixmap_ptr, RECT(A(1)), RECT(A(2)), (int16_t)A(3), A(4) ? RGN(A(4)) : NULL);
}
static void sh_CopyMask(PPC *c)
{
	// CopyMask(src, mask, dst, srcRect, maskRect, dstRect): where the mask is set
	BM m;
	read_bm(A(1), &m);
	QRect mr = RECT(A(4)), dr = RECT(A(5));
	Rgn g = {{0, 0, 0, 0}, 0, 0, NULL};
	RgnBuild rb;
	rb_begin(&rb, &g);
	int mw = mr.right - mr.left, mh = mr.bottom - mr.top, dw = dr.right - dr.left, dh = dr.bottom - dr.top;
	for (int y = dr.top; y < dr.bottom && mh > 0 && dh > 0; y++) {
		int my = mr.top + (y - dr.top) * mh / dh;
		int16_t xs[512];
		int n = 0, in = 0;
		for (int x = dr.left; x < dr.right; x++) {
			int mx = mr.left + (x - dr.left) * mw / dw;
			int on = bm_bit(&m, mx, my);
			if (on != in && n < 510) {
				xs[n++] = (int16_t)x;
				in = on;
			}
		}
		if (in)
			xs[n++] = dr.right;
		if (n)
			rb_row(&rb, y, xs, n);
	}
	rb_end(&rb);
	qd_copybits(A(0), A(2), RECT(A(3)), dr, 0, &g);
	free(g.r);
}

// ---- graphics procs ---------------------------------------------------------------------------------------

static void sh_StdTextHost(PPC *c) { sh_StdText(c); }
static void sh_StdTxMeasHost(PPC *c) { sh_StdTxMeas(c); }
static void sh_StdBitsHost(PPC *c) { sh_StdBits(c); }
static void sh_StdNop(PPC *c) { (void)c; }

static void sh_SetStdCProcs(PPC *c)
{
	// CQDProcs: textProc, lineProc, rectProc, rRectProc, ovalProc, arcProc, polyProc, rgnProc, bitsProc,
	// commentProc, txMeasProc, getPicProc, putPicProc, opcodeProc, newProc1, glyphsProc, printerStatusProc, newProc4..6
	uint32_t p = A(0);
	for (int i = 0; i < 20; i++)
		ST32(p + 4 * i, ppc_host_tvec(sh_StdNop));
	ST32(p, ppc_host_tvec(sh_StdTextHost));
	ST32(p + 32, ppc_host_tvec(sh_StdBitsHost));
	ST32(p + 40, ppc_host_tvec(sh_StdTxMeasHost));
}

// ---- devices ------------------------------------------------------------------------------------------------

static void make_gdevice(void)
{
	QRect r = qd_screen_rect();
	gdev_main = NewHandleClearG(62);
	uint32_t pm = NewHandleClearG(50);
	uint32_t g = HP(gdev_main);
	ST16(g + 4, 2);               // directType
	ST32(g + 22, pm);             // gdPMap
	PUTRECT(g + 34, r);           // gdRect
	ST16(g + 20, 0x8000 | 0x4000 | 0x0800 | 1);   // ramInit, mainScreen, screenActive, ...
	uint32_t p = HP(pm);
	ST16(p + 4, 0x8000 | ((r.right * 4) & 0x3fff));
	PUTRECT(p + 6, r);
	ST16(p + 30, 16);
	ST16(p + 32, 32);
	ST16(p + 34, 3);
	ST16(p + 36, 8);
}
static void sh_GetMainDevice(PPC *c) { RET(gdev_main); }
static void sh_GetGDevice(PPC *c) { RET(gdev_main); }
static void sh_GetDeviceList(PPC *c) { RET(gdev_main); }
static void sh_GetNextDevice(PPC *c) { RET(0); }
static void sh_GetMaxDevice(PPC *c) { RET(gdev_main); }
static void sh_TestDeviceAttribute(PPC *c)
{
	// screenDevice 0, noDriver 14, screenActive 15, mainScreen 11, gdDevType 0 (color)...
	int a = (int16_t)A(1);
	RET(a == 0 || a == 11 || a == 13 || a == 15);
}
static void sh_GDeviceChanged(PPC *c) { (void)c; }
static void sh_GetGrayRgn(PPC *c)
{
	static uint32_t gray;
	if (!gray) {
		Rgn *g;
		gray = rgn_handle(&g);
		QRect r = qd_screen_rect();
		r.top = (int16_t)qd_menubar_height;
		rgn_set_rect(g, r);
		rgn_sync(gray);
	}
	RET(gray);
}

// ---- QuickDraw globals and patterns ---------------------------------------------------------------------------

static const uint8_t pat_white[8] = {0}, pat_gray[8] = {0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55},
	pat_ltgray[8] = {0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22},
	pat_dkgray[8] = {0x77, 0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77, 0xdd};
static void sh_GetQDGlobalsBlack(PPC *c) { memcpy(G(A(0)), pat_black, 8); RET(A(0)); }
static void sh_GetQDGlobalsWhite(PPC *c) { memcpy(G(A(0)), pat_white, 8); RET(A(0)); }
static void sh_GetQDGlobalsGray(PPC *c) { memcpy(G(A(0)), pat_gray, 8); RET(A(0)); }
static void sh_GetQDGlobalsLightGray(PPC *c) { memcpy(G(A(0)), pat_ltgray, 8); RET(A(0)); }
static void sh_GetQDGlobalsDarkGray(PPC *c) { memcpy(G(A(0)), pat_dkgray, 8); RET(A(0)); }
static void sh_SetQDGlobalsRandomSeed(PPC *c) { extern uint32_t qd_random_seed; qd_random_seed = A(0); }

// the system pattern list 'PAT#' 0
static const uint8_t sys_pats[38][8] = {
	{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, {0xdd, 0xff, 0x77, 0xff, 0xdd, 0xff, 0x77, 0xff},
	{0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77, 0xdd, 0x77}, {0xaa, 0xff, 0xaa, 0xff, 0xaa, 0xff, 0xaa, 0xff},
	{0x55, 0xff, 0x55, 0xff, 0x55, 0xff, 0x55, 0xff}, {0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55},
	{0xee, 0xdd, 0xbb, 0x77, 0xee, 0xdd, 0xbb, 0x77}, {0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88},
	{0xb1, 0x30, 0x03, 0x1b, 0xd8, 0xc0, 0x0c, 0x8d}, {0x80, 0x10, 0x02, 0x20, 0x01, 0x08, 0x40, 0x04},
	{0xff, 0x88, 0x88, 0x88, 0xff, 0x88, 0x88, 0x88}, {0xff, 0x80, 0x80, 0x80, 0xff, 0x08, 0x08, 0x08},
	{0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, {0x80, 0x40, 0x20, 0x00, 0x02, 0x04, 0x08, 0x00},
	{0x82, 0x44, 0x39, 0x44, 0x82, 0x01, 0x01, 0x01}, {0xf8, 0x74, 0x22, 0x47, 0x8f, 0x17, 0x22, 0x71},
	{0x55, 0xa0, 0x40, 0x40, 0x55, 0x0a, 0x04, 0x04}, {0x20, 0x50, 0x88, 0x88, 0x88, 0x88, 0x05, 0x02},
	{0xbf, 0x00, 0xbf, 0xbf, 0xb0, 0xb0, 0xb0, 0xb0}, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	{0x80, 0x00, 0x08, 0x00, 0x80, 0x00, 0x08, 0x00}, {0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00},
	{0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22}, {0xaa, 0x00, 0xaa, 0x00, 0xaa, 0x00, 0xaa, 0x00},
	{0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00}, {0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88},
	{0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00}, {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80},
	{0xaa, 0x00, 0x80, 0x00, 0x88, 0x00, 0x80, 0x00}, {0xff, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80},
	{0x08, 0x1c, 0x22, 0xc1, 0x80, 0x01, 0x02, 0x04}, {0x88, 0x14, 0x22, 0x41, 0x88, 0x00, 0xaa, 0x00},
	{0x40, 0xa0, 0x00, 0x00, 0x04, 0x0a, 0x00, 0x00}, {0x03, 0x84, 0x48, 0x30, 0x0c, 0x02, 0x01, 0x01},
	{0x80, 0x80, 0x41, 0x3e, 0x08, 0x08, 0x14, 0xe3}, {0x10, 0x20, 0x54, 0xaa, 0xff, 0x02, 0x04, 0x08},
	{0x77, 0x89, 0x8f, 0x8f, 0x77, 0x98, 0xf8, 0xf8}, {0x00, 0x08, 0x14, 0x2a, 0x55, 0x2a, 0x14, 0x08},
};
static void sh_GetIndPattern(PPC *c)
{
	// GetIndPattern(Pattern *, patternListID, index)
	extern uint32_t res_get(uint32_t type, int16_t id, int one);
	int id = (int16_t)A(1), idx = (int16_t)A(2);
	if (id != 0) {
		uint32_t h = res_get('PAT#', (int16_t)id, 0);
		if (h && idx >= 1 && idx <= (int)LD16(HP(h))) {
			memcpy(G(A(0)), G(HP(h) + 2 + 8 * (idx - 1)), 8);
			return;
		}
	}
	if (idx >= 1 && idx <= 38)
		memcpy(G(A(0)), sys_pats[idx - 1], 8);
}

// ---- cursors ----------------------------------------------------------------------------------------------------

static uint8_t arrow_data[68] = {
	0x00, 0x00, 0x40, 0x00, 0x60, 0x00, 0x70, 0x00, 0x78, 0x00, 0x7c, 0x00, 0x7e, 0x00, 0x7f, 0x00,
	0x7f, 0x80, 0x7c, 0x00, 0x6c, 0x00, 0x46, 0x00, 0x06, 0x00, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00,
	0xc0, 0x00, 0xe0, 0x00, 0xf0, 0x00, 0xf8, 0x00, 0xfc, 0x00, 0xfe, 0x00, 0xff, 0x00, 0xff, 0x80,
	0xff, 0xc0, 0xff, 0xe0, 0xfe, 0x00, 0xef, 0x00, 0xcf, 0x00, 0x87, 0x80, 0x07, 0x80, 0x03, 0x80,
	0x00, 0x01, 0x00, 0x01,
};
static void sh_GetQDGlobalsArrow(PPC *c) { memcpy(G(A(0)), arrow_data, 68); RET(A(0)); }

static NSMutableDictionary *cursor_cache;
static NSCursor *cursor_from(uint32_t a)
{
	if (!memcmp(G(a), arrow_data, 64))
		return NSCursor.arrowCursor;
	NSData *key = [NSData dataWithBytes:G(a) length:68];
	if (!cursor_cache)
		cursor_cache = [NSMutableDictionary new];
	NSCursor *cur = cursor_cache[key];
	if (cur)
		return cur;
	// marks of the system cursors (see res.m)
	const uint8_t *d = G(a);
	if (!memcmp(d, "\xffSYSiBem", 8))
		cur = NSCursor.IBeamCursor;
	else if (!memcmp(d, "\xffSYScros", 8))
		cur = NSCursor.crosshairCursor;
	else if (!memcmp(d, "\xffSYSplus", 8))
		cur = NSCursor.crosshairCursor;
	else if (!memcmp(d, "\xffSYSwatc", 8))
		cur = NSCursor.arrowCursor;
	else {
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:16 pixelsHigh:16
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
			bytesPerRow:64 bitsPerPixel:32];
		uint8_t *px = rep.bitmapData;
		for (int y = 0; y < 16; y++)
			for (int x = 0; x < 16; x++) {
				int bit = (d[2 * y + x / 8] >> (7 - x % 8)) & 1, m = (d[32 + 2 * y + x / 8] >> (7 - x % 8)) & 1;
				uint8_t *q = px + 64 * y + 4 * x;
				q[0] = q[1] = q[2] = bit ? 0 : 255;
				q[3] = (m || bit) ? 255 : 0;
			}
		NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
		[img addRepresentation:rep];
		cur = [[[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint((int16_t)((d[66] << 8) | d[67]), (int16_t)((d[64] << 8) | d[65]))] autorelease];
		[img release];
		[rep release];
	}
	cursor_cache[key] = cur;
	return cur;
}
static void sh_SetCursor(PPC *c) { if (A(0)) [cursor_from(A(0)) set]; }
static void sh_InitCursor(PPC *c) { [NSCursor.arrowCursor set]; }

// ---- Core Graphics for a port ------------------------------------------------------------------------------------

static void sh_CreateCGContextForPort(PPC *c)
{
	ppc_log("CreateCGContextForPort: not supported");
	if (A(1))
		ST32(A(1), 0);
	RET(-50);
}

void qd_init(void)
{
	make_gdevice();
	QRect r = qd_screen_rect();
	screen_port = port_new(0, 0, r, 0);
	screen_port->pix = 0;
	qd_port = screen_port;
}

static const ShimDef qdshims[] = {
	S(GetPort), S(SetPort), S(GetPortBounds), S(SetPortBounds), S(GetPortVisibleRegion), S(SetPortVisibleRegion),
	S(GetPortPixMap), S(GetPortBitMapForCopyBits), S(GetPortTextFont), S(GetPortTextSize), S(GetPortTextFace),
	S(GetPortTextMode), S(GetPortGrafProcs), S(SetPortGrafProcs), S(IsPortRegionBeingDefined), S(QDFlushPortBuffer),
	S(QDError), S(QDDone), S(LockPortBits), {"UnlockPortBits", sh_LockPortBits}, S(SetOrigin), S(ClipRect), S(SetClip),
	S(GetClip), S(GlobalToLocal), S(LocalToGlobal), S(MoveTo), S(Move), S(LineTo), S(Line), S(PenSize), S(PenMode),
	S(PenPat), S(BackPat), S(PenNormal), S(HidePen), S(ShowPen), S(GetPenState), S(SetPenState), S(RGBForeColor),
	S(RGBBackColor), S(GetForeColor), S(GetBackColor), S(OpColor), S(InvertColor), S(ForeColor), S(BackColor),
	S(GetGray), S(FrameRect), S(PaintRect), S(EraseRect), S(InvertRect), S(FillRect), S(FrameOval), S(EraseOval),
	S(PaintOval), S(FrameRoundRect), S(FrameArc), S(PaintArc), S(FillArc), S(OpenPoly), S(ClosePoly), S(KillPoly),
	S(FramePoly), S(PaintPoly), S(FillPoly), S(FrameRgn), S(PaintRgn), S(EraseRgn), S(InvertRgn), S(FillRgn),
	S(ScrollRect), S(SetRect), S(OffsetRect), S(InsetRect), S(SectRect), S(UnionRect), S(EqualRect), S(EmptyRect),
	S(PtInRect), S(PinRect), S(EqualPt), S(MapRect), S(NewRgn), S(DisposeRgn), S(CopyRgn), S(SetEmptyRgn),
	S(SetRectRgn), S(RectRgn), S(OffsetRgn), S(InsetRgn), S(SectRgn), S(UnionRgn), S(DiffRgn), S(EmptyRgn),
	S(PtInRgn), S(RectInRgn), S(GetRegionBounds), S(BitMapToRegion), S(OpenRgn), S(CloseRgn), S(TextFont),
	S(TextFace), S(TextMode), S(TextSize), S(DrawString), S(DrawText), S(StdText), S(StdTxMeas), S(StringWidth),
	S(TextWidth), S(CharWidth), S(GetFontInfo), S(GetFNum), S(GetFontName), S(GetSysFont), S(GetAppFont),
	S(GetDefFontSize), S(SetOutlinePreferred), S(FMSwapFont), S(TruncString), S(NewGWorld), S(DisposeGWorld),
	S(GetGWorld), S(SetGWorld), S(GetGWorldPixMap), S(LockPixels), {"UnlockPixels", sh_StdNop}, S(GetPixBaseAddr),
	S(GetPixDepth), S(NewGWorldFromPtr), S(CopyBits), S(StdBits), S(CopyMask), S(SetStdCProcs), S(GetMainDevice),
	S(GetGDevice), S(GetDeviceList), S(GetNextDevice), S(GetMaxDevice), S(TestDeviceAttribute), S(GDeviceChanged),
	S(GetGrayRgn), S(GetQDGlobalsBlack), S(GetQDGlobalsWhite), S(GetQDGlobalsGray), S(GetQDGlobalsLightGray),
	S(GetQDGlobalsDarkGray), S(SetQDGlobalsRandomSeed), S(GetIndPattern), S(GetQDGlobalsArrow), S(SetCursor),
	S(InitCursor), S(CreateCGContextForPort), {"NewQDTextUPP", sh_StdNop}, {"NewQDTxMeasUPP", sh_StdNop},
	{"NewQDBitsUPP", sh_StdNop}, {"DisposeQDBitsUPP", sh_StdNop},
};
REGISTER(qdshims)
