// Icon Utilities (see icons.h).
#import <AppKit/AppKit.h>
#include "icons.h"
#include "hmap.h"

const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len);
extern uint8_t mac_clut8[256][3];
extern const uint8_t mac_clut4[16][3];
const char *fsspec_path(uint32_t spec, char *out, size_t n);

static int bit(const uint8_t *d, int rowBytes, int x, int y) { return (d[y * rowBytes + x / 8] >> (7 - x % 8)) & 1; }

// RGBA pixels (premultiplied) as a CGImage
static CGImageRef make_image(const uint32_t *px, int w, int h)
{
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CFDataRef d = CFDataCreate(NULL, (const UInt8 *)px, (CFIndex)w * h * 4);
	CGDataProviderRef dp = CGDataProviderCreateWithCFData(d);
	CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, dp, NULL, false,
		kCGRenderingIntentDefault);
	CGDataProviderRelease(dp);
	CFRelease(d);
	CGColorSpaceRelease(cs);
	return img;
}

static uint32_t rgba(int r, int g, int b, int a)
{
	r = r * a / 255;
	g = g * a / 255;
	b = b * a / 255;
	return (uint32_t)r | (uint32_t)g << 8 | (uint32_t)b << 16 | (uint32_t)a << 24;
}

static void transform_px(uint32_t *px, int n, int transform)
{
	int t = transform & 0xff;
	int sel = (transform & 0x4000) != 0;
	for (int i = 0; i < n; i++) {
		uint32_t v = px[i];
		int r = v & 0xff, g = (v >> 8) & 0xff, b = (v >> 16) & 0xff, a = v >> 24;
		if (sel) {
			r = r * 2 / 3;
			g = g * 2 / 3;
			b = b * 2 / 3;
		}
		if (t == 1 || t == 2) {   // disabled, offline
			r /= 2; g /= 2; b /= 2; a /= 2;
		}
		px[i] = (uint32_t)r | (uint32_t)g << 8 | (uint32_t)b << 16 | (uint32_t)a << 24;
	}
}

static QRect align_rect(QRect r, int w, int h, int align)
{
	int rw = r.right - r.left, rh = r.bottom - r.top;
	// scale down to fit, never up beyond the rectangle
	double s = 1;
	if (w > rw || h > rh)
		s = fmin((double)rw / w, (double)rh / h);
	else if (rw >= w * 2 && rh >= h * 2 && w <= 16)
		s = fmin((double)rw / w, (double)rh / h);
	int dw = (int)(w * s), dh = (int)(h * s);
	int x = r.left + (rw - dw) / 2, y = r.top + (rh - dh) / 2;
	if (align & 0x8) y = r.top;            // kAlignTop
	if (align & 0x4) y = r.bottom - dh;    // kAlignBottom
	if (align & 0x2) x = r.left;           // kAlignLeft
	if (align & 0x1) x = r.right - dw;     // kAlignRight
	return (QRect){(int16_t)y, (int16_t)x, (int16_t)(y + dh), (int16_t)(x + dw)};
}

// an icon family member by resource id; size 32 or 16
static int family_pixels(int16_t id, int size, uint32_t *px)
{
	uint32_t ml, cl;
	const uint8_t *mask = res_bytes(size == 32 ? 'ICN#' : 'ics#', id, &ml);
	int rb = size / 8, plane = rb * size;
	const uint8_t *c8 = res_bytes(size == 32 ? 'icl8' : 'ics8', id, &cl);
	int depth = 8;
	if (!c8 || cl < (uint32_t)(size * size)) {
		c8 = res_bytes(size == 32 ? 'icl4' : 'ics4', id, &cl);
		depth = 4;
		if (!c8 || cl < (uint32_t)(size * size / 2))
			c8 = NULL;
	}
	if (!mask && !c8)
		return 0;
	if (mask && ml < (uint32_t)plane * 2)
		mask = NULL;
	for (int y = 0; y < size; y++)
		for (int x = 0; x < size; x++) {
			int a = mask ? bit(mask + plane, rb, x, y) : 1;
			int r, g, b;
			if (c8) {
				int k = depth == 8 ? c8[y * size + x] : (c8[(y * size + x) / 2] >> (x & 1 ? 0 : 4)) & 15;
				const uint8_t *e = depth == 8 ? mac_clut8[k] : mac_clut4[k];
				r = e[0];
				g = e[1];
				b = e[2];
			} else {
				int on = bit(mask, rb, x, y);
				r = g = b = on ? 0 : 255;
			}
			px[y * size + x] = a ? rgba(r, g, b, 255) : 0;
		}
	return 1;
}

static void plot_family(Port *p, QRect r, int align, int transform, int16_t id)
{
	int rw = r.right - r.left, rh = r.bottom - r.top;
	int size = rw < 32 && rh < 32 ? 16 : 32;
	uint32_t px[32 * 32];
	if (!family_pixels(id, size, px)) {
		size = 48 - size;
		if (!family_pixels(id, size, px))
			return;
	}
	transform_px(px, size * size, transform);
	CGImageRef img = make_image(px, size, size);
	qd_draw_image(p, img, align_rect(r, size, size, align));
	CGImageRelease(img);
}

