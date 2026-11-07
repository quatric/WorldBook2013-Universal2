// Menu Manager (see menu.h).
//
// A choice in the Cocoa menu bar reaches the guest as a mouse-down whose
// FindWindow part is inMenuBar; MenuSelect then returns the menu and item that
// were chosen. Command keys are Cocoa key equivalents and arrive the same way;
// keys the menus do not take reach the guest as key-downs for MenuKey.
#import <AppKit/AppKit.h>
#include "menu.h"
#include "hmap.h"

const uint8_t *res_bytes(uint32_t type, int16_t id, uint32_t *len);
NSString *qd_font_name(int font);

typedef struct {
	uint8_t text[256];
	uint8_t icon, cmd, mark, style;
	int enabled;
	uint32_t command;
} Item;

typedef struct Menu {
	uint32_t h;
	int16_t id;
	uint8_t title[256];
	Item *items;
	int n, cap;
	int enabled;
	int inserted;          // 1 menu bar, -1 hierarchical
	int16_t res_id;        // loaded from this MENU resource
} Menu;

static HMap menus;           // MenuHandle -> Menu
static Menu *bar[64];        // the menu bar, in order
static int nbar;
static Menu *hier[64];       // hierarchical menus
static int nhier;
static int dirty = 1;
static int16_t help_id = -16490;
static Menu *help_menu;

static Menu *M(uint32_t h) { return h ? hm_get(&menus, h) : NULL; }

// the guest's MenuInfo: menuID, width, height, proc, enableFlags, title
static void msync_(Menu *m)
{
	if (!is_handle(m->h))
		return;
	if (HSize(m->h) < 14 + 256u)
		HSetSize(m->h, 14 + 256);
	uint32_t p = HP(m->h);
	ST16(p, m->id);
	ST16(p + 2, 200);
	ST16(p + 4, (uint16_t)(m->n * 18));
	ST32(p + 6, 0);
	uint32_t f = m->enabled ? 1 : 0;
	for (int i = 0; i < m->n && i < 31; i++)
		if (m->items[i].enabled)
			f |= 1u << (i + 1);
	if (m->n > 31)
		f |= 0x80000000u;
	ST32(p + 10, f);
	memcpy(G(p + 14), m->title, m->title[0] + 1);
	dirty = 1;
}

static Menu *menu_new(int16_t id, const uint8_t *title)
{
	Menu *m = calloc(1, sizeof *m);
	m->id = id;
	memcpy(m->title, title, title[0] + 1);
	m->enabled = 1;
	m->h = NewHandleClearG(14 + 256);
	hm_put(&menus, m->h, m);
	msync_(m);
	return m;
}

static Item *insert_item(Menu *m, int at)
{
	if (m->n == m->cap) {
		m->cap = m->cap ? m->cap * 2 : 16;
		m->items = realloc(m->items, m->cap * sizeof(Item));
	}
	if (at < 0 || at > m->n)
		at = m->n;
	memmove(m->items + at + 1, m->items + at, (m->n - at) * sizeof(Item));
	m->n++;
	Item *it = &m->items[at];
	memset(it, 0, sizeof *it);
	it->enabled = 1;
	return it;
}

// AppendMenu's metacharacters: ; separates items, ^icon !mark <style /key (disabled
static void append_items(Menu *m, const uint8_t *s, int n, int after)
{
	int i = 0;
	int at = after;
	while (i <= n) {
		int j = i;
		while (j < n && s[j] != ';' && s[j] != 13)
			j++;
		Item tmp = {{0}, 0, 0, 0, 0, 1, 0};
		int k = i;
		int tl = 0;
		while (k < j) {
			uint8_t ch = s[k];
			if (ch == '^' && k + 1 < j) {
				tmp.icon = (uint8_t)(s[k + 1] - 48);
				k += 2;
			} else if (ch == '!' && k + 1 < j) {
				tmp.mark = s[k + 1];
				k += 2;
			} else if (ch == '<' && k + 1 < j) {
				uint8_t st = s[k + 1];
				tmp.style |= st == 'B' ? 1 : st == 'I' ? 2 : st == 'U' ? 4 : st == 'O' ? 8 : st == 'S' ? 16 : 0;
				k += 2;
			} else if (ch == '/' && k + 1 < j) {
				tmp.cmd = s[k + 1];
				k += 2;
			} else if (ch == '(' && tl == 0) {
				tmp.enabled = 0;
				k++;
			} else {
				if (tl < 255)
					tmp.text[1 + tl++] = ch;
				k++;
			}
		}
		tmp.text[0] = (uint8_t)tl;
		if (tl || j < n) {
			Item *it = insert_item(m, at);
			*it = tmp;
			at++;
		}
		i = j + 1;
		if (j >= n)
			break;
	}
	msync_(m);
}

