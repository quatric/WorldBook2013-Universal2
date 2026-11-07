// A styled text engine with TextEdit's behavior: TEHandles, edit text
// controls and MLTE objects all edit through it.
#ifndef TE_H
#define TE_H
#include "qd.h"

typedef struct { int start; int16_t font, size; uint8_t face; RGB16 color; } TRun;

typedef struct TEng {
	Port *port;
	QRect dest, view;
	uint8_t *t;
	int n, cap;
	TRun *runs;
	int nruns, capruns;
	int styled;
	int selStart, selEnd, anchor;
	int *ls, *lh, *la;     // line starts (ls[nl] = n), heights, ascents
	int nl, capl;
	int just;              // 0 left, 1 center, -1 right, -2 left
	int active, caret_vis;
	uint32_t caret_tick;
	int wrap, readonly, password, outline_hilite, autoview;
	int font, size, face;  // the style of an unstyled engine
	RGB16 color;
	TRun null_style;
	int has_null_style;
	uint32_t click_tick;
	int click_count, click_off;
	uint32_t teh;          // the guest TEHandle, if any
	int lineHeight, fontAscent;   // unstyled metrics
	// one level of undo
	uint8_t *u_t;
	int u_n;
	TRun *u_runs;
	int u_nruns, u_sel0, u_sel1, has_undo, redo, typing;
	void (*on_change)(struct TEng *);
	void *owner;
	RGB16 bg;              // the background, if has_bg (else the port's)
	int has_bg;
} TEng;

TEng *te_create(Port *port, QRect dest, QRect view, int styled);
void te_dispose(TEng *e);
void te_layout(TEng *e);
void te_set_text(TEng *e, const void *s, int n);
void te_set_select(TEng *e, int a, int b);
void te_insert(TEng *e, const uint8_t *s, int n, const TRun *runs, int nruns);
void te_delete_sel(TEng *e);
void te_key(TEng *e, uint8_t ch, uint16_t mods);
void te_click(TEng *e, QPoint pt, int extend);
void te_draw(TEng *e, const Rgn *area);
void te_idle(TEng *e);
void te_activate(TEng *e, int on);
void te_set_rects(TEng *e, QRect dest, QRect view);
void te_restyle_all(TEng *e);
void te_scroll(TEng *e, int dh, int dv);
void te_sel_view(TEng *e);
int te_height(TEng *e, int from_line, int to_line);
int te_total_height(TEng *e);
QPoint te_point(TEng *e, int off);   // the bottom-left of the character (TEGetPoint)
int te_offset_at(TEng *e, QPoint pt);
int te_line_of(TEng *e, int off);
void te_copy(TEng *e);
void te_paste(TEng *e);
void te_set_style(TEng *e, int mode, int font, int face, int size, RGB16 color, int redraw);
TRun te_style_at(TEng *e, int off);
int te_continuous(TEng *e, int *mode, TRun *out);
void te_undo(TEng *e);
void te_snapshot(TEng *e);
uint32_t te_handle(TEng *e);   // a guest TEHandle for the engine
double te_line_width(TEng *e, int line);
void te_style_metrics(TRun *r, int *asc, int *desc, int *lead);

#endif
