// Control Manager: Appearance controls drawn with HITheme into the window's port.
#ifndef CTL_H
#define CTL_H
#include "win.h"

enum CtlKind {
	K_PUSH, K_CHECK, K_RADIO, K_BEVEL, K_POPUP, K_SCROLL, K_SLIDER, K_PROGRESS, K_ARROWS, K_CHASING, K_TABS,
	K_SEPARATOR, K_GROUP, K_IMAGEWELL, K_PLACARD, K_USERPANE, K_EDITTEXT, K_STATICTEXT, K_PICTURE, K_ICON,
	K_HEADER, K_LISTBOX, K_TRIANGLE, K_DISCLOSURE, K_ROUND, K_NULL, K_CUSTOM, K_CLOCK, K_RADIOGROUP, K_POPUPARROW,
};

typedef struct Ctl {
	uint32_t h;                // ControlHandle (a guest handle to a ControlRecord)
	Win *win;
	struct Ctl *parent, *child, *next;   // embedding
	int kind, procID, variant;
	QRect r;
	int16_t value, min, max;
	int visible, hilite, active, enabled;
	uint32_t refCon, action, viewSize;
	uint8_t title[256];
	// font style (SetControlFontStyle)
	int fs_flags, fs_font, fs_size, fs_style, fs_just;
	RGB16 fs_fore, fs_back;
	// kind data
	int16_t menuID;
	uint32_t menu;             // MenuHandle of a popup or bevel menu
	int menu_value;            // the bevel button's menu choice
	int behavior, content;     // bevel buttons
	uint32_t content_h;        // icon / picture / IconRef handle
	int content_id;
	int is_default, is_cancel;
	int pushed;                // tracking feedback
	uint32_t procs[8];         // user pane procedures: draw hitTest tracking idle keyDown activate focus background
	uint32_t defproc;          // CreateCustomControl definition (transition vector)
	uint32_t text;             // static text: a guest handle with the text
	struct TEng *te;           // edit text
	int focus;                 // keyboard focus part
	int indeterminate;
	int tab_count;
	uint8_t (*tab_titles)[256];
	int tab_pos;
	int title_width, title_just, title_style;
	int live;                  // live scrolling
	uint32_t color_proc;
} Ctl;

Ctl *CTL(uint32_t h);
void ctl_dispose_all(Win *w);
void ctl_draw(Ctl *c);
void ctl_draw_window(Win *w);

#endif