void icon_plot_id(Port *p, QRect r, int align, int transform, int16_t id)
{
	uint32_t len;
	if (res_bytes('ICN#', id, &len) || res_bytes('icl8', id, &len) || res_bytes('ics#', id, &len)) {
		plot_family(p, r, align, transform, id);
		return;
	}
	uint32_t h = cicn_get(id);
	if (h)
		icon_plot_cicn(p, r, h);
}

// ---- cicn -------------------------------------------------------------------------------------------

static HMap cicns;   // id+1 -> guest handle (kept)

uint32_t cicn_get(int16_t id)
{
	uint32_t key = (uint32_t)(uint16_t)id + 1;
	uint32_t h = (uint32_t)(uintptr_t)hm_get(&cicns, key);
	if (h)
		return h;
	uint32_t len;
	const uint8_t *d = res_bytes('cicn', id, &len);
	if (!d)
		return 0;
	h = NewHandleFrom(d, len);
	hm_put(&cicns, key, (void *)(uintptr_t)h);
	return h;
}

static uint16_t be16(const uint8_t *d) { return (uint16_t)(d[0] << 8 | d[1]); }

static CGImageRef cicn_image(const uint8_t *d, uint32_t len, int *w, int *h)
{
	if (len < 82)
		return NULL;
	int prb = be16(d + 4) & 0x3fff;
	QRect b = {(int16_t)be16(d + 6), (int16_t)be16(d + 8), (int16_t)be16(d + 10), (int16_t)be16(d + 12)};
	int depth = be16(d + 32);
	int mrb = be16(d + 54);
	int irb = be16(d + 68);
	int ww = b.right - b.left, hh = b.bottom - b.top;
	if (ww <= 0 || hh <= 0 || ww > 512 || hh > 512)
		return NULL;
	uint32_t o = 82;
	const uint8_t *mask = d + o;
	o += (uint32_t)mrb * hh;
	const uint8_t *bw = d + o;
	o += (uint32_t)irb * hh;
	if (o + 8 > len)
		return NULL;
	int ctsize = be16(d + o + 6) + 1;
	const uint8_t *ct = d + o + 8;
	uint8_t clut[256][3] = {{0}};
	for (int i = 0; i < ctsize && i < 256; i++) {
		const uint8_t *e = ct + i * 8;
		int v = be16(e) & 0xff;
		if (be16(d + o + 4) & 0x8000)   // device table: by position
			v = i;
		clut[v][0] = e[2];
		clut[v][1] = e[4];
		clut[v][2] = e[6];
	}
	o += 8 + ctsize * 8;
	const uint8_t *pix = d + o;
	int have_pix = prb && depth && o + (uint32_t)prb * hh <= len;
	uint32_t *px = calloc((size_t)ww * hh, 4);
	for (int y = 0; y < hh; y++)
		for (int x = 0; x < ww; x++) {
			int a = mrb ? bit(mask, mrb, x, y) : 1;
			if (!a)
				continue;
			int r, g, bl;
			if (have_pix) {
				int k;
				const uint8_t *row = pix + y * prb;
				switch (depth) {
				case 1: k = (row[x / 8] >> (7 - x % 8)) & 1; break;
				case 2: k = (row[x / 4] >> (6 - 2 * (x % 4))) & 3; break;
				case 4: k = (row[x / 2] >> (x & 1 ? 0 : 4)) & 15; break;
				default: k = row[x]; break;
				}
				r = clut[k][0];
				g = clut[k][1];
				bl = clut[k][2];
			} else {
				int on = irb ? bit(bw, irb, x, y) : 1;
				r = g = bl = on ? 0 : 255;
			}
			px[y * ww + x] = rgba(r, g, bl, 255);
		}
	CGImageRef img = make_image(px, ww, hh);
	free(px);
	*w = ww;
	*h = hh;
	return img;
}

void icon_plot_cicn(Port *p, QRect r, uint32_t h)
{
	if (!h || !is_handle(h))
		return;
	int w, ht;
	CGImageRef img = cicn_image(G(HP(h)), HSize(h), &w, &ht);
	if (!img)
		return;
	// PlotCIcon stretches the icon to the rectangle
	qd_draw_image(p, img, r);
	CGImageRelease(img);
}

// ---- icon suites and IconRefs ------------------------------------------------------------------------

// a suite: a guest handle {'XLis', resource id}; an IconRef: a guest block {'XLir', id or -1, path}
static void plot_ns(Port *p, QRect r, NSImage *im)
{
	if (!im)
		return;
	int w = r.right - r.left, h = r.bottom - r.top;
	NSRect nr = NSMakeRect(0, 0, w, h);
	CGImageRef img = [im CGImageForProposedRect:&nr context:nil hints:nil];
	if (img)
		qd_draw_image(p, img, r);
}

