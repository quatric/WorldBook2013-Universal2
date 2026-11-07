// Control Manager (see ctl.h).
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include "ctl.h"
#include "hmap.h"
#include "te.h"
#include "icons.h"
#include "menu.h"
#include "pict.h"

static HMap ctls;   // ControlHandle -> Ctl

uint32_t res_get(uint32_t type, int16_t id, int one);
void ev_drop_mouseups(void);

Ctl *CTL(uint32_t h) { return hm_get(&ctls, h); }

// the ControlRecord the guest may read
static void ctl_sync(Ctl *c)
{
	uint32_t p = HP(c->h);
	if (!p)
		return;
	ST32(p, c->next ? c->next->h : 0);
	ST32(p + 4, c->win ? c->win->tok : 0);
	PUTRECT(p + 8, c->r);
	ST8(p + 16, c->visible ? 255 : 0);
	ST8(p + 17, c->hilite);
	ST16(p + 18, c->value);
	ST16(p + 20, c->min);
	ST16(p + 22, c->max);
	ST32(p + 24, c->procID);
	ST32(p + 32, c->action);
	ST32(p + 36, c->refCon);
	memcpy(G(p + 40), c->title, c->title[0] + 1);
}

static int kind_of(int proc, int *variant)
{
	*variant = proc & 15;
	switch (proc) {
	case 0: return K_PUSH;
	case 1: return K_CHECK;
	case 2: return K_RADIO;
	case 16: return K_SCROLL;
	case 1008: return K_POPUP;
	}
	switch (proc >> 4) {
	case 2: return K_BEVEL;                 // 32..
	case 3: return K_SLIDER;                // 48..
	case 4: return K_TRIANGLE;              // 64..
	case 5: return K_PROGRESS;              // 80..
	case 6: return K_ARROWS;                // 96..
	case 7: return K_CHASING;               // 112..
	case 8: return K_TABS;                  // 128..
	case 9: return K_SEPARATOR;             // 144..
	case 10: return K_GROUP;                // 160..
	case 11: return K_IMAGEWELL;            // 176..
	case 12: return K_POPUPARROW;           // 192..
	case 14: return K_PLACARD;              // 224..
	case 15: return K_CLOCK;                // 240..
	case 16: return K_USERPANE;             // 256..
	case 17: return K_EDITTEXT;             // 272..
	case 18: return K_STATICTEXT;           // 288..
	case 19: return K_PICTURE;              // 304..
	case 20: return K_ICON;                 // 320..
	case 21: return K_HEADER;               // 336..
	case 22: return K_LISTBOX;              // 352..
	case 23:                                // 368..
		return *variant == 0 || *variant == 4 ? K_PUSH : (*variant == 1 || *variant == 3) ? K_CHECK : K_RADIO;
	case 24: return K_SCROLL;               // 384..
	case 25: return K_POPUP;                // 400..
	case 26: return K_RADIOGROUP;           // 416..
	case 30: return K_DISCLOSURE;           // 480..
	case 31: return K_ROUND;                // 496..
	case 83: return K_NULL;                 // the application's CDEF 83: an empty container
	}
	if (proc >= 0x3f0 && proc <= 0x3ff)
		return K_POPUP;
	return K_NULL;
}

static Ctl *ctl_root(Win *w) { return w && w->root ? CTL(w->root) : NULL; }

static void add_child(Ctl *parent, Ctl *c)
{
	c->parent = parent;
	c->next = NULL;
	Ctl **p = &parent->child;
	while (*p)
		p = &(*p)->next;
	*p = c;
}

static void remove_child(Ctl *c)
{
	if (!c->parent)
		return;
	for (Ctl **p = &c->parent->child; *p; p = &(*p)->next)
		if (*p == c) {
			*p = c->next;
			break;
		}
	c->parent = NULL;
	c->next = NULL;
}

static Ctl *ctl_new(Win *w, QRect r, const uint8_t *title, int visible, int value, int min, int max, int proc, uint32_t refCon)
{
	Ctl *c = calloc(1, sizeof *c);
	c->h = NewHandleClearG(296);
	c->win = w;
	c->r = r;
	c->procID = proc;
	c->kind = kind_of(proc, &c->variant);
	c->visible = visible;
	c->value = (int16_t)value;
	c->min = (int16_t)min;
	c->max = (int16_t)max;
	c->refCon = refCon;
	c->active = 1;
	c->enabled = 1;
	if (title)
		memcpy(c->title, title, title[0] + 1);
	hm_put(&ctls, c->h, c);
	// creation-time conventions of the classic definitions
	switch (c->kind) {
	case K_POPUP:
		c->menuID = (int16_t)min;
		c->title_width = max;
		c->title_style = value;
		c->menu = menu_get_handle(c->menuID);
		if (!c->menu)
			c->menu = menu_load(c->menuID);
		c->min = 1;
		c->max = c->menu ? (int16_t)menu_count(c->menu) : 0;
		c->value = 1;
		break;
	case K_BEVEL:
		// value: the menu ID; min: behavior (high byte) and content type; max: the content's resource ID
		c->behavior = min & 0xff00;
		c->content = min & 0xff;
		c->content_id = max;
		c->menuID = (int16_t)value;
		if (c->menuID) {
			c->menu = menu_get_handle(c->menuID);
			if (!c->menu)
				c->menu = menu_load(c->menuID);
		}
		c->value = 0;
		c->min = 0;
		c->max = 1;
		break;
	case K_TABS: {
		// min: a 'tab#' resource
		uint32_t th = min ? res_get('tab#', (int16_t)min, 0) : 0;
		if (th) {
			uint32_t p = HP(th);
			int n = LD16(p + 2);
			c->tab_count = n;
			c->tab_titles = calloc(n ? n : 1, 256);
			p += 4;
			for (int i = 0; i < n; i++) {
				p += 2;   // icon suite id
				memcpy(c->tab_titles[i], G(p), LD8(p) + 1);
				p += 1 + LD8(p);
				p += 4;   // reserved
			}
			c->max = (int16_t)n;
		} else {
			c->tab_count = max;
			c->tab_titles = calloc(max > 0 ? max : 1, 256);
		}
		c->min = 1;
		c->value = value ? (int16_t)value : 1;
		break;
	}
	case K_EDITTEXT: {
		QRect tr = r;
		tr.left += 3;
		tr.right -= 3;
		tr.top += 3;
		tr.bottom -= 3;
		c->te = te_create(w->port, tr, tr, 0);
		c->te->wrap = 0;
		c->te->password = (c->variant & 2) != 0;
		c->te->font = 0;
		c->te->size = 12;
		te_layout(c->te);
		break;
	}
	case K_ICON:
	case K_PICTURE:
		c->content_id = value;
		break;
	}
	Ctl *root = ctl_root(w);
	if (root && root != c)
		add_child(root, c);
	ctl_sync(c);
	return c;
}

static void dispose_ctl(Ctl *c)
{
	while (c->child)
		dispose_ctl(c->child);
	remove_child(c);
	if (c->win && c->win->root == c->h)
		c->win->root = 0;
	if (c->te)
		te_dispose(c->te);
	free(c->tab_titles);
	hm_del(&ctls, c->h);
	DisposeHandleG(c->h);
	free(c);
}

void ctl_dispose_all(Win *w)
{
	Ctl *root = ctl_root(w);
	if (root)
		dispose_ctl(root);
	// controls not in the hierarchy
	for (uint32_t i = 0; i < ctls.cap; i++)
		if (ctls.k[i] && ctls.k[i] != 0xffffffffu && ((Ctl *)ctls.v[i])->win == w) {
			dispose_ctl(ctls.v[i]);
			i = (uint32_t)-1;   // the map changed: rescan
		}
}

static int eff_visible(Ctl *c)
{
	for (; c; c = c->parent)
		if (!c->visible)
			return 0;
	return 1;
}

static int eff_active(Ctl *c)
{
	for (; c; c = c->parent)
		if (!c->active || c->hilite == 255)
			return 0;
	return 1;
}

