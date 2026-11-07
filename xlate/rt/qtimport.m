// QuickTime graphics importers and QuickDraw GWorlds over pixel buffers, on ImageIO and
// Core Graphics (both gone from 64-bit macOS).
//
// The media library decodes pictures this way: an importer opened for 'grip'
// (JPEG, GIF) takes the picture as a Handle, says whether it can read it, reports
// its ImageDescription or natural bounds, and draws it, optionally through a
// scaling matrix, into a GWorld made around the caller's own 32-bit ARGB buffer.
// Importers and GWorlds are host objects behind handles; Handles are the guest's
// (shims.m: a block of pointer and size).
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "rt.h"

#define A(i) xl_arg(c, i)
#define U32(a) (*(uint32_t *)GP(a))
#define S16(a) (*(int16_t *)GP(a))

typedef int32_t Fixed32;

@interface XLImporter : NSObject {
@public
	CGImageRef image;
	uint32_t gworld;          // handle of the XLGWorld to draw into
	double m[3][3];           // matrix: x' = x*m00 + y*m10 + m20, y' = x*m01 + y*m11 + m21
}
@end
@implementation XLImporter
- (void)dealloc
{
	CGImageRelease(image);
	[super dealloc];
}
@end

@interface XLGWorld : NSObject {
@public
	uint32_t buf, rowBytes;
	int16_t top, left, bottom, right;
	uint32_t format;
}
@end
@implementation XLGWorld
@end

static XLMap importers;   // handle -> 1

static void identity(double m[3][3])
{
	memset(m, 0, 9 * sizeof(double));
	m[0][0] = m[1][1] = m[2][2] = 1;
}

uint32_t xl_gi_open(uint32_t subtype)
{
	(void)subtype;   // one importer reads every format ImageIO knows
	XLImporter *im = [XLImporter new];
	identity(im->m);
	uint32_t h = xl_h(im);
	xl_map_put(&importers, h, 1);
	return h;
}

int xl_gi_close(uint32_t h)
{
	if (!xl_map_get(&importers, h))
		return 0;
	xl_map_del(&importers, h);
	[(XLImporter *)xl_p(h) release];
	return 1;
}

static XLImporter *I(uint32_t h) { return xl_map_get(&importers, h) ? (XLImporter *)xl_p(h) : nil; }

// GraphicsImportSetDataHandle(ci, Handle)
static void sh_SetDataHandle(XLCPU *c)
{
	XLImporter *im = I(A(0));
	uint32_t h = A(1);
	if (!im || !h) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	CGImageRelease(im->image);
	im->image = NULL;
	uint32_t p = U32(h), n = U32(h + 4);
	NSData *d = [NSData dataWithBytes:GP(p) length:n];
	CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)d, NULL);
	if (src) {
		im->image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
		CFRelease(src);
	}
	xl_ret(c, 0);
}

// GraphicsImportValidate(ci, Boolean *valid)
static void sh_Validate(XLCPU *c)
{
	XLImporter *im = I(A(0));
	if (A(1))
		*(uint8_t *)GP(A(1)) = im && im->image ? 1 : 0;
	xl_ret(c, 0);
}

// GraphicsImportGetNaturalBounds(ci, Rect *)
static void sh_GetNaturalBounds(XLCPU *c)
{
	XLImporter *im = I(A(0));
	uint32_t r = A(1);
	if (!im || !im->image || !r) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	S16(r) = 0;
	S16(r + 2) = 0;
	S16(r + 4) = (int16_t)CGImageGetHeight(im->image);
	S16(r + 6) = (int16_t)CGImageGetWidth(im->image);
	xl_ret(c, 0);
}

// GraphicsImportGetImageDescription(ci, ImageDescriptionHandle *): a new handle
// with the ImageDescription (86 bytes; width +0x20, height +0x22, depth +0x52)
static void sh_GetImageDescription(XLCPU *c)
{
	XLImporter *im = I(A(0));
	if (!im || !im->image || !A(1)) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	uint32_t h = xl_malloc(8), p = xl_calloc(86);
	U32(h) = p;
	U32(h + 4) = 86;
	*(int32_t *)GP(p) = 86;
	*(uint32_t *)GP(p + 4) = 'jpeg';
	S16(p + 0x20) = (int16_t)CGImageGetWidth(im->image);
	S16(p + 0x22) = (int16_t)CGImageGetHeight(im->image);
	*(int32_t *)GP(p + 0x24) = 72 << 16;
	*(int32_t *)GP(p + 0x28) = 72 << 16;
	S16(p + 0x30) = 1;
	CGImageAlphaInfo ai = CGImageGetAlphaInfo(im->image);
	int alpha = ai != kCGImageAlphaNone && ai != kCGImageAlphaNoneSkipFirst && ai != kCGImageAlphaNoneSkipLast;
	S16(p + 0x52) = alpha ? 32 : 24;
	S16(p + 0x54) = -1;
	U32(A(1)) = h;
	xl_ret(c, 0);
}

// NewGWorldFromPtr(GWorldPtr *, OSType pixelFormat, const Rect *, CTabHandle, GDHandle, flags, Ptr, long rowBytes)
static void sh_NewGWorldFromPtr(XLCPU *c)
{
	uint32_t out = A(0), r = A(2);
	if (!out || !r || !A(6)) {
		xl_ret(c, (uint32_t)(uint16_t)-50);
		return;
	}
	XLGWorld *gw = [XLGWorld new];
	gw->format = A(1);
	gw->top = S16(r);
	gw->left = S16(r + 2);
	gw->bottom = S16(r + 4);
	gw->right = S16(r + 6);
	gw->buf = A(6);
	gw->rowBytes = A(7) & 0x3fffffff;
	U32(out) = xl_h(gw);
	xl_ret(c, 0);
}

