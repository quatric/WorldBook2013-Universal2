// QuickDraw pictures: drawing PICT data, recording with OpenPicture.
#ifndef PICT_H
#define PICT_H
#include "qd.h"

typedef struct QDPict {
	Port *shadow;     // what was drawn while recording
	QRect frame;
	uint32_t h;
} QDPict;

void pict_draw(Port *p, const uint8_t *data, uint32_t len, QRect dst);
void pict_mirror_fill(Port *p, const Rgn *shape, Paint pt);
void pict_mirror_text(Port *p, const uint8_t *s, int n);
void pict_mirror_copybits(Port *p, uint32_t src, QRect sr, QRect dr, int mode, Rgn *mask);
// a picture as an image (for the clipboard), NULL if it cannot be drawn
CGImageRef pict_image(const uint8_t *data, uint32_t len);

void rgnrec_move(Port *p);
void rgnrec_line(Port *p, QPoint to);
void rgnrec_shape(Port *p, Rgn *g);

#endif