// ---- drawing --------------------------------------------------------------------------------------

static CGRect cgr(QRect r) { return CGRectMake(r.left, r.top, r.right - r.left, r.bottom - r.top); }

static CTFontRef ctl_font(Ctl *c, int *small)
{
	int font = 0, size = 13, face = 0;
	if (small && *small)
		size = 11;
	if (c->fs_flags & 0x80) {   // a theme font ID
		switch (c->fs_font) {
		case 1: case 2: size = 11; break;     // small system, small emphasized
		case 4: face = 1; break;              // emphasized system
		case 3: size = 12; break;             // views
		case 6: size = 10; break;             // label
		case 109: size = 9; break;            // mini
		}
		if (c->fs_font == 2)
			face = 1;
	} else {
		if (c->fs_flags & 1)
			font = c->fs_font;
		if (c->fs_flags & 4)
			size = c->fs_size;
		if (c->fs_flags & 0x100)
			size += c->fs_size;
		if (c->fs_flags & 2)
			face = c->fs_style;
		if (!(c->fs_flags & 4) && (c->fs_flags & 1) && font != 0)
			size = 12;
	}
	if (size <= 0)
		size = 12;
	if (font == 0 && !(c->fs_flags & 1))
		return qd_font(2001, size, face);   // Lucida Grande: the Aqua system font
	return qd_font(font, size, face);
}

static void draw_label(CGContextRef cg, Ctl *c, const uint8_t *s, int n, QRect r, int just, int dim)
{
	if (n <= 0)
		return;
	CFStringRef str = CFStringCreateWithBytes(NULL, s, n, kCFStringEncodingMacRoman, false);
	if (!str)
		return;
	CTFontRef f = ctl_font(c, NULL);
	CGFloat col[4] = {0, 0, 0, 1};
	if (c->fs_flags & 8) {
		col[0] = c->fs_fore.r / 65535.0;
		col[1] = c->fs_fore.g / 65535.0;
		col[2] = c->fs_fore.b / 65535.0;
	}
	if (dim)
		col[3] = 0.45;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGColorRef color = CGColorCreate(cs, col);
	CGColorSpaceRelease(cs);
	NSDictionary *at = @{(id)kCTFontAttributeName: (id)f, (id)kCTForegroundColorAttributeName: (id)color};
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, (CFDictionaryRef)at);
	CTLineRef line = CTLineCreateWithAttributedString(as);
	CGFloat asc, desc, lead;
	double w = CTLineGetTypographicBounds(line, &asc, &desc, &lead);
	double x = r.left;
	if (just == 1)
		x = r.left + (r.right - r.left - w) / 2;
	else if (just == -1)
		x = r.right - w;
	double y = r.top + (r.bottom - r.top - (asc + desc)) / 2 + asc;
	CGContextSaveGState(cg);
	CGContextClipToRect(cg, cgr(r));
	CGContextSetTextPosition(cg, x, floor(y + 0.5));
	CTLineDraw(line, cg);
	CGContextRestoreGState(cg);
	CFRelease(line);
	CFRelease(as);
	CFRelease(str);
	CGColorRelease(color);
}

// wrapped text (static text controls)
static void draw_text_box(CGContextRef cg, Ctl *c, const uint8_t *s, int n, QRect r, int just)
{
	CFStringRef str = CFStringCreateWithBytes(NULL, s, n, kCFStringEncodingMacRoman, false);
	if (!str)
		return;
	CTFontRef f = ctl_font(c, NULL);
	CGFloat col[4] = {0, 0, 0, 1};
	if (c->fs_flags & 8) {
		col[0] = c->fs_fore.r / 65535.0;
		col[1] = c->fs_fore.g / 65535.0;
		col[2] = c->fs_fore.b / 65535.0;
	}
	if (!eff_active(c))
		col[3] = 0.45;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGColorRef color = CGColorCreate(cs, col);
	CGColorSpaceRelease(cs);
	CTTextAlignment al = just == 1 ? kCTTextAlignmentCenter : just == -1 ? kCTTextAlignmentRight : kCTTextAlignmentLeft;
	CTParagraphStyleSetting set = {kCTParagraphStyleSpecifierAlignment, sizeof al, &al};
	CTParagraphStyleRef ps = CTParagraphStyleCreate(&set, 1);
	NSDictionary *at = @{(id)kCTFontAttributeName: (id)f, (id)kCTForegroundColorAttributeName: (id)color,
		(id)kCTParagraphStyleAttributeName: (id)ps};
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, (CFDictionaryRef)at);
	CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(as);
	CGContextSaveGState(cg);
	// frames lay out in unflipped coordinates
	CGContextTranslateCTM(cg, 0, r.bottom + r.top);
	CGContextScaleCTM(cg, 1, -1);
	CGContextSetTextMatrix(cg, CGAffineTransformIdentity);
	CGMutablePathRef path = CGPathCreateMutable();
	CGPathAddRect(path, NULL, cgr(r));
	CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
	CTFrameDraw(frame, cg);
	CGContextRestoreGState(cg);
	CFRelease(frame);
	CGPathRelease(path);
	CFRelease(fs);
	CFRelease(as);
	CFRelease(ps);
	CFRelease(str);
	CGColorRelease(color);
}

static ThemeDrawState tstate(Ctl *c)
{
	if (!eff_active(c))
		return kThemeStateInactive;
	if (c->pushed)
		return kThemeStatePressed;
	return kThemeStateActive;
}

static HIThemeTrackDrawInfo track_info(Ctl *c)
{
	HIThemeTrackDrawInfo t;
	memset(&t, 0, sizeof t);
	t.version = 0;
	t.bounds = cgr(c->r);
	t.min = c->min;
	t.max = c->max;
	t.value = c->value;
	int horiz = (c->r.right - c->r.left) > (c->r.bottom - c->r.top);
	t.attributes = kThemeTrackShowThumb | (horiz ? kThemeTrackHorizontal : 0);
	t.enableState = eff_active(c) ? kThemeTrackActive : kThemeTrackInactive;
	if (c->kind == K_SCROLL) {
		t.kind = (c->r.right - c->r.left < 15 && !horiz) || (c->r.bottom - c->r.top < 15 && horiz) ? kThemeSmallScrollBar : kThemeMediumScrollBar;
		t.trackInfo.scrollbar.viewsize = c->viewSize ? c->viewSize : (c->max - c->min) / 10 + 1;
		t.trackInfo.scrollbar.pressState = 0;
	} else if (c->kind == K_SLIDER) {
		t.kind = kThemeMediumSlider;
		t.trackInfo.slider.thumbDir = kThemeThumbPlain;
	} else {
		t.kind = c->indeterminate ? kThemeMediumIndeterminateBar : kThemeMediumProgressBar;
		t.trackInfo.progress.phase = (UInt8)(ev_ticks() / 4);
	}
	return t;
}

static void icon_content(Ctl *c, CGContextRef cg, Port *p, QRect r)
{
	(void)cg;
	switch (c->content) {
	case 1: icon_plot_id(p, r, 0, 0, (int16_t)c->content_id); break;
	case 2: { uint32_t h = cicn_get((int16_t)c->content_id); if (h) icon_plot_cicn(p, r, h); break; }
	case 3: {
		uint32_t h = res_get('PICT', (int16_t)c->content_id, 0);
		if (h) {
			QRect f = RECT(HP(h) + 2);
			int w = f.right - f.left, ht = f.bottom - f.top;
			QRect d = {(int16_t)(r.top + (r.bottom - r.top - ht) / 2), (int16_t)(r.left + (r.right - r.left - w) / 2), 0, 0};
			d.bottom = (int16_t)(d.top + ht);
			d.right = (int16_t)(d.left + w);
			pict_draw(p, G(HP(h)), HSize(h), d);
		}
		break;
	}
	case 129: if (c->content_h) icon_plot_suite(p, r, 0, 0, c->content_h); break;
	case 130: if (c->content_h) icon_plot_cicn(p, r, c->content_h); break;
	case 131:
		if (c->content_h && is_handle(c->content_h)) {
			QRect f = RECT(HP(c->content_h) + 2);
			int w = f.right - f.left, ht = f.bottom - f.top;
			QRect d = {(int16_t)(r.top + (r.bottom - r.top - ht) / 2), (int16_t)(r.left + (r.right - r.left - w) / 2), 0, 0};
			d.bottom = (int16_t)(d.top + ht);
			d.right = (int16_t)(d.left + w);
			pict_draw(p, G(HP(c->content_h)), HSize(c->content_h), d);
		}
		break;
	case 132: if (c->content_h) icon_plot_ref(p, r, c->content_h); break;
	}
}