uint32_t menu_load(int16_t id)
{
	uint32_t len;
	const uint8_t *d = res_bytes('MENU', id, &len);
	if (!d || len < 15)
		return 0;
	int16_t mid = (int16_t)(d[0] << 8 | d[1]);
	Menu *m = menu_new(mid, d + 14);
	m->res_id = id;
	uint32_t enable = (uint32_t)d[10] << 24 | d[11] << 16 | d[12] << 8 | d[13];
	m->enabled = enable & 1;
	uint32_t o = 14 + d[14] + 1;
	int idx = 0;
	while (o < len && d[o]) {
		Item *it = insert_item(m, -1);
		memcpy(it->text, d + o, d[o] + 1);
		o += d[o] + 1;
		if (o + 4 > len)
			break;
		it->icon = d[o];
		it->cmd = d[o + 1];
		it->mark = d[o + 2];
		it->style = d[o + 3];
		it->enabled = idx < 31 ? (enable >> (idx + 1)) & 1 : 1;
		o += 4;
		idx++;
	}
	// commands from an xmnu resource
	const uint8_t *x = res_bytes('xmnu', id, &len);
	if (x && len >= 4) {
		int cnt = x[2] << 8 | x[3];
		uint32_t q = 4;
		for (int i = 0; i < cnt && q + 2 <= len; i++) {
			int type = x[q] << 8 | x[q + 1];
			if (type == 1 && q + 6 <= len && i < m->n)
				m->items[i].command = (uint32_t)x[q + 2] << 24 | x[q + 3] << 16 | x[q + 4] << 8 | x[q + 5];
			if (type == 1)
				q += 2 + 4 + 1 + 1 + 4 + 2 + 2 + 4 + 2 + 2;   // the extended entry
			else
				q += 2;
		}
	}
	msync_(m);
	return m->h;
}

uint32_t menu_get_handle(int16_t id)
{
	for (int i = 0; i < nbar; i++)
		if (bar[i]->id == id)
			return bar[i]->h;
	for (int i = 0; i < nhier; i++)
		if (hier[i]->id == id)
			return hier[i]->h;
	return 0;
}

static Menu *by_id(int16_t id) { return M(menu_get_handle(id)); }

int menu_count(uint32_t h) { Menu *m = M(h); return m ? m->n : 0; }
int16_t menu_id(uint32_t h) { Menu *m = M(h); return m ? m->id : 0; }

void menu_item_text(uint32_t h, int item, uint8_t *p)
{
	Menu *m = M(h);
	p[0] = 0;
	if (m && item >= 1 && item <= m->n)
		memcpy(p, m->items[item - 1].text, m->items[item - 1].text[0] + 1);
}

// ---- Cocoa menus ---------------------------------------------------------------------------------

@interface XLMenuTarget : NSObject
- (void)choose:(NSMenuItem *)it;
- (void)quit:(id)sender;
- (void)about:(id)sender;
@end

static XLMenuTarget *target;
static int popup_choice;
static int in_popup;
static int16_t apple_id;   // the Apple menu, folded into the application menu

