// Toolbox start-up: files, resources, QuickDraw, the menu bar, and the
// 'oapp' Apple event a launched application receives first.
#import <AppKit/AppKit.h>
#include "win.h"

void fs_init(void);
void res_init(const char *app_rsrc);

void toolbox_init(void)
{
	fs_init();
	res_init(ppc_app_path);
	qd_init();
	menu_bar_install();
	Ev e = {0};
	e.what = 23;   // kHighLevelEvent
	e.message = 'aevt';
	e.where = (QPoint){(int16_t)('oapp' >> 16), (int16_t)('oapp' & 0xffff)};
	ev_post(e);
}