static QRect tab_rect(Ctl *c, int i, CGContextRef cg);

static void draw_one(Ctl *c)
{
	Win *w = c->win;
	if (!w)
		return;
	Port *p = w->port;
	if (c->kind == K_USERPANE || c->kind == K_CUSTOM) {
		uint32_t proc = c->kind == K_USERPANE ? c->procs[0] : c->defproc;
		if (proc) {
			Port *save = qd_port;
			qd_port = p;
			if (c->kind == K_USERPANE)
				ppc_cb2(proc, c->h, 0);
			else
				ppc_cb4(proc, c->variant, c->h, 0, 0);   // drawCntl
			qd_port = save;
		}
		return;
	}
	if (c->kind == K_NULL || c->kind == K_RADIOGROUP)
		return;
	if (c->kind == K_EDITTEXT) {
		CGContextRef cg = qd_cg_begin(p);
		HIThemeFrameDrawInfo fi = {0, kHIThemeFrameTextFieldSquare, eff_active(c) ? kThemeStateActive : kThemeStateInactive, c->focus != 0};
		QRect fr = c->r;
		CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
		CGContextFillRect(cg, cgr(fr));
		{ CGRect ir_ = CGRectInset(cgr(fr), 1, 1); HIThemeDrawFrame(&ir_, &fi, cg, kHIThemeOrientationNormal); }
		if (c->focus)
			{ CGRect fr_ = CGRectInset(cgr(fr), 1, 1); HIThemeDrawFocusRect(&fr_, true, cg, kHIThemeOrientationNormal); }
		qd_cg_end(p);
		te_draw(c->te, NULL);
		qd_dirty(p, rect_off(c->r, 0, 0));
		return;
	}
	if (c->kind == K_PICTURE) {
		uint32_t h = c->content_h ? c->content_h : res_get('PICT', (int16_t)c->content_id, 0);
		if (h && is_handle(h) && HP(h))
			pict_draw(p, G(HP(h)), HSize(h), c->r);
		return;
	}
	if (c->kind == K_ICON) {
		if (c->content_h)
			icon_content(c, NULL, p, c->r);
		else
			icon_plot_id(p, c->r, 0, 0, (int16_t)c->content_id);
		return;
	}
	CGContextRef cg = qd_cg_begin(p);
	CGRect r = cgr(c->r);
	ThemeDrawState st = tstate(c);
	int dim = !eff_active(c);
	switch (c->kind) {
	case K_PUSH: case K_ROUND: case K_DISCLOSURE: case K_TRIANGLE: case K_ARROWS: {
		HIThemeButtonDrawInfo bi = {0, st, kThemePushButton, kThemeButtonOff, kThemeAdornmentNone, {0}};
		if (c->kind == K_ROUND)
			bi.kind = kThemeRoundButton;
		else if (c->kind == K_DISCLOSURE) {
			bi.kind = kThemeDisclosureButton;
			bi.value = c->value ? kThemeDisclosureDown : kThemeDisclosureRight;
		} else if (c->kind == K_TRIANGLE) {
			bi.kind = kThemeDisclosureTriangle;
			bi.value = c->value ? kThemeDisclosureDown : kThemeDisclosureRight;
		} else if (c->kind == K_ARROWS)
			bi.kind = kThemeIncDecButton;
		if (c->is_default && eff_active(c))
			bi.adornment = kThemeAdornmentDefault;
		CGRect br = r;
		if (bi.kind == kThemePushButton) {
			// the theme push button is 20 pixels tall plus its shadow
			br = CGRectInset(r, 1, 0);
			if (br.size.height > 22)
				br = CGRectMake(br.origin.x, br.origin.y + (br.size.height - 22) / 2, br.size.width, 22);
		}
		HIThemeDrawButton(&br, &bi, cg, kHIThemeOrientationNormal, NULL);
		if (c->kind == K_PUSH || c->kind == K_ROUND) {
			QRect lr = c->r;
			lr.bottom -= 2;
			draw_label(cg, c, c->title + 1, c->title[0], lr, 1, dim);
		} else if (c->kind == K_TRIANGLE && c->title[0]) {
			QRect lr = c->r;
			lr.left += 16;
			draw_label(cg, c, c->title + 1, c->title[0], lr, 0, dim);
		}
		break;
	}
	case K_CHECK: case K_RADIO: {
		int small = (c->r.bottom - c->r.top) < 16;
		HIThemeButtonDrawInfo bi = {0, st, c->kind == K_CHECK ? (small ? kThemeSmallCheckBox : kThemeCheckBox) : (small ? kThemeSmallRadioButton : kThemeRadioButton),
			c->value == 2 ? kThemeButtonMixed : c->value ? kThemeButtonOn : kThemeButtonOff, kThemeAdornmentNone, {0}};
		CGRect box = CGRectMake(r.origin.x, r.origin.y + (r.size.height - (small ? 14 : 18)) / 2, small ? 14 : 18, small ? 14 : 18);
		HIThemeDrawButton(&box, &bi, cg, kHIThemeOrientationNormal, NULL);
		QRect lr = c->r;
		lr.left += small ? 16 : 20;
		draw_label(cg, c, c->title + 1, c->title[0], lr, 0, dim);
		break;
	}
	case K_BEVEL: {
		HIThemeButtonDrawInfo bi = {0, st, kThemeBevelButton, (c->behavior && c->value) ? kThemeButtonOn : kThemeButtonOff, kThemeAdornmentNone, {0}};
		if (c->variant == 0)
			bi.kind = kThemeSmallBevelButton;
		else if (c->variant == 2)
			bi.kind = kThemeLargeBevelButton;
		CGContextSetRGBFillColor(cg, 0.93, 0.93, 0.93, 1);
		HIThemeDrawButton(&r, &bi, cg, kHIThemeOrientationNormal, NULL);
		qd_cg_end(p);
		if (c->content)
			icon_content(c, NULL, p, c->r);
		cg = qd_cg_begin(p);
		if (c->title[0])
			draw_label(cg, c, c->title + 1, c->title[0], c->r, c->content ? 0 : 1, dim);
		if (c->menu) {
			CGRect ar = CGRectMake(r.origin.x + r.size.width - 12, r.origin.y + r.size.height / 2 - 3, 7, 5);
			HIThemePopupArrowDrawInfo pi = {0, st, kThemeArrowDown, kThemeArrow7pt};
			HIThemeDrawPopupArrow(&ar, &pi, cg, kHIThemeOrientationNormal);
		}
		break;
	}
	case K_POPUP: {
		QRect pr = c->r;
		if (c->title[0] && c->title_width > 0) {
			QRect tr = pr;
			tr.right = (int16_t)(tr.left + c->title_width);
			draw_label(cg, c, c->title + 1, c->title[0], tr, c->title_just == 1 ? 1 : c->title_just == -1 ? -1 : 0, dim);
			pr.left = (int16_t)(tr.right + 2);
		} else if (c->title[0] && c->title_width == -1) {
			double tw = 0;
			CTFontRef f = ctl_font(c, NULL);
			CFStringRef s = CFStringCreateWithBytes(NULL, c->title + 1, c->title[0], kCFStringEncodingMacRoman, false);
			NSAttributedString *a = [[NSAttributedString alloc] initWithString:(NSString *)s attributes:@{NSFontAttributeName: (id)f}];
			tw = a.size.width;
			[a release];
			CFRelease(s);
			QRect tr = pr;
			tr.right = (int16_t)(tr.left + tw + 4);
			draw_label(cg, c, c->title + 1, c->title[0], tr, 0, dim);
			pr.left = tr.right;
		}
		HIThemeButtonDrawInfo bi = {0, st, kThemePopupButton, kThemeButtonOff, kThemeAdornmentNone, {0}};
		CGRect br = cgr(pr);
		if (br.size.height > 22)
			br = CGRectMake(br.origin.x, br.origin.y + (br.size.height - 22) / 2, br.size.width, 22);
		CGRect lab;
		HIThemeDrawButton(&br, &bi, cg, kHIThemeOrientationNormal, &lab);
		uint8_t item[256] = {0};
		if (c->menu)
			menu_item_text(c->menu, c->value, item);
		QRect lr = {(int16_t)br.origin.y, (int16_t)(br.origin.x + 9), (int16_t)(br.origin.y + br.size.height - 2), (int16_t)(br.origin.x + br.size.width - 22)};
		draw_label(cg, c, item + 1, item[0], lr, 0, dim);
		break;
	}
	case K_SCROLL: case K_SLIDER: case K_PROGRESS: {
		HIThemeTrackDrawInfo t = track_info(c);
		if (c->kind != K_PROGRESS && c->max <= c->min)
			t.attributes &= ~kThemeTrackShowThumb;
		HIThemeDrawTrack(&t, NULL, cg, kHIThemeOrientationNormal);
		break;
	}
	case K_CHASING: {
		HIThemeChasingArrowsDrawInfo ci = {0, st, (UInt32)(ev_ticks() / 6)};
		HIThemeDrawChasingArrows(&r, &ci, cg, kHIThemeOrientationNormal);
		break;
	}
	case K_TABS: {
		CGRect pane = r;
		pane.origin.y += 10;
		pane.size.height -= 10;
		HIThemeTabPaneDrawInfo pi;
		memset(&pi, 0, sizeof pi);
		pi.version = 1;
		pi.state = eff_active(c) ? kThemeStateActive : kThemeStateInactive;
		pi.direction = kThemeTabNorth;
		pi.size = kHIThemeTabSizeNormal;
		pi.kind = kHIThemeTabKindNormal;
		HIThemeDrawTabPane(&pane, &pi, cg, kHIThemeOrientationNormal);
		for (int i = 0; i < c->tab_count; i++) {
			QRect tr = tab_rect(c, i, cg);
			HIThemeTabDrawInfo ti;
			memset(&ti, 0, sizeof ti);
			ti.version = 1;
			ti.style = i + 1 == c->value ? (eff_active(c) ? kThemeTabFront : kThemeTabFrontInactive) : (eff_active(c) ? kThemeTabNonFront : kThemeTabNonFrontInactive);
			ti.direction = kThemeTabNorth;
			ti.size = kHIThemeTabSizeNormal;
			ti.kind = kHIThemeTabKindNormal;
			ti.position = c->tab_count == 1 ? kHIThemeTabPositionOnly : i == 0 ? kHIThemeTabPositionFirst : i == c->tab_count - 1 ? kHIThemeTabPositionLast : kHIThemeTabPositionMiddle;
			CGRect trr = cgr(tr), lab;
			HIThemeDrawTab(&trr, &ti, cg, kHIThemeOrientationNormal, &lab);
			draw_label(cg, c, c->tab_titles[i] + 1, c->tab_titles[i][0], tr, 1, dim);
		}
		break;
	}
	case K_SEPARATOR: {
		HIThemeSeparatorDrawInfo si = {0, st};
		HIThemeDrawSeparator(&r, &si, cg, kHIThemeOrientationNormal);
		break;
	}
	case K_GROUP: {
		HIThemeGroupBoxDrawInfo gi = {0, st, (c->variant & 4) ? kHIThemeGroupBoxKindSecondary : kHIThemeGroupBoxKindPrimary};
		CGRect gr = r;
		int titled = c->title[0] != 0;
		if (titled) {
			gr.origin.y += 8;
			gr.size.height -= 8;
		}
		HIThemeDrawGroupBox(&gr, &gi, cg, kHIThemeOrientationNormal);
		if (titled) {
			CTFontRef f = ctl_font(c, NULL);
			CFStringRef s = CFStringCreateWithBytes(NULL, c->title + 1, c->title[0], kCFStringEncodingMacRoman, false);
			NSAttributedString *a = [[NSAttributedString alloc] initWithString:(NSString *)s attributes:@{NSFontAttributeName: (id)f}];
			double tw = a.size.width;
			[a release];
			CFRelease(s);
			QRect tr = {c->r.top, (int16_t)(c->r.left + 10), (int16_t)(c->r.top + 16), (int16_t)(c->r.left + 14 + tw)};
			CGContextSetRGBFillColor(cg, p->bg.r / 65535.0, p->bg.g / 65535.0, p->bg.b / 65535.0, 1);
			CGContextFillRect(cg, cgr(tr));
			draw_label(cg, c, c->title + 1, c->title[0], (QRect){tr.top, (int16_t)(tr.left + 2), tr.bottom, tr.right}, 0, dim);
		}
		break;
	}
	case K_IMAGEWELL: case K_PLACARD: case K_HEADER: {
		HIThemeFrameDrawInfo fi = {0, kHIThemeFrameListBox, st, false};
		if (c->kind == K_PLACARD) {
			HIThemePlacardDrawInfo pi = {0, st};
			HIThemeDrawPlacard(&r, &pi, cg, kHIThemeOrientationNormal);
		} else if (c->kind == K_HEADER) {
			HIThemeHeaderDrawInfo hi = {0, st, kHIThemeHeaderKindWindow};
			HIThemeDrawHeader(&r, &hi, cg, kHIThemeOrientationNormal);
		} else
			{ CGRect ir_ = CGRectInset(r, 1, 1); HIThemeDrawFrame(&ir_, &fi, cg, kHIThemeOrientationNormal); }
		break;
	}
	case K_STATICTEXT: {
		if (c->text && is_handle(c->text) && HP(c->text)) {
			int just = (c->fs_flags & 0x40) ? (c->fs_just == 1 ? 1 : c->fs_just == -1 ? -1 : 0) : 0;
			draw_text_box(cg, c, G(HP(c->text)), (int)HSize(c->text), c->r, just);
		}
		break;
	}
	case K_POPUPARROW: {
		HIThemePopupArrowDrawInfo pi = {0, st, (ThemeArrowOrientation)(c->variant & 3), (c->variant & 4) ? kThemeArrow5pt : kThemeArrow9pt};
		HIThemeDrawPopupArrow(&r, &pi, cg, kHIThemeOrientationNormal);
		break;
	}
	default:
		break;
	}
	qd_cg_end(p);
	QRect dr = c->r;
	dr.left -= 4;
	dr.top -= 4;
	dr.right += 4;
	dr.bottom += 4;
	qd_dirty(p, dr);
}