@implementation XLMenuTarget
- (void)choose:(NSMenuItem *)it
{
	uint32_t data = (uint32_t)it.tag;
	if (in_popup) {
		popup_choice = (int)(data & 0xffff);
		return;
	}
	ev_post_mouse_part(NULL, 1, data);
}
- (void)quit:(id)sender
{
	(void)sender;
	Ev e = {0};
	e.what = 23;   // kHighLevelEvent
	e.message = 'aevt';
	e.where = (QPoint){(int16_t)('quit' >> 16), (int16_t)('quit' & 0xffff)};
	ev_post(e);
}
- (void)about:(id)sender
{
	(void)sender;
	ev_post_mouse_part(NULL, 1, (uint32_t)(uint16_t)apple_id << 16 | 1);
}
@end

static NSString *item_title(const uint8_t *p)
{
	NSString *s = mac_ns(p + 1, p[0]);
	return s ? s : @"";
}

static unichar mark_char(uint8_t mark)
{
	return mark == 0x12 ? 0x2713 : mark == 0xa5 ? 0x2022 : mark == 0x13 ? 0x25c6 : 0;
}

static NSMenu *build(Menu *m, int depth);

static NSMenuItem *build_item(Menu *m, int i, int depth)
{
	Item *it = &m->items[i];
	if (it->text[0] >= 1 && it->text[1] == '-' && (it->text[0] == 1 || it->text[2] == '-'))
		return [NSMenuItem separatorItem];
	NSString *title = item_title(it->text);
	NSMenuItem *ni = [[NSMenuItem alloc] initWithTitle:title action:@selector(choose:) keyEquivalent:@""];
	ni.target = target;
	ni.tag = (NSInteger)((uint32_t)(uint16_t)m->id << 16 | (uint32_t)(i + 1));
	ni.enabled = m->enabled && it->enabled;
	if (it->cmd == 0x1b) {
		Menu *sub = by_id(it->mark);
		if (sub && depth < 4)
			ni.submenu = build(sub, depth + 1);
	} else {
		if (it->cmd > 0x20 && it->cmd < 0x7f) {
			ni.keyEquivalent = [[NSString stringWithFormat:@"%c", it->cmd] lowercaseString];
			ni.keyEquivalentModifierMask = NSEventModifierFlagCommand;
		}
		if (it->mark) {
			unichar mc = mark_char(it->mark);
			if (mc == 0x2713)
				ni.state = NSControlStateValueOn;
			else if (mc == 0x2022 || mc == 0x25c6)
				ni.state = NSControlStateValueMixed;
			else
				ni.state = NSControlStateValueOn;
		}
	}
	if (it->style) {
		NSFontManager *fm = NSFontManager.sharedFontManager;
		NSFont *f = [NSFont menuFontOfSize:0];
		if (it->style & 1)
			f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
		if (it->style & 2)
			f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
		NSMutableDictionary *at = [NSMutableDictionary dictionaryWithObject:f forKey:NSFontAttributeName];
		if (it->style & 4)
			at[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
		ni.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:at];
	}
	return ni;
}

static NSMenu *build(Menu *m, int depth)
{
	NSMenu *nm = [[NSMenu alloc] initWithTitle:item_title(m->title)];
	nm.autoenablesItems = NO;
	for (int i = 0; i < m->n; i++)
		[nm addItem:build_item(m, i, depth)];
	return nm;
}

static int guest_has_quit(void)
{
	for (int b = 0; b < nbar; b++)
		for (int i = 0; i < bar[b]->n; i++)
			if (bar[b]->items[i].cmd == 'Q' || bar[b]->items[i].cmd == 'q')
				return 1;
	return 0;
}

