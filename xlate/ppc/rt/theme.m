// Appearance Manager: theme brushes, text colors, fonts and primitives.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "qd.h"

static RGB16 brush_color(int brush)
{
	switch (brush) {
	case 15: case 16:                          // document window background
	case 13: case 14:                          // list view background
	case 3: case 4:                            // alert background
	case 23: case 24:                          // utility window background
		return brush == 23 || brush == 24 ? (RGB16){0xeeee, 0xeeee, 0xeeee} : (RGB16){0xffff, 0xffff, 0xffff};
	case -1: case -2:                          // white, black
		return brush == -1 ? (RGB16){0xffff, 0xffff, 0xffff} : (RGB16){0, 0, 0};
	case 3 + 100:
		break;
	case 5: case 6:                            // modeless dialog background
	case 1: case 2:                            // dialog background
	default:
		break;
	}
	return (RGB16){0xeded, 0xeded, 0xeded};
}

static RGB16 text_color(int k, int depth)
{
	(void)depth;
	switch (k) {
	case 2: case 4: case 6: case 8: case 12: case 14: case 16: case 18: case 20: case 25: case 27:   // inactive
		return (RGB16){0x7fff, 0x7fff, 0x7fff};
	case 35: case 36:                          // white (selected) text
		return (RGB16){0xffff, 0xffff, 0xffff};
	default:
		return (RGB16){0, 0, 0};
	}
}

static void sh_SetThemeBackground(PPC *c)
{
	// SetThemeBackground(brush, depth, isColorDevice)
	if (qd_port)
		qd_port->bg = brush_color((int16_t)A(0));
	RET(0);
}
static void sh_ApplyThemeBackground(PPC *c)
{
	// ApplyThemeBackground(kind, bounds, state, depth, isColor)
	if (qd_port)
		qd_port->bg = (RGB16){0xeded, 0xeded, 0xeded};
	RET(0);
}
static void sh_SetThemePen(PPC *c) { if (qd_port) qd_port->fg = brush_color((int16_t)A(0)); RET(0); }
static void sh_SetThemeTextColor(PPC *c) { if (qd_port) qd_port->fg = text_color((int16_t)A(0), A(1)); RET(0); }
static void sh_GetThemeTextColor(PPC *c)
{
	// GetThemeTextColor(color, depth, isColor, RGBColor *)
	RGB16 col = text_color((int16_t)A(0), A(1));
	ST16(A(3), col.r);
	ST16(A(3) + 2, col.g);
	ST16(A(3) + 4, col.b);
	RET(0);
}
static void sh_GetThemeBrushAsColor(PPC *c)
{
	RGB16 col = brush_color((int16_t)A(0));
	ST16(A(3), col.r);
	ST16(A(3) + 2, col.g);
	ST16(A(3) + 4, col.b);
	RET(0);
}
static void sh_GetThemeAccentColors(PPC *c) { if (A(0)) ST32(A(0), 0); RET(-1); }
static void sh_IsThemeInColor(PPC *c) { (void)c; RET(1); }

static void sh_GetThemeFont(PPC *c)
{
	// GetThemeFont(fontID, script, Str255 name, SInt16 *size, Style *style)
	int id = (int16_t)A(0);
	int size = 13, style = 0;
	switch (id) {
	case 1: case 2: case 4: case 7: size = 11; style = id == 2 ? 1 : 0; break;   // small system (emphasized), small emphasized
	case 3: size = 12; break;                                                   // views
	case 5: case 6: case 100: case 101: size = 10; break;                       // mini, label
	default: break;
	}
	if (id == 4)
		style = 1;
	if (A(2)) {
		static const char nm[] = "Lucida Grande";
		ST8(A(2), (uint8_t)(sizeof nm - 1));
		memcpy(G(A(2) + 1), nm, sizeof nm - 1);
	}
	if (A(3))
		ST16(A(3), size);
	if (A(4))
		ST8(A(4), style);
	RET(0);
}

static CGRect cgr(QRect r) { return CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top); }