static void draw_tree(Ctl *c)
{
	if (!c->visible)
		return;
	draw_one(c);
	for (Ctl *k = c->child; k; k = k->next)
		draw_tree(k);
}

void ctl_draw(Ctl *c)
{
	if (!c || !c->win || !eff_visible(c))
		return;
	Port *save = qd_port;
	qd_port = c->win->port;
	draw_tree(c);
	qd_port = save;
}

void ctl_draw_window(Win *w)
{
	Ctl *root = ctl_root(w);
	if (root)
		ctl_draw(root);
}

static QRect tab_rect(Ctl *c, int i, CGContextRef cg)
{
	(void)cg;
	CTFontRef f = ctl_font(c, NULL);
	double *ws = calloc(c->tab_count + 1, sizeof(double)), total = 0;
	for (int k = 0; k < c->tab_count; k++) {
		CFStringRef s = CFStringCreateWithBytes(NULL, c->tab_titles[k] + 1, c->tab_titles[k][0], kCFStringEncodingMacRoman, false);
		NSAttributedString *a = [[NSAttributedString alloc] initWithString:(NSString *)(s ?: CFSTR("")) attributes:@{NSFontAttributeName: (id)f}];
		ws[k] = ceil(a.size.width) + 24;
		total += ws[k];
		[a release];
		if (s)
			CFRelease(s);
	}
	double x = c->r.left + ((c->r.right - c->r.left) - total) / 2;
	for (int k = 0; k < i; k++)
		x += ws[k];
	QRect r = {c->r.top, (int16_t)x, (int16_t)(c->r.top + 22), (int16_t)(x + ws[i])};
	free(ws);
	return r;
}