void menu_flush(void)
{
	if (!dirty || in_popup)
		return;
	dirty = 0;
	if (!target)
		target = [XLMenuTarget new];
	NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
	main.autoenablesItems = NO;
	NSString *app = NSProcessInfo.processInfo.processName;
	NSString *bn = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
	if (bn)
		app = bn;
	NSMenu *am = [[NSMenu alloc] initWithTitle:app];
	am.autoenablesItems = NO;
	Menu *apple = NULL;
	for (int b = 0; b < nbar; b++)
		if (bar[b]->title[0] == 1 && bar[b]->title[1] == 0x14) {
			apple = bar[b];
			break;
		}
	if (apple) {
		apple_id = apple->id;
		for (int i = 0; i < apple->n; i++)
			[am addItem:build_item(apple, i, 0)];
		[am addItem:[NSMenuItem separatorItem]];
	} else {
		NSMenuItem *ab = [am addItemWithTitle:[@"About " stringByAppendingString:app] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
		ab.target = NSApp;
		[am addItem:[NSMenuItem separatorItem]];
	}
	NSMenuItem *hide = [am addItemWithTitle:[@"Hide " stringByAppendingString:app] action:@selector(hide:) keyEquivalent:@"h"];
	hide.target = NSApp;
	NSMenuItem *ho = [am addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
	ho.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
	ho.target = NSApp;
	NSMenuItem *sa = [am addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
	sa.target = NSApp;
	[am addItem:[NSMenuItem separatorItem]];
	NSMenuItem *q = [am addItemWithTitle:[@"Quit " stringByAppendingString:app] action:@selector(quit:) keyEquivalent:guest_has_quit() ? @"" : @"q"];
	q.target = target;
	NSMenuItem *ai = [[NSMenuItem alloc] initWithTitle:app action:NULL keyEquivalent:@""];
	ai.submenu = am;
	[main addItem:ai];
	for (int b = 0; b < nbar; b++) {
		Menu *m = bar[b];
		if (m == apple)
			continue;
		NSMenu *nm = build(m, 0);
		NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:nm.title action:NULL keyEquivalent:@""];
		top.submenu = nm;
		top.enabled = m->enabled;
		[main addItem:top];
	}
	NSApp.mainMenu = main;
}

void menu_bar_install(void)
{
	dirty = 1;
	menu_flush();
}

int menu_popup(uint32_t h, QPoint g, int cur, int width, CTFontRef font)
{
	Menu *m = M(h);
	if (!m)
		return 0;
	if (!target)
		target = [XLMenuTarget new];
	NSMenu *nm = build(m, 0);
	if (font)
		nm.font = (__bridge NSFont *)font;
	nm.minimumWidth = width;
	NSMenuItem *pos = cur >= 1 && cur <= (int)nm.numberOfItems ? [nm itemAtIndex:cur - 1] : nil;
	if (pos && pos.state == NSControlStateValueOff)
		pos.state = NSControlStateValueOn;
	popup_choice = 0;
	in_popup = 1;
	NSPoint at = NSMakePoint(g.h, qd_cocoa_y(g.v));
	if (!pos)
		at.y = qd_cocoa_y(g.v);
	[nm popUpMenuPositioningItem:pos atLocation:at inView:nil];
	in_popup = 0;
	return popup_choice;
}

// ---- shims ----------------------------------------------------------------------------------------

static void sh_GetMenu(PPC *c)
{
	int16_t id = (int16_t)A(0);
	// a menu loaded before (resources are loaded once)
	for (uint32_t i = 0; i < menus.cap; i++)
		if (menus.k[i] && menus.k[i] != 0xffffffffu) {
			Menu *m = menus.v[i];
			if (m->res_id == id && m->id == id)
				return RET(m->h);
		}
	RET(menu_load(id));
}
static void sh_NewMenu(PPC *c) { RET(menu_new((int16_t)A(0), G(A(1)))->h); }
static void sh_GetMenuHandle(PPC *c) { RET(menu_get_handle((int16_t)A(0))); }
static void sh_GetMenuID(PPC *c) { Menu *m = M(A(0)); RET(m ? (uint32_t)(int32_t)m->id : 0); }
static void sh_InsertMenu(PPC *c)
{
	Menu *m = M(A(0));
	int16_t before = (int16_t)A(1);
	if (!m || m->inserted)
		return;
	if (before == -1) {
		if (nhier < 64)
			hier[nhier++] = m;
		m->inserted = -1;
	} else {
		int at = nbar;
		for (int i = 0; i < nbar; i++)
			if (before && bar[i]->id == before)
				at = i;
		if (help_menu && at == nbar && m != help_menu)
			for (int i = 0; i < nbar; i++)
				if (bar[i] == help_menu)
					at = i;
		if (nbar < 64) {
			memmove(bar + at + 1, bar + at, (nbar - at) * sizeof *bar);
			bar[at] = m;
			nbar++;
		}
		m->inserted = 1;
	}
	dirty = 1;
}
static void remove_menu(Menu *m)
{
	for (int i = 0; i < nbar; i++)
		if (bar[i] == m) {
			memmove(bar + i, bar + i + 1, (nbar - i - 1) * sizeof *bar);
			nbar--;
			break;
		}
	for (int i = 0; i < nhier; i++)
		if (hier[i] == m) {
			memmove(hier + i, hier + i + 1, (nhier - i - 1) * sizeof *hier);
			nhier--;
			break;
		}
	m->inserted = 0;
	dirty = 1;
}
static void sh_DeleteMenu(PPC *c) { Menu *m = by_id((int16_t)A(0)); if (m) remove_menu(m); }
static void sh_DisposeMenu(PPC *c)
{
	Menu *m = M(A(0));
	if (!m)
		return;
	remove_menu(m);
	hm_del(&menus, m->h);
	DisposeHandleG(m->h);
	free(m->items);
	free(m);
}
static void sh_DrawMenuBar(PPC *c) { (void)c; dirty = 1; }
static void sh_InvalMenuBar(PPC *c) { (void)c; dirty = 1; }
static void sh_HiliteMenu(PPC *c) { (void)c; }
static void sh_FlashMenuBar(PPC *c) { (void)c; }
static void sh_GetMBarHeight(PPC *c) { RET(qd_menubar_height); }
static void sh_ClearMenuBar(PPC *c) { (void)c; while (nbar) remove_menu(bar[0]); }

static void sh_AppendMenu(PPC *c)
{
	Menu *m = M(A(0));
	uint32_t s = A(1);
	if (m)
		append_items(m, G(s + 1), LD8(s), m->n);
}
static void sh_InsertMenuItem(PPC *c)
{
	// InsertMenuItem(menu, itemString, afterItem)
	Menu *m = M(A(0));
	uint32_t s = A(1);
	int after = (int16_t)A(2);
	if (m)
		append_items(m, G(s + 1), LD8(s), after < 0 ? 0 : after > m->n ? m->n : after);
}
static void sh_DeleteMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m || i < 1 || i > m->n)
		return;
	memmove(m->items + i - 1, m->items + i, (m->n - i) * sizeof(Item));
	m->n--;
	msync_(m);
}
static void sh_CountMenuItems(PPC *c) { Menu *m = M(A(0)); RET(m ? m->n : 0); }