static void sh_DrawThemeFocusRect(PPC *c)
{
	// DrawThemeFocusRect(rect, hasFocus)
	Port *p = qd_port;
	if (!p || !(A(1) & 0xff))
		return RET(0);
	QRect r = RECT(A(0));
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFocusRect(&cr, true, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 4), (int16_t)(r.left - 4), (int16_t)(r.bottom + 4), (int16_t)(r.right + 4)});
	RET(0);
}
static void sh_DrawThemeFocusRegion(PPC *c)
{
	Rgn *g = RGN(A(0));
	Port *p = qd_port;
	if (!p || !g || !(A(1) & 0xff))
		return RET(0);
	QRect r = g->bbox;
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFocusRect(&cr, true, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 4), (int16_t)(r.left - 4), (int16_t)(r.bottom + 4), (int16_t)(r.right + 4)});
	RET(0);
}
static void sh_DrawThemeEditTextFrame(PPC *c)
{
	// DrawThemeEditTextFrame(rect, state): the frame is outside the rectangle
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeFrameDrawInfo fi = {0, kHIThemeFrameTextFieldSquare, (A(1) == 0) ? kThemeStateInactive : kThemeStateActive, false};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawFrame(&cr, &fi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, (QRect){(int16_t)(r.top - 2), (int16_t)(r.left - 2), (int16_t)(r.bottom + 2), (int16_t)(r.right + 2)});
	RET(0);
}
static void sh_DrawThemeTabPane(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeTabPaneDrawInfo ti = {1, A(1) ? kThemeStateActive : kThemeStateInactive, kThemeTabNorth, kHIThemeTabSizeNormal, kHIThemeTabKindNormal, kHIThemeTabAdornmentNone};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawTabPane(&cr, &ti, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemeSeparator(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeSeparatorDrawInfo si = {0, A(1) ? kThemeStateActive : kThemeStateInactive};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawSeparator(&cr, &si, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemePrimaryGroup(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeGroupBoxDrawInfo gi = {0, A(1) ? kThemeStateActive : kThemeStateInactive, kHIThemeGroupBoxKindPrimary};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawGroupBox(&cr, &gi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}
static void sh_DrawThemeWindowHeader(PPC *c)
{
	Port *p = qd_port;
	if (!p)
		return RET(0);
	QRect r = RECT(A(0));
	HIThemeHeaderDrawInfo hi = {0, A(1) ? kThemeStateActive : kThemeStateInactive, kHIThemeHeaderKindWindow};
	CGContextRef cg = qd_cg_begin(p);
	CGRect cr = cgr(r);
	HIThemeDrawHeader(&cr, &hi, cg, kHIThemeOrientationInverted);
	qd_cg_end(p);
	qd_dirty(p, r);
	RET(0);
}

// drawing state: a saved copy of the port's pen, colors and text
typedef struct {
	RGB16 fg, bg;
	uint8_t pnPat[8], bkPat[8];
	QPoint pnSize;
	int pnMode, txFont, txFace, txSize, txMode;
} DState;

static void sh_GetThemeDrawingState(PPC *c)
{
	Port *p = qd_port;
	DState *s = calloc(1, sizeof *s);
	if (p) {
		s->fg = p->fg;
		s->bg = p->bg;
		memcpy(s->pnPat, p->pnPat, 8);
		memcpy(s->bkPat, p->bkPat, 8);
		s->pnSize = p->pnSize;
		s->pnMode = p->pnMode;
		s->txFont = p->txFont;
		s->txFace = p->txFace;
		s->txSize = p->txSize;
		s->txMode = p->txMode;
	}
	ST32(A(0), tok_new(s, 16, 'XLds'));
	RET(0);
}
static void sh_SetThemeDrawingState(PPC *c)
{
	DState *s = tok_get(A(0), 'XLds');
	Port *p = qd_port;
	if (s && p) {
		p->fg = s->fg;
		p->bg = s->bg;
		memcpy(p->pnPat, s->pnPat, 8);
		memcpy(p->bkPat, s->bkPat, 8);
		p->pnSize = s->pnSize;
		p->pnMode = s->pnMode;
		p->txFont = s->txFont;
		p->txFace = s->txFace;
		p->txSize = s->txSize;
		p->txMode = s->txMode;
	}
	if (s && (A(1) & 0xff)) {
		tok_free(A(0));
		free(s);
	}
	RET(0);
}
static void sh_DisposeThemeDrawingState(PPC *c)
{
	DState *s = tok_get(A(0), 'XLds');
	if (s) {
		tok_free(A(0));
		free(s);
	}
	RET(0);
}
static void sh_NormalizeThemeDrawingState(PPC *c)
{
	(void)c;
	Port *p = qd_port;
	if (p) {
		p->fg = (RGB16){0, 0, 0};
		p->bg = (RGB16){0xffff, 0xffff, 0xffff};
		memset(p->pnPat, 0xff, 8);
		memset(p->bkPat, 0, 8);
		p->pnSize = (QPoint){1, 1};
		p->pnMode = 8;
		p->txFont = 0;
		p->txFace = 0;
		p->txSize = 0;
		p->txMode = 1;
	}
	RET(0);
}

static void sh_RegisterAppearanceClient(PPC *c) { (void)c; RET(0); }
static void sh_UnregisterAppearanceClient(PPC *c) { (void)c; RET(0); }

static const ShimDef themeshims[] = {
	S(RegisterAppearanceClient), S(UnregisterAppearanceClient),
	S(SetThemeBackground), S(ApplyThemeBackground), S(SetThemePen), S(SetThemeTextColor), S(GetThemeTextColor),
	S(GetThemeBrushAsColor), S(GetThemeAccentColors), S(IsThemeInColor), S(GetThemeFont), S(DrawThemeFocusRect),
	S(DrawThemeFocusRegion), S(DrawThemeEditTextFrame), S(DrawThemeTabPane), S(DrawThemeSeparator),
	S(DrawThemePrimaryGroup), S(DrawThemeWindowHeader), S(GetThemeDrawingState), S(SetThemeDrawingState),
	S(DisposeThemeDrawingState), S(NormalizeThemeDrawingState),
};
REGISTER(themeshims)