// ---- hit testing and tracking ----------------------------------------------------------------------------

static int test(Ctl *c, QPoint pt)
{
	if (!eff_visible(c) || !eff_active(c))
		return 0;
	QRect r = c->r;
	if (pt.h < r.left || pt.h >= r.right || pt.v < r.top || pt.v >= r.bottom)
		return 0;
	switch (c->kind) {
	case K_PUSH: case K_BEVEL: case K_ROUND: case K_DISCLOSURE: case K_ICON:
		if (c->kind == K_BEVEL && c->menu && pt.h >= r.right - 16)
			return 2;
		if (c->kind == K_BEVEL && c->menu && !c->behavior)
			return 2;
		return 10;
	case K_CHECK: case K_RADIO: return 11;
	case K_POPUP: return 2;
	case K_TRIANGLE: return 4;
	case K_EDITTEXT: return 5;
	case K_PICTURE: return (c->variant & 1) ? 0 : 1;
	case K_ARROWS: return pt.v < (r.top + r.bottom) / 2 ? 20 : 21;
	case K_TABS:
		for (int i = 0; i < c->tab_count; i++) {
			QRect tr = tab_rect(c, i, NULL);
			if (pt.h >= tr.left && pt.h < tr.right && pt.v >= tr.top && pt.v < tr.bottom)
				return i + 1;
		}
		return 0;
	case K_SCROLL: case K_SLIDER: {
		HIThemeTrackDrawInfo t = track_info(c);
		CGPoint p = CGPointMake(pt.h + 0.5, pt.v + 0.5);
		ControlPartCode part = 0;
		if (HIThemeHitTestTrack(&t, &p, &part))
			return part;
		return 0;
	}
	case K_USERPANE:
		if (c->procs[1])
			return (int16_t)ppc_cb2(c->procs[1], c->h, PTV(pt));
		return 0;
	case K_CUSTOM:
		if (c->defproc)
			return (int16_t)ppc_cb4(c->defproc, c->variant, c->h, 1, PTV(pt));
		return 0;
	default: return 0;
	}
}

static QPoint mouse_local(Win *w)
{
	QPoint g = ev_mouse_global();
	QPoint o = win_origin(w);
	return (QPoint){(int16_t)(g.v - o.v + w->port->portRect.top), (int16_t)(g.h - o.h + w->port->portRect.left)};
}

static void redraw(Ctl *c)
{
	ctl_draw(c);
	win_flush(c->win);
}

static void call_action(Ctl *c, uint32_t action, int part)
{
	if (action == 0xffffffffu)
		action = c->action;
	if (action && action != 0xffffffffu)
		ppc_cb2(action, c->h, part);
}

static int set_value(Ctl *c, int v)
{
	if (v < c->min)
		v = c->min;
	if (v > c->max)
		v = c->max;
	int changed = v != c->value;
	c->value = (int16_t)v;
	ctl_sync(c);
	return changed;
}

static int track(Ctl *c, QPoint start, uint32_t action, uint16_t mods)
{
	(void)mods;
	int part = test(c, start);
	if (!part)
		return 0;
	Win *w = c->win;
	switch (c->kind) {
	case K_POPUP: {
		if (!c->menu)
			return 0;
		QPoint g = {(int16_t)(c->r.top + w->frame.top - w->port->portRect.top), (int16_t)(c->r.left + w->frame.left - w->port->portRect.left)};
		int chosen = menu_popup(c->menu, g, c->value, c->r.right - c->r.left, ctl_font(c, NULL));
		ev_drop_mouseups();
		if (chosen > 0) {
			set_value(c, chosen);
			redraw(c);
			return part;
		}
		return 0;
	}
	case K_BEVEL:
		if (part == 2 && c->menu) {
			QPoint g = {(int16_t)(c->r.bottom + w->frame.top - w->port->portRect.top), (int16_t)(c->r.left + w->frame.left - w->port->portRect.left)};
			c->pushed = 1;
			redraw(c);
			int chosen = menu_popup(c->menu, g, 0, c->r.right - c->r.left, ctl_font(c, NULL));
			c->pushed = 0;
			redraw(c);
			ev_drop_mouseups();
			if (chosen > 0) {
				c->menu_value = chosen;
				return part;
			}
			return 0;
		}
		break;
	case K_EDITTEXT:
		te_click(c->te, start, (mods & 0x200) != 0);
		ev_drop_mouseups();
		return part;
	case K_USERPANE:
		if (c->procs[2]) {
			int r = (int16_t)ppc_cb3(c->procs[2], c->h, PTV(start), action);
			ev_drop_mouseups();
			return r;
		}
		while (ev_button_down())
			ev_pump(0.01);
		ev_drop_mouseups();
		return part;
	case K_SCROLL: case K_SLIDER:
		if (part == 129) {
			HIThemeTrackDrawInfo t = track_info(c);
			CGRect thumb;
			HIThemeGetTrackPartBounds(&t, kControlIndicatorPart, &thumb);
			int horiz = (t.attributes & kThemeTrackHorizontal) != 0;
			double grab = horiz ? start.h - thumb.origin.x : start.v - thumb.origin.y;
			int orig = c->value;
			int live = c->kind == K_SLIDER || c->procID == 386 || c->live || (action && action != 0xffffffffu);
			while (ev_button_down()) {
				QPoint m = mouse_local(w);
				CGRect nt = thumb;
				if (horiz)
					nt.origin.x = m.h - grab;
				else
					nt.origin.y = m.v - grab;
				CGFloat rel = 0;
				HIThemeGetTrackThumbPositionFromBounds(&t, &nt, &rel);
				SInt32 v = orig;
				HIThemeGetTrackLiveValue(&t, rel, &v);
				if (set_value(c, v)) {
					redraw(c);
					if (live)
						call_action(c, action, part);
				}
				ev_pump(0.015);
			}
			ev_drop_mouseups();
			return part;
		}
		/* fallthrough: arrows and page parts repeat */
	case K_ARROWS: {
		uint32_t next = 0;
		int first = 1;
		while (ev_button_down()) {
			QPoint m = mouse_local(w);
			int in = test(c, m) == part;
			if (in != c->pushed) {
				c->pushed = in;
				redraw(c);
			}
			if (in && ev_ticks() >= next) {
				call_action(c, action, part);
				redraw(c);
				next = ev_ticks() + (first ? 20 : 4);
				first = 0;
			}
			ev_pump(0.015);
		}
		c->pushed = 0;
		redraw(c);
		ev_drop_mouseups();
		return part;
	}
	default:
		break;
	}
	// buttons: pressed while the mouse is inside
	int in = 1;
	c->pushed = 1;
	redraw(c);
	while (ev_button_down()) {
		QPoint m = mouse_local(w);
		int now = test(c, m) == part;
		if (now != in) {
			in = now;
			c->pushed = in;
			redraw(c);
		}
		if (action && action != 0xffffffffu && in)
			call_action(c, action, part);
		ev_pump(0.015);
	}
	c->pushed = 0;
	ev_drop_mouseups();
	if (!in) {
		redraw(c);
		return 0;
	}
	// automatic behavior of some variants
	if ((c->kind == K_CHECK && (c->procID == 371 || c->procID == 1)) || (c->kind == K_RADIO && c->procID == 372)) {
		if (c->kind == K_CHECK && c->procID == 371)
			set_value(c, c->value ? 0 : 1);
		else if (c->kind == K_RADIO)
			set_value(c, 1);
	}
	if (c->kind == K_TABS)
		set_value(c, part);
	if ((c->kind == K_TRIANGLE && (c->variant & 1)) || (c->kind == K_DISCLOSURE && c->behavior))
		set_value(c, !c->value);
	if (c->kind == K_BEVEL && (c->behavior & 0x0100))
		set_value(c, !c->value);
	if (c->kind == K_BEVEL && (c->behavior & 0x0200))
		set_value(c, 1);
	redraw(c);
	return part;
}