static int fontname_cmp(const void *a, const void *b)
{
	return [(__bridge NSString *)*(void *const *)a localizedCaseInsensitiveCompare:(__bridge NSString *)*(void *const *)b];
}

static void res_menu(Menu *m, uint32_t type, int after)
{
	if (type != 'FONT' && type != 'FOND')
		return;
	NSArray *fams = NSFontManager.sharedFontManager.availableFontFamilies;
	int n = (int)fams.count;
	CFTypeRef *names = calloc(n, sizeof *names);
	int k = 0;
	for (NSString *f in fams) {
		if ([f hasPrefix:@"."])
			continue;
		names[k++] = (__bridge CFTypeRef)f;
	}
	qsort(names, k, sizeof *names, fontname_cmp);
	for (int i = 0; i < k; i++) {
		NSString *f = (__bridge NSString *)names[i];
		char buf[256];
		if (![f getCString:buf maxLength:sizeof buf encoding:NSMacOSRomanStringEncoding])
			continue;
		Item *it = insert_item(m, after++);
		size_t l = strlen(buf);
		if (l > 255)
			l = 255;
		it->text[0] = (uint8_t)l;
		memcpy(it->text + 1, buf, l);
	}
	free(names);
	msync_(m);
}
static void sh_AppendResMenu(PPC *c) { Menu *m = M(A(0)); if (m) res_menu(m, A(1), m->n); }
static void sh_InsertResMenu(PPC *c)
{
	Menu *m = M(A(0));
	if (m)
		res_menu(m, A(1), (int16_t)A(2) > m->n ? m->n : (int16_t)A(2) < 0 ? 0 : (int16_t)A(2));
}

