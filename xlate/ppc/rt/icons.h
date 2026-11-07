// Icon Utilities: cicn, icon families and IconRefs.
#ifndef ICONS_H
#define ICONS_H
#include "qd.h"

void icon_plot_id(Port *p, QRect r, int align, int transform, int16_t id);
void icon_plot_cicn(Port *p, QRect r, uint32_t cicn);
void icon_plot_suite(Port *p, QRect r, int align, int transform, uint32_t suite);
void icon_plot_ref(Port *p, QRect r, uint32_t ref);
uint32_t cicn_get(int16_t id);

#endif
