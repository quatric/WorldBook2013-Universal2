// The standard Macintosh color tables and the classic QuickDraw colors.
#include "qd.h"

static const uint8_t ramp[10] = {0xee, 0xdd, 0xbb, 0xaa, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11};

uint8_t mac_clut8[256][3];
const uint8_t mac_clut4[16][3] = {
	{0xff, 0xff, 0xff}, {0xfc, 0xf3, 0x05}, {0xff, 0x64, 0x02}, {0xdd, 0x08, 0x06},
	{0xf2, 0x08, 0x84}, {0x46, 0x00, 0xa5}, {0x00, 0x00, 0xd4}, {0x02, 0xab, 0xea},
	{0x1f, 0xb7, 0x14}, {0x00, 0x64, 0x11}, {0x56, 0x2c, 0x05}, {0x90, 0x71, 0x3a},
	{0xc0, 0xc0, 0xc0}, {0x80, 0x80, 0x80}, {0x40, 0x40, 0x40}, {0x00, 0x00, 0x00},
};

__attribute__((constructor)) static void init_clut8(void)
{
	for (int i = 0; i < 215; i++) {
		mac_clut8[i][0] = (uint8_t)(0x33 * (5 - i / 36));
		mac_clut8[i][1] = (uint8_t)(0x33 * (5 - (i / 6) % 6));
		mac_clut8[i][2] = (uint8_t)(0x33 * (5 - i % 6));
	}
	for (int k = 0; k < 10; k++) {
		uint8_t v = ramp[k];
		mac_clut8[215 + k][0] = v;
		mac_clut8[225 + k][1] = v;
		mac_clut8[235 + k][2] = v;
		mac_clut8[245 + k][0] = mac_clut8[245 + k][1] = mac_clut8[245 + k][2] = v;
	}
	mac_clut8[255][0] = mac_clut8[255][1] = mac_clut8[255][2] = 0;
}

// ForeColor/BackColor constants of the original QuickDraw
void qd_classic_color(int32_t k, RGB16 *out)
{
	RGB16 c = {0, 0, 0};
	switch (k) {
	case 30: c = (RGB16){0xffff, 0xffff, 0xffff}; break;       // white
	case 205: c = (RGB16){0xdd6b, 0x08c2, 0x06a2}; break;      // red
	case 341: c = (RGB16){0x0000, 0x8000, 0x11b0}; break;      // green
	case 409: c = (RGB16){0x0000, 0x0000, 0xd400}; break;      // blue
	case 273: c = (RGB16){0x0241, 0xab54, 0xeafe}; break;      // cyan
	case 137: c = (RGB16){0xf2d7, 0x0856, 0x84ec}; break;      // magenta
	case 69: c = (RGB16){0xfc00, 0xf37d, 0x052f}; break;       // yellow
	default: break;                                            // black (33) and the rest
	}
	*out = c;
}