static Item *ITEM(PPC *c, int mi, int ii)
{
	Menu *m = M(A(mi));
	int i = (int16_t)A(ii);
	return m && i >= 1 && i <= m->n ? &m->items[i - 1] : NULL;
}
static void sh_EnableMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m)
		return;
	if (i == 0)
		m->enabled = 1;
	else if (i <= m->n)
		m->items[i - 1].enabled = 1;
	msync_(m);
}
static void sh_DisableMenuItem(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	if (!m)
		return;
	if (i == 0)
		m->enabled = 0;
	else if (i <= m->n)
		m->items[i - 1].enabled = 0;
	msync_(m);
}
static void sh_IsMenuItemEnabled(PPC *c)
{
	Menu *m = M(A(0));
	int i = (int16_t)A(1);
	RET(m && m->enabled && (i == 0 || (i <= m->n && m->items[i - 1].enabled)));
}
static void sh_CheckMenuItem(PPC *c) { Item *it = ITEM(c, 0, 1); if (it && it->cmd != 0x1b) { it->mark = (A(2) & 0xff) ? 0x12 : 0; dirty = 1; } }
static void sh_SetItemMark(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->mark = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemMark(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it ? it->mark : 0); }
static void sh_SetItemCmd(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->cmd = (uint8_t)A(2); dirty = 1; } }
static void sh_GetItemCmd(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST16(A(2), it ? it->cmd : 0); }
static void sh_SetItemStyle(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) { it->style = (uint8_t)A(2); dirty = 1; } }
static void sh_SetMenuItemText(PPC *c)
{
	Item *it = ITEM(c, 0, 1);
	if (it) {
		memcpy(it->text, G(A(2)), LD8(A(2)) + 1);
		dirty = 1;
	}
}
static void sh_GetMenuItemText(PPC *c)
{
	Item *it = ITEM(c, 0, 1);
	if (it)
		memcpy(G(A(2)), it->text, it->text[0] + 1);
	else
		ST8(A(2), 0);
}
static void sh_SetMenuItemCommandID(PPC *c) { Item *it = ITEM(c, 0, 1); if (it) it->command = A(2); RET(0); }
static void sh_GetMenuItemCommandID(PPC *c) { Item *it = ITEM(c, 0, 1); if (A(2)) ST32(A(2), it ? it->command : 0); RET(it ? 0 : -5620); }

static Item *find_command(uint32_t menu, uint32_t cmd, Menu **owner)
{
	Menu *only = M(menu);
	for (uint32_t k = 0; k < menus.cap; k++) {
		if (!menus.k[k] || menus.k[k] == 0xffffffffu)
			continue;
		Menu *m = menus.v[k];
		if (only && m != only)
			continue;
		for (int i = 0; i < m->n; i++)
			if (m->items[i].command == cmd) {
				if (owner)
					*owner = m;
				return &m->items[i];
			}
	}
	return NULL;
}
static void sh_EnableMenuCommand(PPC *c) { Menu *m; Item *it = find_command(A(0), A(1), &m); if (it) { it->enabled = 1; msync_(m); } }
static void sh_DisableMenuCommand(PPC *c) { Menu *m; Item *it = find_command(A(0), A(1), &m); if (it) { it->enabled = 0; msync_(m); } }
static void sh_IsMenuCommandEnabled(PPC *c)
{
	Item *it = find_command(A(0), A(1), NULL);
	RET(it ? it->enabled : A(1) == 'quit');
}

static void sh_MenuSelect(PPC *c)
{
	// MenuSelect(Point startPt): the choice made in the Cocoa menu bar
	(void)c;
	menu_flush();
	if (ev_last.part == 1 && !ev_last.win && ev_last.data) {
		uint32_t d = ev_last.data;
		ev_last.data = 0;
		RET(d);
		return;
	}
	RET(0);
}