static void sh_DisposeGWorld(XLCPU *c)
{
	if (A(0))
		[(XLGWorld *)xl_p(A(0)) release];
	xl_ret(c, 0);
}

// GraphicsImportSetGWorld(ci, CGrafPtr, GDHandle)
static void sh_SetGWorld(XLCPU *c)
{
	XLImporter *im = I(A(0));
	if (im)
		im->gworld = A(1);
	xl_ret(c, im ? 0 : (uint32_t)-50);
}

// MatrixRecord: 3x3 of Fixed (16.16), the last column Fract (2.30)
static void matrix_in(uint32_t g, double m[3][3])
{
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++) {
			int32_t v = *(int32_t *)GP(g + 4 * (3 * i + j));
			m[i][j] = j == 2 ? v / (double)(1 << 30) : v / 65536.0;
		}
}

static void matrix_out(double m[3][3], uint32_t g)
{
	for (int i = 0; i < 3; i++)
		for (int j = 0; j < 3; j++)
			*(int32_t *)GP(g + 4 * (3 * i + j)) = (int32_t)lround(j == 2 ? m[i][j] * (1 << 30) : m[i][j] * 65536.0);
}

static void sh_SetMatrix(XLCPU *c)
{
	XLImporter *im = I(A(0));
	if (im) {
		if (A(1))
			matrix_in(A(1), im->m);
		else
			identity(im->m);
	}
	xl_ret(c, im ? 0 : (uint32_t)-50);
}

static void sh_SetIdentityMatrix(XLCPU *c)
{
	double m[3][3];
	identity(m);
	if (A(0))
		matrix_out(m, A(0));
	xl_ret(c, 0);
}

// ScaleMatrix(MatrixRecord *, Fixed sx, Fixed sy, Fixed aboutX, Fixed aboutY)
static void sh_ScaleMatrix(XLCPU *c)
{
	double m[3][3];
	matrix_in(A(0), m);
	double sx = (int32_t)A(1) / 65536.0, sy = (int32_t)A(2) / 65536.0;
	double ax = (int32_t)A(3) / 65536.0, ay = (int32_t)A(4) / 65536.0;
	// m * T(-a) S T(a): applied to the columns of x and y
	for (int i = 0; i < 3; i++) {
		m[i][0] = (m[i][0] - ax * m[i][2]) * sx + ax * m[i][2];
		m[i][1] = (m[i][1] - ay * m[i][2]) * sy + ay * m[i][2];
	}
	matrix_out(m, A(0));
	xl_ret(c, 0);
}

// Fixed X2Fix(double)
static void sh_X2Fix(XLCPU *c)
{
	double d;
	memcpy(&d, GP(c->r[ESP] + 4), 8);
	xl_ret(c, (uint32_t)(int32_t)lround(d * 65536.0));
}

// GraphicsImportDraw(ci): the picture through the matrix into the GWorld's pixels
static void sh_Draw(XLCPU *c)
{
	XLImporter *im = I(A(0));
	XLGWorld *gw = im && im->gworld ? (XLGWorld *)xl_p(im->gworld) : nil;
	if (!im || !im->image || !gw) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	size_t w = (size_t)(gw->right - gw->left), h = (size_t)(gw->bottom - gw->top);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	// k32ARGBPixelFormat: A R G B in memory; k32BGRAPixelFormat: B G R A
	CGBitmapInfo bi = gw->format == 'BGRA' ? (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
		: (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
	CGContextRef ctx = CGBitmapContextCreate(GP(gw->buf), w, h, 8, gw->rowBytes, cs, bi);
	CGColorSpaceRelease(cs);
	if (!ctx) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	double iw = (double)CGImageGetWidth(im->image), ih = (double)CGImageGetHeight(im->image);
	// QuickDraw's y grows downwards: the image rect after the matrix, flipped
	double x0 = im->m[2][0] - gw->left, y0 = im->m[2][1] - gw->top;
	double dw = iw * im->m[0][0], dh = ih * im->m[1][1];
	CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
	CGContextDrawImage(ctx, CGRectMake(x0, (double)h - y0 - dh, dw, dh), im->image);
	CGContextRelease(ctx);
	xl_ret(c, 0);
}

static const struct { const char *name; XLShim fn; } qt_shims[] = {
	{"_GraphicsImportSetDataHandle", sh_SetDataHandle},
	{"_GraphicsImportValidate", sh_Validate},
	{"_GraphicsImportGetNaturalBounds", sh_GetNaturalBounds},
	{"_GraphicsImportGetImageDescription", sh_GetImageDescription},
	{"_GraphicsImportSetGWorld", sh_SetGWorld},
	{"_GraphicsImportSetMatrix", sh_SetMatrix},
	{"_GraphicsImportDraw", sh_Draw},
	{"_NewGWorldFromPtr", sh_NewGWorldFromPtr},
	{"_DisposeGWorld", sh_DisposeGWorld},
	{"_SetIdentityMatrix", sh_SetIdentityMatrix},
	{"_ScaleMatrix", sh_ScaleMatrix},
	{"_X2Fix", sh_X2Fix},
	{NULL, NULL},
};

XLShim xl_find_qt_shim(const char *name)
{
	for (int i = 0; qt_shims[i].name; i++)
		if (!strcmp(qt_shims[i].name, name))
			return qt_shims[i].fn;
	return NULL;
}