// ---- shims --------------------------------------------------------------------------------------------

#define C0 CTL(A(0))

static void sh_NewControl(PPC *c)
{
	// NewControl(window, bounds, title, visible, value, min, max, procID, refCon)
	Win *w = WIN(A(0));
	if (!w) {
		RET(0);
		return;
	}
	uint8_t title[256] = {0};
	if (A(2))
		memcpy(title, G(A(2)), LD8(A(2)) + 1);
	if (ppc_verbose >= 2)
		ppc_log("NewControl proc %d value %d min %d max %d '%.*s'", (int16_t)A(7), (int16_t)A(4), (int16_t)A(5), (int16_t)A(6), title[0], title + 1);
	Ctl *k = ctl_new(w, RECT(A(1)), title, A(3) & 0xff, (int16_t)A(4), (int16_t)A(5), (int16_t)A(6), (int16_t)A(7), A(8));
	if (k->visible)
		ctl_draw(k);
	RET(k->h);
}

static void sh_CreateRootControl(PPC *c)
{
	Win *w = WIN(A(0));
	if (!w) {
		RET(-50);
		return;
	}
	if (w->root) {
		if (A(1))
			ST32(A(1), w->root);
		RET(-30584);   // errRootAlreadyExists
		return;
	}
	Ctl *k = ctl_new(w, (QRect){-32767, -32767, 32767, 32767}, NULL, 1, 0, 0, 0, 256, 0);
	w->root = k->h;
	if (A(1))
		ST32(A(1), k->h);
	RET(0);
}
static void sh_GetRootControl(PPC *c)
{
	Win *w = WIN(A(0));
	if (A(1))
		ST32(A(1), w ? w->root : 0);
	RET(w && w->root ? 0 : -30583);
}
static void sh_EmbedControl(PPC *c)
{
	Ctl *k = C0, *p = CTL(A(1));
	if (!k || !p) {
		RET(-50);
		return;
	}
	remove_child(k);
	add_child(p, k);
	RET(0);
}
static void sh_GetIndexedSubControl(PPC *c)
{
	Ctl *p = C0;
	int i = (int16_t)A(1);
	Ctl *k = p ? p->child : NULL;
	while (k && --i > 0)
		k = k->next;
	if (A(2))
		ST32(A(2), k ? k->h : 0);
	RET(k ? 0 : -50);
}
static void sh_GetControlOwner(PPC *c) { Ctl *k = C0; RET(k && k->win ? k->win->tok : 0); }
static void sh_DisposeControl(PPC *c) { Ctl *k = C0; if (k) dispose_ctl(k); }
static void sh_Draw1Control(PPC *c) { ctl_draw(C0); }
static void sh_DrawControlInCurrentPort(PPC *c)
{
	Ctl *k = C0;
	if (!k || !eff_visible(k))
		return;
	Win *save = k->win;
	if (qd_port && qd_port->win == NULL && qd_port != k->win->port) {
		// into an offscreen port: draw there with the same coordinates
		Win tmp = *save;
		tmp.port = qd_port;
		k->win = &tmp;
		draw_tree(k);
		k->win = save;
		return;
	}
	ctl_draw(k);
}
static void sh_ShowControl(PPC *c)
{
	Ctl *k = C0;
	if (k && !k->visible) {
		k->visible = 1;
		ctl_sync(k);
		ctl_draw(k);
	}
}
static void sh_HideControl(PPC *c)
{
	Ctl *k = C0;
	if (k && k->visible) {
		int was = eff_visible(k);
		k->visible = 0;
		ctl_sync(k);
		if (was && k->win) {
			Port *save = qd_port;
			qd_port = k->win->port;
			qd_fill_rect(k->win->port, k->r, qd_back(k->win->port));
			qd_port = save;
			win_invalidate(k->win, k->r);
		}
	}
}
static void sh_SetControlVisibility(PPC *c)
{
	Ctl *k = C0;
	if (!k) {
		RET(-50);
		return;
	}
	k->visible = A(1) & 0xff;
	ctl_sync(k);
	if (A(2) & 0xff) {
		if (k->visible)
			ctl_draw(k);
		else if (k->win)
			win_invalidate(k->win, k->r);
	}
	RET(0);
}
static void sh_IsControlVisible(PPC *c) { Ctl *k = C0; RET(k && eff_visible(k)); }
static void sh_ActivateControl(PPC *c)
{
	Ctl *k = C0;
	if (k && !k->active) {
		k->active = 1;
		if (k->kind == K_USERPANE && k->procs[5])
			ppc_cb2(k->procs[5], k->h, 1);
		if (k->te)
			te_activate(k->te, k->focus != 0);
		ctl_draw(k);
	}
	RET(0);
}
static void sh_DeactivateControl(PPC *c)
{
	Ctl *k = C0;
	if (k && k->active) {
		k->active = 0;
		if (k->kind == K_USERPANE && k->procs[5])
			ppc_cb2(k->procs[5], k->h, 0);
		if (k->te)
			te_activate(k->te, 0);
		ctl_draw(k);
	}
	RET(0);
}
static void sh_IsControlActive(PPC *c) { Ctl *k = C0; RET(k && eff_active(k)); }
static void sh_HiliteControl(PPC *c)
{
	Ctl *k = C0;
	if (!k)
		return;
	int h = A(1) & 0xff;
	if (h != k->hilite) {
		k->hilite = h;
		k->pushed = h != 0 && h != 255;
		ctl_sync(k);
		ctl_draw(k);
	}
}
static void sh_IsControlHilited(PPC *c) { Ctl *k = C0; RET(k && k->hilite != 0 && k->hilite != 255); }
static void sh_GetControlValue(PPC *c) { Ctl *k = C0; RET(k ? (uint32_t)(int32_t)k->value : 0); }
static void sh_GetControlMinimum(PPC *c) { Ctl *k = C0; RET(k ? (uint32_t)(int32_t)k->min : 0); }
static void sh_GetControlMaximum(PPC *c) { Ctl *k = C0; RET(k ? (uint32_t)(int32_t)k->max : 0); }
static void sh_SetControlValue(PPC *c)
{
	Ctl *k = C0;
	if (k && set_value(k, (int16_t)A(1)))
		ctl_draw(k);
}
static void sh_SetControlMinimum(PPC *c)
{
	Ctl *k = C0;
	if (!k)
		return;
	k->min = (int16_t)A(1);
	if (k->value < k->min)
		k->value = k->min;
	ctl_sync(k);
	ctl_draw(k);
}
static void sh_SetControlMaximum(PPC *c)
{
	Ctl *k = C0;
	if (!k)
		return;
	k->max = (int16_t)A(1);
	if (k->value > k->max)
		k->value = k->max < k->min ? k->min : k->max;
	ctl_sync(k);
	ctl_draw(k);
}
static void sh_SetControlViewSize(PPC *c) { Ctl *k = C0; if (k) { k->viewSize = A(1); ctl_draw(k); } }
static void sh_GetControlBounds(PPC *c) { Ctl *k = C0; if (k) PUTRECT(A(1), k->r); RET(A(1)); }
static void sh_SetControlBounds(PPC *c)
{
	Ctl *k = C0;
	if (!k)
		return;
	k->r = RECT(A(1));
	if (k->te) {
		QRect tr = k->r;
		tr.left += 3;
		tr.right -= 3;
		tr.top += 3;
		tr.bottom -= 3;
		te_set_rects(k->te, tr, tr);
	}
	ctl_sync(k);
}
static void sh_SetControlTitle(PPC *c)
{
	Ctl *k = C0;
	if (!k || !A(1))
		return;
	memcpy(k->title, G(A(1)), LD8(A(1)) + 1);
	ctl_sync(k);
	ctl_draw(k);
}
static void sh_GetControlTitle(PPC *c) { Ctl *k = C0; if (k) memcpy(G(A(1)), k->title, k->title[0] + 1); }
static void sh_SetControlReference(PPC *c) { Ctl *k = C0; if (k) { k->refCon = A(1); ctl_sync(k); } }
static void sh_GetControlReference(PPC *c) { Ctl *k = C0; RET(k ? k->refCon : 0); }
static void sh_SetControlAction(PPC *c) { Ctl *k = C0; if (k) { k->action = A(1); ctl_sync(k); } }
static void sh_GetControlVariant(PPC *c) { Ctl *k = C0; RET(k ? k->variant : 0); }
static void sh_GetControlFeatures(PPC *c)
{
	Ctl *k = C0;
	uint32_t f = 0;
	if (k) {
		f = 0x2;   // kControlSupportsEmbedding... for containers
		if (k->kind == K_EDITTEXT)
			f |= 0x4 | 0x8 | 0x10;   // focus, idle, key events
		if (k->kind == K_USERPANE)
			f = 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80;
		if (k->kind == K_NULL)
			f = 0x82;
	}
	if (A(1))
		ST32(A(1), f);
	RET(0);
}
static void sh_SetControlFontStyle(PPC *c)
{
	Ctl *k = C0;
	if (!k) {
		RET(-50);
		return;
	}
	uint32_t s = A(1);
	k->fs_flags = LD16(s);
	k->fs_font = (int16_t)LD16(s + 2);
	k->fs_size = (int16_t)LD16(s + 4);
	k->fs_style = (int16_t)LD16(s + 6);
	k->fs_just = (int16_t)LD16(s + 10);
	k->fs_fore = (RGB16){(uint16_t)LD16(s + 12), (uint16_t)LD16(s + 14), (uint16_t)LD16(s + 16)};
	k->fs_back = (RGB16){(uint16_t)LD16(s + 18), (uint16_t)LD16(s + 20), (uint16_t)LD16(s + 22)};
	if (k->te) {
		if (k->fs_flags & 1)
			k->te->font = k->fs_font;
		if (k->fs_flags & 4)
			k->te->size = k->fs_size;
		if (k->fs_flags & 2)
			k->te->face = k->fs_style;
		te_restyle_all(k->te);
	}
	RET(0);
}
static void sh_SetControlColorProc(PPC *c) { Ctl *k = C0; if (k) k->color_proc = A(1); RET(0); }