int menu_key(uint8_t ch, uint16_t mods)
{
	(void)mods;
	uint8_t u = (uint8_t)toupper(ch);
	for (int b = 0; b < nbar; b++) {
		Menu *m = bar[b];
		if (!m->enabled)
			continue;
		for (int i = 0; i < m->n; i++) {
			Item *it = &m->items[i];
			if (it->cmd && it->cmd != 0x1b && toupper(it->cmd) == u)
				return it->enabled ? (int)((uint32_t)(uint16_t)m->id << 16 | (uint32_t)(i + 1)) : 0;
		}
	}
	return 0;
}
static void sh_MenuKey(PPC *c) { RET(menu_key((uint8_t)A(0), 0x100)); }
static void sh_MenuEvent(PPC *c)
{
	uint32_t e = A(0);
	uint16_t mods = LD16(e + 14);
	if (!(mods & 0x100)) {
		RET(0);
		return;
	}
	RET(menu_key((uint8_t)LD32(e + 2), mods));
}
static void sh_PopUpMenuSelect(PPC *c)
{
	// PopUpMenuSelect(menu, top, left, popUpItem)
	Menu *m = M(A(0));
	if (!m) {
		RET(0);
		return;
	}
	QPoint g = {(int16_t)A(1), (int16_t)A(2)};
	int item = menu_popup(m->h, g, (int16_t)A(3), 0, NULL);
	void ev_drop_mouseups(void);
	ev_drop_mouseups();
	RET(item ? (uint32_t)(uint16_t)m->id << 16 | (uint32_t)item : 0);
}
static void sh_HMGetHelpMenu(PPC *c)
{
	// HMGetHelpMenu(MenuRef *, MenuItemIndex *firstCustomItem)
	if (!help_menu) {
		static const uint8_t t[] = {4, 'H', 'e', 'l', 'p'};
		help_menu = menu_new(help_id, t);
		bar[nbar++] = help_menu;
		help_menu->inserted = 1;
		dirty = 1;
	}
	if (A(0))
		ST32(A(0), help_menu->h);
	if (A(1))
		ST16(A(1), (uint16_t)(help_menu->n + 1));
	RET(0);
}
static void sh_SetMenuTitle(PPC *c) { Menu *m = M(A(0)); if (m) { memcpy(m->title, G(A(1)), LD8(A(1)) + 1); msync_(m); } }
static void sh_CalcMenuSize(PPC *c) { (void)c; }

static const ShimDef menushims[] = {
	S(GetMenu), S(NewMenu), S(GetMenuHandle), S(GetMenuID), S(InsertMenu), S(DeleteMenu), S(DisposeMenu),
	S(DrawMenuBar), S(InvalMenuBar), S(HiliteMenu), S(FlashMenuBar), S(GetMBarHeight), S(ClearMenuBar),
	S(AppendMenu), S(InsertMenuItem), S(DeleteMenuItem), S(CountMenuItems), S(AppendResMenu), S(InsertResMenu),
	S(EnableMenuItem), S(DisableMenuItem), S(IsMenuItemEnabled), S(CheckMenuItem), S(SetItemMark), S(GetItemMark),
	S(SetItemCmd), S(GetItemCmd), S(SetItemStyle), S(SetMenuItemText), S(GetMenuItemText), S(SetMenuItemCommandID),
	S(GetMenuItemCommandID), S(EnableMenuCommand), S(DisableMenuCommand), S(IsMenuCommandEnabled), S(MenuSelect),
	S(MenuKey), S(MenuEvent), S(PopUpMenuSelect), S(HMGetHelpMenu), S(SetMenuTitle), S(CalcMenuSize),
	{"MacAppendMenu", sh_AppendMenu}, {"MacInsertMenu", sh_InsertMenu}, {"MacDeleteMenu", sh_DeleteMenu},
	{"EnableMenuItemIcon", sh_HiliteMenu}, {"CountMItems", sh_CountMenuItems}, {"EnableItem", sh_EnableMenuItem},
	{"DisableItem", sh_DisableMenuItem}, {"GetMenuItemTextWithCFString", sh_HiliteMenu},
};
REGISTER(menushims)
