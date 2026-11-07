// Drag Manager for drags inside the application: TrackDrag follows the mouse
// with an image of the dragged region and calls the guest's tracking and
// receive handlers of the windows it passes over.
#import <AppKit/AppKit.h>
#include "win.h"

void ev_drop_mouseups(void);

typedef struct { uint32_t type, flags; NSData *data; } Flavor;
typedef struct { uint32_t ref; QRect bounds; Flavor fl[8]; int nfl; } DItem;
typedef struct {
	uint32_t tok;
	DItem items[16];
	int n;
	QPoint mouse;
	uint32_t attrs;
	// the hilite and the pixels under it
	Port *hl_port;
	QRect hl_rect;
	uint32_t *hl_save;
} Drag;

typedef struct { uint32_t proc, win, refcon; } DHandler;
static DHandler tracking[16], receive[16];
static int ntracking, nreceive;

static Drag *DR(uint32_t t) { return tok_get(t, 'XLdg'); }

static DItem *item_of(Drag *d, uint32_t ref, int create)
{
	for (int i = 0; i < d->n; i++)
		if (d->items[i].ref == ref)
			return &d->items[i];
	if (!create || d->n == 16)
		return NULL;
	DItem *it = &d->items[d->n++];
	memset(it, 0, sizeof *it);
	it->ref = ref;
	return it;
}

static void sh_NewDrag(PPC *c)
{
	Drag *d = calloc(1, sizeof *d);
	d->tok = tok_new(d, 16, 'XLdg');
	ST32(A(0), d->tok);
	RET(0);
}
static void hide_hilite(Drag *d);
static void sh_DisposeDrag(PPC *c)
{
	Drag *d = DR(A(0));
	if (!d)
		return RET(0);
	hide_hilite(d);
	for (int i = 0; i < d->n; i++)
		for (int k = 0; k < d->items[i].nfl; k++)
			[d->items[i].fl[k].data release];
	tok_free(d->tok);
	free(d);
	RET(0);
}
static void sh_AddDragItemFlavor(PPC *c)
{
	// (drag, itemRef, type, data, size, flags)
	Drag *d = DR(A(0));
	DItem *it = d ? item_of(d, A(1), 1) : NULL;
	if (!it || it->nfl == 8)
		return RET(-50);
	Flavor *f = &it->fl[it->nfl++];
	f->type = A(2);
	f->flags = A(5);
	f->data = [[NSData alloc] initWithBytes:A(3) ? G(A(3)) : "" length:A(3) ? A(4) : 0];
	RET(0);
}
static void sh_SetDragItemBounds(PPC *c) { Drag *d = DR(A(0)); DItem *it = d ? item_of(d, A(1), 1) : NULL; if (it) it->bounds = RECT(A(2)); RET(0); }
static void sh_GetDragItemBounds(PPC *c) { Drag *d = DR(A(0)); DItem *it = d ? item_of(d, A(1), 0) : NULL; if (it) PUTRECT(A(2), it->bounds); RET(it ? 0 : -1852); }
static void sh_SetDragImage(PPC *c) { (void)c; RET(0); }
static void sh_CountDragItems(PPC *c) { Drag *d = DR(A(0)); ST16(A(1), d ? (uint16_t)d->n : 0); RET(0); }
static void sh_GetDragItemReferenceNumber(PPC *c)
{
	Drag *d = DR(A(0));
	int i = (uint16_t)A(1);
	if (!d || i < 1 || i > d->n)
		return RET(-1852);   // badDragItemErr
	ST32(A(2), d->items[i - 1].ref);
	RET(0);
}
static Flavor *flavor(PPC *c, Drag *d)
{
	DItem *it = d ? item_of(d, A(1), 0) : NULL;
	if (!it)
		return NULL;
	for (int k = 0; k < it->nfl; k++)
		if (it->fl[k].type == A(2))
			return &it->fl[k];
	return NULL;
}
static void sh_GetFlavorFlags(PPC *c)
{
	Flavor *f = flavor(c, DR(A(0)));
	if (A(3))
		ST32(A(3), f ? f->flags : 0);
	RET(f ? 0 : -1854);   // badDragFlavorErr
}
static void sh_GetFlavorDataSize(PPC *c)
{
	Flavor *f = flavor(c, DR(A(0)));
	if (A(3))
		ST32(A(3), f ? (uint32_t)f->data.length : 0);
	RET(f ? 0 : -1854);
}
static void sh_GetFlavorData(PPC *c)
{
	// (drag, item, type, dataPtr, Size *dataSize, dataOffset)
	Flavor *f = flavor(c, DR(A(0)));
	if (!f)
		return RET(-1854);
	uint32_t off = A(5), want = LD32(A(4));
	uint32_t n = (uint32_t)f->data.length > off ? (uint32_t)f->data.length - off : 0;
	if (n > want)
		n = want;
	memcpy(G(A(3)), (const uint8_t *)f->data.bytes + off, n);
	ST32(A(4), n);
	RET(0);
}
static void sh_GetDragAttributes(PPC *c) { Drag *d = DR(A(0)); ST32(A(1), d ? d->attrs : 0); RET(0); }
static void sh_GetDragMouse(PPC *c)
{
	Drag *d = DR(A(0));
	QPoint m = d ? d->mouse : ev_mouse_global();
	if (A(1))
		STPT(A(1), m);
	if (A(2))
		STPT(A(2), m);
	RET(0);
}