static void sh_TestControl(PPC *c) { Ctl *k = C0; RET(k ? test(k, PT(A(1))) : 0); }
static void sh_TrackControl(PPC *c) { Ctl *k = C0; RET(k ? track(k, PT(A(1)), A(2), ev_modifiers()) : 0); }
static void sh_HandleControlClick(PPC *c) { Ctl *k = C0; RET(k ? track(k, PT(A(1)), A(3), (uint16_t)A(2)) : 0); }
static void sh_HandleControlKey(PPC *c)
{
	// HandleControlKey(control, keyCode, charCode, modifiers)
	Ctl *k = C0;
	if (!k) {
		RET(0);
		return;
	}
	if (k->kind == K_EDITTEXT && k->te) {
		uint8_t ch = (uint8_t)A(2);
		if (ch == 13 || ch == 3 || ch == 9) {
			RET(0);
			return;
		}
		te_key(k->te, ch, (uint16_t)A(3));
		RET(5);
		return;
	}
	if (k->kind == K_USERPANE && k->procs[4]) {
		RET((int16_t)ppc_cb4(k->procs[4], k->h, (int16_t)A(1), (int16_t)A(2), (int16_t)A(3)));
		return;
	}
	RET(0);
}
static void sh_SetKeyboardFocus(PPC *c)
{
	// SetKeyboardFocus(window, control, part)
	Win *w = WIN(A(0));
	Ctl *k = CTL(A(1));
	int part = (int16_t)A(2);
	if (!w) {
		RET(-50);
		return;
	}
	// clear the old focus
	for (uint32_t i = 0; i < ctls.cap; i++)
		if (ctls.k[i] && ctls.k[i] != 0xffffffffu) {
			Ctl *o = ctls.v[i];
			if (o->win == w && o->focus && o != k) {
				o->focus = 0;
				if (o->te)
					te_activate(o->te, 0);
				if (o->kind == K_USERPANE && o->procs[6])
					ppc_cb2(o->procs[6], o->h, 0);
				ctl_draw(o);
			}
		}
	if (k && part) {
		k->focus = part;
		if (k->te)
			te_activate(k->te, 1);
		if (k->kind == K_USERPANE && k->procs[6])
			ppc_cb2(k->procs[6], k->h, part);
		ctl_draw(k);
	}
	RET(0);
}
static void sh_SendControlMessage(PPC *c)
{
	Ctl *k = C0;
	if (k && k->kind == K_CUSTOM && k->defproc)
		RET(ppc_cb4(k->defproc, k->variant, k->h, (int16_t)A(1), A(2)));
	else if (k && k->kind == K_NULL && (int16_t)A(1) == 27)
		RET(0x206f6b20);   // kControlSupportsNewMessages
	else
		RET(0);
}

// ---- data tags ---------------------------------------------------------------------------------------------------

static void set_static_text(Ctl *k, const void *bytes, uint32_t n)
{
	if (!k->text)
		k->text = NewHandleG(n);
	else
		HSetSize(k->text, n);
	memcpy(G(HP(k->text)), bytes, n);
}

static void sh_SetControlData(PPC *c)
{
	// SetControlData(control, part, tag, size, data)
	Ctl *k = C0;
	if (!k) {
		RET(-50);
		return;
	}
	uint32_t tag = A(2), size = A(3), d = A(4);
	switch (tag) {
	case 'dflt': k->is_default = LD8(d) != 0; break;
	case 'cncl': k->is_cancel = LD8(d) != 0; break;
	case 'font': {
		uint32_t save = c->r[4];
		c->r[4] = d;
		sh_SetControlFontStyle(c);
		c->r[4] = save;
		break;
	}
	case 'text':
		if (k->kind == K_EDITTEXT)
			te_set_text(k->te, G(d), (int)size);
		else
			set_static_text(k, G(d), size);
		break;
	case 'cfst': {
		extern NSString *cf_string(uint32_t t);
		NSString *s = cf_string(LD32(d));
		NSData *b = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] ?: [NSData data];
		if (k->kind == K_EDITTEXT)
			te_set_text(k->te, b.bytes, (int)b.length);
		else
			set_static_text(k, b.bytes, (uint32_t)b.length);
		break;
	}
	case 'sele':
		if (k->te)
			te_set_select(k->te, (int16_t)LD16(d), (int16_t)LD16(d + 2));
		break;
	case 'lock': if (k->te) k->te->readonly = LD8(d) != 0; break;
	case 'pass': break;
	case 'mhan': k->menu = LD32(d); if (k->kind == K_POPUP) { k->max = (int16_t)menu_count(k->menu); ctl_sync(k); } break;
	case 'mid ': k->menuID = (int16_t)LD16(d); k->menu = menu_get_handle(k->menuID); break;
	case 'mvsl': k->menu_value = (int16_t)LD16(d); break;
	case 'cont': {   // ControlButtonContentInfo: contentType, union
		k->content = (int16_t)LD16(d);
		if (k->content >= 128)
			k->content_h = LD32(d + 2);
		else
			k->content_id = (int16_t)LD16(d + 2);
		if (k->kind == K_ICON && k->content >= 128)
			k->content_h = LD32(d + 2);
		break;
	}
	case 'ires': k->content_id = (int16_t)LD16(d); break;
	case 'pich': k->content_h = LD32(d); break;
	case 'tabi': {
		int part = (int16_t)A(1);
		if (part >= 1 && part <= k->tab_count)
			memcpy(k->tab_titles[part - 1], G(d + 4), LD8(d + 4) + 1);
		break;
	}
	case 'inde': k->indeterminate = LD8(d) != 0; break;
	case 'draw': k->procs[0] = LD32(d); break;
	case 'hitt': k->procs[1] = LD32(d); break;
	case 'trak': k->procs[2] = LD32(d); break;
	case 'idle': k->procs[3] = LD32(d); break;
	case 'keyd': k->procs[4] = LD32(d); break;
	case 'acti': k->procs[5] = LD32(d); break;
	case 'foci': k->procs[6] = LD32(d); break;
	case 'back': k->procs[7] = LD32(d); break;
	default:
		if (ppc_verbose)
			ppc_log("SetControlData: tag '%.4s' ignored (kind %d)", (char *)&(uint32_t){__builtin_bswap32(tag)}, k->kind);
		break;
	}
	RET(0);
}