void icon_plot_suite(Port *p, QRect r, int align, int transform, uint32_t suite)
{
	if (!suite || !is_handle(suite) || LD32(HP(suite)) != 'XLis')
		return;
	plot_family(p, r, align, transform, (int16_t)LD16(HP(suite) + 4));
}

static NSMutableDictionary *ref_images;

void icon_plot_ref(Port *p, QRect r, uint32_t ref)
{
	if (!ref || LD32(ref) != 'XLir')
		return;
	int16_t id = (int16_t)LD16(ref + 4);
	if (id != -1) {
		plot_family(p, r, 0, 0, id);
		return;
	}
	NSImage *im = ref_images[@(ref)];
	plot_ns(p, r, im);
}

static void sh_GetCIcon(PPC *c)
{
	uint32_t len;
	const uint8_t *d = res_bytes('cicn', (int16_t)A(0), &len);
	RET(d ? NewHandleFrom(d, len) : 0);
}
static void sh_DisposeCIcon(PPC *c)
{
	uint32_t h = A(0);
	for (uint32_t i = 0; i < cicns.cap; i++)
		if (cicns.k[i] && cicns.k[i] != 0xffffffffu && (uint32_t)(uintptr_t)cicns.v[i] == h)
			return;   // a cached one
	DisposeHandleG(h);
}
static void sh_PlotCIcon(PPC *c) { if (qd_port) icon_plot_cicn(qd_port, RECT(A(0)), A(1)); }
static void sh_PlotIconID(PPC *c)
{
	// PlotIconID(rect, align, transform, resID)
	if (qd_port)
		icon_plot_id(qd_port, RECT(A(0)), (int16_t)A(1), (int16_t)A(2), (int16_t)A(3));
	RET(0);
}
static void sh_GetIconSuite(PPC *c)
{
	// GetIconSuite(&suite, id, selector)
	uint32_t h = NewHandleClearG(8);
	ST32(HP(h), 'XLis');
	ST16(HP(h) + 4, (uint16_t)A(1));
	ST32(A(0), h);
	uint32_t len;
	RET(res_bytes('ICN#', (int16_t)A(1), &len) || res_bytes('icl8', (int16_t)A(1), &len) || res_bytes('ics#', (int16_t)A(1), &len) ? 0 : -192);
}
static void sh_DisposeIconSuite(PPC *c) { if (A(0) && is_handle(A(0))) DisposeHandleG(A(0)); RET(0); }
static void sh_PlotIconSuite(PPC *c)
{
	// PlotIconSuite(rect, align, transform, suite)
	if (qd_port)
		icon_plot_suite(qd_port, RECT(A(0)), (int16_t)A(1), (int16_t)A(2), A(3));
	RET(0);
}
static uint32_t new_ref(int16_t id)
{
	uint32_t r = gcalloc(16);
	ST32(r, 'XLir');
	ST16(r + 4, (uint16_t)id);
	ST32(r + 8, 1);
	return r;
}
static void sh_GetIconRef(PPC *c)
{
	// GetIconRef(vRefNum, creator, type, &ref)
	uint32_t r = new_ref(-1);
	uint32_t type = A(2);
	char t[5] = {(char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type, 0};
	NSImage *im = nil;
	if (type == 'fldr')
		im = [NSWorkspace.sharedWorkspace iconForFile:@"/System"];
	else
		im = [NSWorkspace.sharedWorkspace iconForFileType:NSFileTypeForHFSTypeCode(type)];
	(void)t;
	if (!ref_images)
		ref_images = [NSMutableDictionary new];
	if (im)
		ref_images[@(r)] = im;
	ST32(A(3), r);
	RET(0);
}
static void sh_RegisterIconRefFromResource(PPC *c)
{
	// RegisterIconRefFromResource(creator, type, FSSpec *, resID, &ref)
	ST32(A(4), new_ref((int16_t)A(3)));
	RET(0);
}
static void sh_ReleaseIconRef(PPC *c) { RET(0); (void)c; }
static void sh_UnregisterIconRef(PPC *c) { RET(0); (void)c; }
static void sh_PlotIconRef(PPC *c)
{
	// PlotIconRef(rect, align, transform, flags, ref)
	if (qd_port)
		icon_plot_ref(qd_port, RECT(A(0)), A(4));
	RET(0);
}

static const ShimDef iconshims[] = {
	S(GetCIcon), S(DisposeCIcon), S(PlotCIcon), S(PlotIconID), S(GetIconSuite), S(DisposeIconSuite),
	S(PlotIconSuite), S(GetIconRef), S(RegisterIconRefFromResource), S(ReleaseIconRef), S(UnregisterIconRef),
	S(PlotIconRef),
};
REGISTER(iconshims)
