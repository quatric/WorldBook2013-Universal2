// Menu Manager: guest MenuHandles shown as NSMenus.
#ifndef MENU_H
#define MENU_H
#include "win.h"

uint32_t menu_get_handle(int16_t id);     // an inserted menu (menu bar or hierarchical)
uint32_t menu_load(int16_t id);           // from a MENU resource
int menu_count(uint32_t menu);
void menu_item_text(uint32_t menu, int item, uint8_t *pstr);
int16_t menu_id(uint32_t menu);
void menu_flush(void);                    // rebuild the menu bar if it changed
#ifdef __OBJC__
#import <CoreText/CoreText.h>
// a popup menu at a global point; returns the chosen item or 0
int menu_popup(uint32_t menu, QPoint global, int cur, int width, CTFontRef font);
#endif

#endif