static void sh_GetControlData(PPC *c)
{
	// GetControlData(control, part, tag, bufferSize, buffer, Size *actualSize)
	Ctl *k = C0;
	if (!k) {
		RET(-50);
		return;
	}
	uint32_t tag = A(2), bufsize = A(3), buf = A(4), outsz = A(5);
	uint8_t tmp[64];
	const void *src = tmp;
	uint32_t n = 0;
	switch (tag) {
	case 'text':
		if (k->kind == K_EDITTEXT) {
			src = k->te->t;
			n = (uint32_t)k->te->n;
		} else if (k->text) {
			src = G(HP(k->text));
			n = HSize(k->text);
		}
		break;
	case 'sele':
		if (!k->te)
			RET(-30580);
		{
			uint16_t a = __builtin_bswap16((uint16_t)k->te->selStart), b = __builtin_bswap16((uint16_t)k->te->selEnd);
			memcpy(tmp, &a, 2);
			memcpy(tmp + 2, &b, 2);
			n = 4;
		}
		break;
	case 'tehd':
		if (!k->te) {
			RET(-30580);
			return;
		}
		{
			uint32_t h = __builtin_bswap32(te_handle(k->te));
			memcpy(tmp, &h, 4);
			n = 4;
		}
		break;
	case 'mhan': { uint32_t h = __builtin_bswap32(k->menu); memcpy(tmp, &h, 4); n = 4; break; }
	case 'mid ': { uint16_t v = __builtin_bswap16((uint16_t)k->menuID); memcpy(tmp, &v, 2); n = 2; break; }
	case 'mvsl': { uint16_t v = __builtin_bswap16((uint16_t)k->menu_value); memcpy(tmp, &v, 2); n = 2; break; }
	case 'dflt': tmp[0] = (uint8_t)k->is_default; n = 1; break;
	case 'rect': {   // the tab content rectangle
		QRect r = k->r;
		r.top += 32;
		r.left += 8;
		r.right -= 8;
		r.bottom -= 8;
		int16_t v[4] = {(int16_t)__builtin_bswap16(r.top), (int16_t)__builtin_bswap16(r.left), (int16_t)__builtin_bswap16(r.bottom), (int16_t)__builtin_bswap16(r.right)};
		memcpy(tmp, v, 8);
		n = 8;
		break;
	}
	case 'cfst': {
		extern uint32_t cf_make_string(NSString *s);
		NSString *s = k->te ? mac_ns(k->te->t, k->te->n) : k->text ? mac_ns(G(HP(k->text)), HSize(k->text)) : @"";
		uint32_t t = __builtin_bswap32(cf_make_string(s));
		memcpy(tmp, &t, 4);
		n = 4;
		break;
	}
	case 'cont': {
		uint16_t t = __builtin_bswap16((uint16_t)k->content);
		memcpy(tmp, &t, 2);
		uint32_t h = __builtin_bswap32(k->content >= 128 ? k->content_h : (uint32_t)k->content_id << 16);
		memcpy(tmp + 2, &h, 4);
		n = 6;
		break;
	}
	default:
		if (ppc_verbose)
			ppc_log("GetControlData: tag '%.4s' not supported", (char *)&(uint32_t){__builtin_bswap32(tag)});
		RET(-30581);   // errDataNotSupported
		return;
	}
	if (outsz)
		ST32(outsz, n);
	if (buf)
		memcpy(G(buf), src, n < bufsize ? n : bufsize);
	RET(0);
}

// ---- creation calls of Carbon -----------------------------------------------------------------------------------

static void sh_CreatePopupButtonControl(PPC *c)
{
	// (window, bounds, title CFString, menuID, variableWidth, titleWidth, titleJust, titleStyle, ControlRef *)
	extern NSString *cf_string(uint32_t t);
	Win *w = WIN(A(0));
	NSString *t = cf_string(A(2)) ?: @"";
	uint8_t title[256] = {0};
	CFIndex used = 0;
	CFStringGetBytes((CFStringRef)t, CFRangeMake(0, t.length < 255 ? t.length : 255), kCFStringEncodingMacRoman, '?', false, title + 1, 255, &used);
	title[0] = (uint8_t)used;
	Ctl *k = ctl_new(w, RECT(A(1)), title, 1, 0, (int16_t)A(3), (int16_t)A(5), 400, 0);
	k->title_just = (int16_t)A(6);
	ST32(A(8), k->h);
	RET(0);
}
static void sh_CreateDisclosureButtonControl(PPC *c)
{
	// (window, bounds, value, autoToggles, ControlRef *)
	Ctl *k = ctl_new(WIN(A(0)), RECT(A(1)), NULL, 1, (int)A(2), 0, 1, 480, 0);
	k->behavior = A(3) & 0xff;
	ST32(A(4), k->h);
	RET(0);
}
static void sh_CreateIconControl(PPC *c)
{
	// (window, bounds, const ControlButtonContentInfo *, dontTrack, ControlRef *)
	Ctl *k = ctl_new(WIN(A(0)), RECT(A(1)), NULL, 1, 0, 0, 0, (A(3) & 0xff) ? 321 : 320, 0);
	uint32_t ci = A(2);
	if (ci) {
		k->content = (int16_t)LD16(ci);
		if (k->content >= 128)
			k->content_h = LD32(ci + 2);
		else
			k->content_id = (int16_t)LD16(ci + 2);
	}
	ST32(A(4), k->h);
	RET(0);
}
static void sh_CreateCustomControl(PPC *c)
{
	// (window, bounds, const ControlDefSpec *, Collection, ControlRef *)
	Ctl *k = ctl_new(WIN(A(0)), RECT(A(1)), NULL, 1, 0, 0, 0, 0xffff, 0);
	k->kind = K_CUSTOM;
	k->defproc = A(2) ? LD32(A(2) + 4) : 0;
	if (k->defproc)
		ppc_cb4(k->defproc, 0, k->h, 3, 0);   // initCntl
	ST32(A(4), k->h);
	RET(0);
}

static const ShimDef ctlshims[] = {
	S(NewControl), S(CreateRootControl), S(GetRootControl), S(EmbedControl), S(GetIndexedSubControl),
	S(GetControlOwner), S(DisposeControl), S(Draw1Control), S(DrawControlInCurrentPort), S(ShowControl),
	S(HideControl), S(SetControlVisibility), S(IsControlVisible), S(ActivateControl), S(DeactivateControl),
	S(IsControlActive), S(HiliteControl), S(IsControlHilited), S(GetControlValue), S(GetControlMinimum),
	S(GetControlMaximum), S(SetControlValue), S(SetControlMinimum), S(SetControlMaximum), S(SetControlViewSize),
	S(GetControlBounds), S(SetControlBounds), S(SetControlTitle), S(GetControlTitle), S(SetControlReference),
	S(GetControlReference), S(SetControlAction), S(GetControlVariant), S(GetControlFeatures), S(SetControlFontStyle),
	S(SetControlColorProc), S(TestControl), S(TrackControl), S(HandleControlClick), S(HandleControlKey),
	S(SetKeyboardFocus), S(SendControlMessage), S(SetControlData), S(GetControlData), S(CreatePopupButtonControl),
	S(CreateDisclosureButtonControl), S(CreateIconControl), S(CreateCustomControl),
};
REGISTER(ctlshims)
