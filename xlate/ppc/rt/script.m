// Scripted input for testing without the real mouse and keyboard.
//
// PPC_SCRIPT="t:cmd;t:cmd;..." with t seconds after start and cmd one of
//   click x y [mods]    a click at window-local x, y of the front window
//   down x y / move x y / up    a press, drag and release
//   key c [mods]        a key (c a character, or a name: return tab esc left right up down del)
//   shot file           the front window's pixels as a PNG
//   menu id item        a menu choice
//   quit
// mods: any of cmd shift opt ctrl, joined with +
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "win.h"

typedef struct { double t; char cmd[256]; } Step;
static Step *steps;
static int nsteps, next_step, loaded;
static double t_start;
static int fake, fake_down;
static QPoint fake_pos;

static void load(void)
{
	loaded = 1;
	const char *s = getenv("PPC_SCRIPT");
	if (!s)
		return;
	t_start = CFAbsoluteTimeGetCurrent();
	char *dup = strdup(s), *save = NULL;
	for (char *tok = strtok_r(dup, ";", &save); tok; tok = strtok_r(NULL, ";", &save)) {
		char *colon = strchr(tok, ':');
		if (!colon)
			continue;
		steps = realloc(steps, sizeof(Step) * (nsteps + 1));
		steps[nsteps].t = atof(tok);
		snprintf(steps[nsteps].cmd, sizeof steps[nsteps].cmd, "%s", colon + 1);
		nsteps++;
	}
	free(dup);
}

int script_mouse(QPoint *p)
{
	if (!fake)
		return 0;
	*p = fake_pos;
	return 1;
}
int script_button(int *down)
{
	if (!fake)
		return 0;
	*down = fake_down;
	return 1;
}

static uint16_t mods_of(const char *s)
{
	uint16_t m = 0;
	if (!s)
		return 0;
	if (strstr(s, "cmd")) m |= 0x100;
	if (strstr(s, "shift")) m |= 0x200;
	if (strstr(s, "opt")) m |= 0x800;
	if (strstr(s, "ctrl")) m |= 0x1000;
	return m;
}

static Win *front(void) { return win_front(1); }

static QPoint global_of(int x, int y)
{
	Win *w = front();
	QPoint o = w ? win_origin(w) : (QPoint){0, 0};
	int l = w ? w->port->portRect.left : 0, t = w ? w->port->portRect.top : 0;
	return (QPoint){(int16_t)(o.v + y - t), (int16_t)(o.h + x - l)};
}

static void mouse(int what, QPoint g, uint16_t mods)
{
	Ev e = {0};
	e.what = (uint16_t)what;
	e.where = g;
	e.modifiers = mods | (what == 2 ? 0x80 : 0);
	e.win = win_at(g.h, g.v);
	ev_post(e);
}

static void shot(const char *file)
{
	Win *w = front();
	if (!w || !w->port || !w->port->pix)
		return;
	Port *p = w->port;
	int wd = p->bounds.right - p->bounds.left, ht = p->bounds.bottom - p->bounds.top;
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, G(p->pix), (size_t)p->rowBytes * ht, NULL);
	CGImageRef img = CGImageCreate(wd, ht, 8, 32, p->rowBytes, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big, dp, NULL,
		false, kCGRenderingIntentDefault);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)file, (CFIndex)strlen(file), false);
	CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(d, img, NULL);
	CGImageDestinationFinalize(d);
	CFRelease(d);
	CFRelease(url);
	CGImageRelease(img);
	CGDataProviderRelease(dp);
	CGColorSpaceRelease(cs);
	ppc_log("script: shot %s (%s)", file, w->title + 1);
}

static void run(const char *cmd)
{
	char op[32] = {0}, a[200] = {0}, b[32] = {0}, m[64] = {0};
	sscanf(cmd, "%31s %199s %31s %63s", op, a, b, m);
	if (ppc_verbose)
		ppc_log("script: %s", cmd);
	if (!strcmp(op, "click") || !strcmp(op, "down")) {
		fake = 1;
		fake_pos = global_of(atoi(a), atoi(b));
		fake_down = 1;
		mouse(1, fake_pos, mods_of(m));
		if (!strcmp(op, "click")) {
			// released at the next step of the pump
			fake_down = 2;
		}
	} else if (!strcmp(op, "move")) {
		fake = 1;
		fake_pos = global_of(atoi(a), atoi(b));
	} else if (!strcmp(op, "up")) {
		fake_down = 0;
		mouse(2, fake_pos, 0);
	} else if (!strcmp(op, "key")) {
		static const struct { const char *n; uint8_t c, code; } names[] = {
			{"return", 13, 36}, {"tab", 9, 48}, {"esc", 27, 53}, {"left", 28, 123}, {"right", 29, 124},
			{"up", 30, 126}, {"down", 31, 125}, {"del", 8, 51}, {"space", 32, 49},
		};
		uint8_t ch = (uint8_t)a[0], code = 0;
		for (size_t i = 0; i < sizeof names / sizeof *names; i++)
			if (!strcmp(a, names[i].n)) {
				ch = names[i].c;
				code = names[i].code;
			}
		uint16_t mods = mods_of(b);
		if (mods & 0x100) {
			int r = menu_key(ch, mods);
			if (r) {
				Ev e = {0};
				e.what = 1;
				e.where = (QPoint){5, 5};
				e.part = 1;
				e.data = (uint32_t)r;
				ev_post(e);
				return;
			}
		}
		Ev e = {0};
		e.what = 3;
		e.message = ch | (uint32_t)code << 8;
		e.modifiers = mods | 0x80;
		e.win = front();
		e.where = fake ? fake_pos : ev_mouse_global();
		ev_post(e);
	} else if (!strcmp(op, "menu")) {
		Ev e = {0};
		e.what = 1;
		e.where = (QPoint){5, 5};
		e.part = 1;
		e.data = (uint32_t)(uint16_t)atoi(a) << 16 | (uint16_t)atoi(b);
		ev_post(e);
	} else if (!strcmp(op, "shot"))
		shot(a);
	else if (!strcmp(op, "quit"))
		exit(0);
}

void script_tick(void)
{
	if (!loaded)
		load();
	if (fake_down == 2)
		fake_down = 3;           // pressed for one pump
	else if (fake_down == 3) {
		fake_down = 0;
		mouse(2, fake_pos, 0);
	}
	if (next_step >= nsteps)
		return;
	double now = CFAbsoluteTimeGetCurrent() - t_start;
	while (next_step < nsteps && steps[next_step].t <= now)
		run(steps[next_step++].cmd);
}
