// QuickDraw: graphics ports over 32-bit pixel buffers in guest memory.
//
// Every port draws into k32ARGBPixelFormat pixels (bytes X R G B per pixel)
// that live in the guest window, so guest code can address them (GWorlds) and
// Core Graphics can draw into them (text, theme controls). Coordinates are
// local: pixel (x, y) is at (x - bounds.left, y - bounds.top) in the buffer.
#ifndef QD_H
#define QD_H
#include "ppcrt.h"
#include "rgn.h"
#include <CoreGraphics/CoreGraphics.h>

typedef struct { uint16_t r, g, b; } RGB16;

struct Win;

typedef struct Port {
	uint32_t tok;            // CGrafPtr
	uint32_t pix;            // pixel buffer
	int32_t rowBytes;
	QRect bounds;            // local coordinates of the buffer
	QRect portRect;
	Rgn *vis, *clip;
	QPoint pnLoc, pnSize;
	int pnMode, pnVis;
	uint8_t pnPat[8], bkPat[8], fillPat[8];
	RGB16 fg, bg, op, hilite;
	int txFont, txFace, txMode, txSize, spExtra;
	uint32_t grafProcs;
	struct Win *win;
	int gworld;
	uint32_t pixmap;         // PixMapHandle (guest PixMap)
	uint32_t pixmap_ptr;     // the PixMap itself, as GetPortBitMapForCopyBits returns
	CGContextRef cg;         // over the pixels (cached)
	uint32_t cg_pix;
	int rec_rgn;             // recording a region (OpenRgn)
	struct QDPict *rec_pic; // recording a picture (OpenPicture)
	uint32_t devH;
	// a GWorld of less than 32 bits: the guest sees pixels of that depth in
	// "shadow"; QuickDraw draws into pix. shadow_state: 0 pix is current,
	// 1 both are, 2 the guest may have written the shadow.
	uint32_t shadow, sctab;
	int sdepth, srow, shadow_state;
} Port;
void port_shadow_sync(Port *p, int for_guest);   // for_guest: before the guest reads the shadow

extern Port *qd_port;                 // the current port
Port *PORT(uint32_t tok);
Port *port_new(uint32_t pix, int32_t rowBytes, QRect bounds, int own_pixels);
void port_free(Port *p);
void port_resize(Port *p, QRect bounds);   // a window port after SizeWindow: new pixels
void port_sync_pixmap(Port *p);
void qd_init(void);

// colors: pixels are native uint32 values of bytes X R G B
static inline uint32_t PIXV(int r, int g, int b) { return 0xffu | (uint32_t)r << 8 | (uint32_t)g << 16 | (uint32_t)b << 24; }
static inline uint32_t rgb_pix(RGB16 c) { return PIXV(c.r >> 8, c.g >> 8, c.b >> 8); }
static inline RGB16 pix_rgb(uint32_t p)
{
	RGB16 c = {(uint16_t)(((p >> 8) & 0xff) * 257), (uint16_t)(((p >> 16) & 0xff) * 257), (uint16_t)(((p >> 24) & 0xff) * 257)};
	return c;
}
static inline uint32_t *PIXP(Port *p, int x, int y)
{
	return (uint32_t *)G(p->pix + (uint32_t)((y - p->bounds.top) * p->rowBytes + (x - p->bounds.left) * 4));
}

// drawing
typedef struct { const uint8_t *pat; RGB16 fg, bg; int mode; } Paint;
void qd_fill(Port *p, const Rgn *shape, Paint pt);         // shape in local coordinates
void qd_fill_rect(Port *p, QRect r, Paint pt);
Paint qd_pen(Port *p);
Paint qd_back(Port *p);
Paint qd_solid(Port *p, const uint8_t *pat);   // fill with the port's colors
void qd_clip_region(Port *p, Rgn *out);         // clip ∩ vis ∩ bounds
void qd_dirty(Port *p, QRect r);                // window ports: mark for display

// Core Graphics over a port: flipped (y down), local coordinates, clipped; restore with qd_cg_end
CGContextRef qd_cg_begin(Port *p);
void qd_cg_end(Port *p);

// text
void qd_text_draw(Port *p, const uint8_t *s, int n);
double qd_text_width(Port *p, const uint8_t *s, int n);
void qd_font_info(Port *p, int *ascent, int *descent, int *widMax, int *leading);
#ifdef __OBJC__
#import <CoreText/CoreText.h>
CTFontRef qd_font(int font, int size, int face);
NSString *qd_font_name(int font);
int qd_font_num(NSString *name);
#endif

// CopyBits between guest BitMaps/PixMaps
void qd_copybits(uint32_t src, uint32_t dst, QRect sr, QRect dr, int mode, Rgn *mask);
void qd_draw_image(Port *p, CGImageRef img, QRect dst);

// screen
QRect qd_screen_rect(void);   // main screen in global coordinates
extern int qd_menubar_height;
int qd_global_y(double cocoa_y);   // Cocoa screen y -> QuickDraw global v
double qd_cocoa_y(int v);

// regions of guest handles (RgnHandle shims also use these)
void qd_hidecursor_reset(void);

#endif