static void hide_hilite(Drag *d)
{
	if (!d->hl_save)
		return;
	Port *p = d->hl_port;
	QRect r = d->hl_rect;
	int w = r.right - r.left;
	for (int y = r.top; y < r.bottom; y++)
		memcpy(PIXP(p, r.left, y), d->hl_save + (y - r.top) * w, (size_t)w * 4);
	qd_dirty(p, r);
	free(d->hl_save);
	d->hl_save = NULL;
}

static void sh_ShowDragHilite(PPC *c)
{
	// (drag, RgnHandle hiliteFrame, Boolean inside): in the current port's local coordinates
	Drag *d = DR(A(0));
	Rgn *g = RGN(A(1));
	Port *p = qd_port;
	if (!d || !g || !p || !p->pix)
		return RET(0);
	hide_hilite(d);
	QRect r = g->bbox;
	if (!(A(2) & 0xff))
		r = (QRect){(int16_t)(r.top - 3), (int16_t)(r.left - 3), (int16_t)(r.bottom + 3), (int16_t)(r.right + 3)};
	r = rect_sect(r, p->bounds);
	if (rect_empty(r))
		return RET(0);
	int w = r.right - r.left;
	d->hl_port = p;
	d->hl_rect = r;
	d->hl_save = malloc((size_t)w * (r.bottom - r.top) * 4);
	for (int y = r.top; y < r.bottom; y++)
		memcpy(d->hl_save + (y - r.top) * w, PIXP(p, r.left, y), (size_t)w * 4);
	CGContextRef cg = qd_cg_begin(p);
	CGContextSetRGBStrokeColor(cg, p->hilite.r / 65535.0 * 0.6, p->hilite.g / 65535.0 * 0.6, p->hilite.b / 65535.0 * 0.9, 1);
	CGContextSetLineWidth(cg, 3);
	CGContextStrokeRect(cg, CGRectMake(r.left + 1.5, r.top + 1.5, w - 3, r.bottom - r.top - 3));
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_HideDragHilite(PPC *c) { Drag *d = DR(A(0)); if (d) hide_hilite(d); RET(0); }

static void install(DHandler *t, int *n, PPC *c)
{
	for (int i = 0; i < *n; i++)
		if (t[i].proc == A(0) && t[i].win == A(1)) {
			t[i].refcon = A(2);
			return;
		}
	if (*n < 16)
		t[(*n)++] = (DHandler){A(0), A(1), A(2)};
}
static void sh_InstallTrackingHandler(PPC *c) { install(tracking, &ntracking, c); RET(0); }
static void sh_InstallReceiveHandler(PPC *c) { install(receive, &nreceive, c); RET(0); }
static void remove_h(DHandler *t, int *n, PPC *c)
{
	for (int i = 0; i < *n; i++)
		if (t[i].proc == A(0) && t[i].win == A(1)) {
			t[i] = t[--(*n)];
			return;
		}
}
static void sh_RemoveTrackingHandler(PPC *c) { remove_h(tracking, &ntracking, c); RET(0); }
static void sh_RemoveReceiveHandler(PPC *c) { remove_h(receive, &nreceive, c); RET(0); }

// tracking messages
enum { kEnterHandler = 1, kEnterWindow = 2, kInWindow = 3, kLeaveWindow = 4, kLeaveHandler = 5 };

static void track_msg(Drag *d, Win *w, int msg)
{
	if (!w)
		return;
	Port *save = qd_port;
	for (int i = 0; i < ntracking; i++)
		if (!tracking[i].win || tracking[i].win == w->tok) {
			qd_port = w->port;
			ppc_cb4(tracking[i].proc, (uint32_t)msg, w->tok, tracking[i].refcon, d->tok);
		}
	qd_port = save;
}

static CGImageRef snapshot(Win *w, QRect g)
{
	if (!w || !w->port || !w->port->pix)
		return NULL;
	Port *p = w->port;
	QPoint o = win_origin(w);
	QRect l = rect_off(g, p->portRect.left - o.h, p->portRect.top - o.v);
	l = rect_sect(l, p->bounds);
	int wd = l.right - l.left, ht = l.bottom - l.top;
	if (wd <= 0 || ht <= 0)
		return NULL;
	CFMutableDataRef data = CFDataCreateMutable(NULL, (CFIndex)wd * ht * 4);
	CFDataSetLength(data, (CFIndex)wd * ht * 4);
	uint8_t *px = CFDataGetMutableBytePtr(data);
	for (int y = 0; y < ht; y++)
		memcpy(px + (size_t)y * wd * 4, PIXP(p, l.left, l.top + y), (size_t)wd * 4);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef dp = CGDataProviderCreateWithCFData(data);
	CGImageRef img = CGImageCreate(wd, ht, 8, 32, wd * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp, NULL, false,
		kCGRenderingIntentDefault);
	CGDataProviderRelease(dp);
	CGColorSpaceRelease(cs);
	CFRelease(data);
	return img;
}

static void sh_TrackDrag(PPC *c)
{
	// TrackDrag(drag, const EventRecord *, RgnHandle dragRgn in global coordinates)
	Drag *d = DR(A(0));
	if (!d)
		return RET(-50);
	QPoint start = A(1) ? LDPT(A(1) + 10) : ev_mouse_global();
	Rgn *g = RGN(A(2));
	QRect box = g ? g->bbox : (QRect){start.v, start.h, start.v, start.h};
	Win *src = win_at(start.h, start.v);
	// the feedback window
	NSWindow *fw = nil;
	CGImageRef img = snapshot(src, box);
	if (img) {
		NSRect fr = NSMakeRect(box.left, qd_cocoa_y(box.bottom), box.right - box.left, box.bottom - box.top);
		fw = [[NSWindow alloc] initWithContentRect:fr styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		fw.opaque = NO;
		fw.backgroundColor = NSColor.clearColor;
		fw.alphaValue = 0.6;
		fw.ignoresMouseEvents = YES;
		fw.level = NSPopUpMenuWindowLevel;
		fw.releasedWhenClosed = NO;
		NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, fr.size.width, fr.size.height)];
		NSImage *im = [[NSImage alloc] initWithCGImage:img size:fr.size];
		iv.image = im;
		iv.imageScaling = NSImageScaleAxesIndependently;
		fw.contentView = iv;
		[im release];
		[iv release];
		CGImageRelease(img);
		[fw orderFront:nil];
	}
	d->mouse = start;
	d->attrs = 2 | 4;   // inside the sender application and window
	Win *over = NULL;
	int entered = 0;
	if (ntracking) {
		entered = 1;
		for (Win *w = win_list(); w; w = w->next)
			if (w->visible)
				track_msg(d, w, kEnterHandler);
	}
	for (;;) {
		QPoint m = ev_mouse_global();
		d->mouse = m;
		if (fw)
			[fw setFrameOrigin:NSMakePoint(box.left + m.h - start.h, qd_cocoa_y(box.bottom + m.v - start.v))];
		Win *w = win_at(m.h, m.v);
		if (w != over) {
			if (over)
				track_msg(d, over, kLeaveWindow);
			over = w;
			if (w != src)
				d->attrs = (d->attrs & ~4) | 1;
			else
				d->attrs |= 4;
			if (over)
				track_msg(d, over, kEnterWindow);
		}
		if (over)
			track_msg(d, over, kInWindow);
		win_flush_all();
		if (!ev_button_down())
			break;
		ev_pump(0.015);
	}
	if (over)
		track_msg(d, over, kLeaveWindow);
	if (entered)
		for (Win *w = win_list(); w; w = w->next)
			if (w->visible)
				track_msg(d, w, kLeaveHandler);
	hide_hilite(d);
	if (fw) {
		[fw orderOut:nil];
		[fw release];
	}
	int r = -128;   // userCanceledErr: dropped nowhere
	if (over) {
		Port *save = qd_port;
		for (int i = 0; i < nreceive; i++)
			if (!receive[i].win || receive[i].win == over->tok) {
				qd_port = over->port;
				r = (int16_t)ppc_cb3(receive[i].proc, over->tok, receive[i].refcon, d->tok);
				break;
			}
		qd_port = save;
		if (r != 0 && r != -128)
			r = -1857;   // dragNotAcceptedErr
	}
	ev_drop_mouseups();
	win_flush_all();
	RET(r);
}

static const ShimDef dragshims[] = {
	S(NewDrag), S(DisposeDrag), S(AddDragItemFlavor), S(SetDragItemBounds), S(GetDragItemBounds), S(SetDragImage),
	S(CountDragItems), S(GetDragItemReferenceNumber), S(GetFlavorFlags), S(GetFlavorDataSize), S(GetFlavorData),
	S(GetDragAttributes), S(GetDragMouse), S(ShowDragHilite), S(HideDragHilite), S(InstallTrackingHandler),
	S(InstallReceiveHandler), S(RemoveTrackingHandler), S(RemoveReceiveHandler), S(TrackDrag),
};
REGISTER(dragshims)
