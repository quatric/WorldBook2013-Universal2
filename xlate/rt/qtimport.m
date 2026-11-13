// QuickTime graphics importers and QuickDraw GWorlds over pixel buffers, on ImageIO and
// Core Graphics (both gone from 64-bit macOS).
//
// The media library decodes pictures this way: an importer opened for 'grip'
// (JPEG, GIF) takes the picture as a Handle, says whether it can read it, reports
// its ImageDescription or natural bounds, and draws it, optionally through a
// scaling matrix, into a GWorld made around the caller's own 32-bit ARGB buffer.
// Importers and GWorlds are host objects behind handles; Handles are the guest's
// (shims.m: a block of pointer and size).
//
// The home screen's moving pictures are QuickTime movies read sample by sample
// (SMKGLKit's GLMovieEffect): GetMediaSample hands the codec the compressed
// frame, DecompressSequenceFrameWhen decodes it into the texture's GWorld. Here a
// Movie is an XLMovie on an AVAsset, its tracks XLTracks (a Track and its Media
// are one handle), and the "sample" GetMediaSample returns is a 16-byte token
// (movie, media time) that DecompressSequenceFrameWhen turns into a decoded
// frame from an AVAssetReader.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <pthread.h>
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

// ---- movies --------------------------------------------------------------------------------
static XLMap qt_objects;   // handle -> 'm' (XLMovie), 't' (XLTrack), 's' (XLSequence)
static pthread_mutex_t qt_lock = PTHREAD_MUTEX_INITIALIZER;   // the preloading thread and the main thread both come here
static void qt_forget(uint32_t h);

@interface XLMovie : NSObject {
@public
	AVAsset *asset;
	AVAssetTrack *video;
	NSMutableArray *tracks;      // XLTrack, in track order; DisposeMovieTrack removes
	int32_t timescale, duration, frameDur, sampleCount;
	int width, height;
	AVAssetReader *reader;
	AVAssetReaderTrackOutput *out;
	CMSampleBufferRef cur, next;
	int64_t curPTS, nextPTS;
}
@end

@interface XLTrack : NSObject {
@public
	XLMovie *movie;   // not retained: the movie owns its tracks
	uint32_t kind;    // 'vide' or 'soun'
}
@end
@implementation XLTrack
@end

@implementation XLMovie
- (instancetype)initWithURL:(NSURL *)url
{
	if (!(self = [super init]))
		return nil;
	asset = [[AVURLAsset URLAssetWithURL:url options:nil] retain];
	tracks = [NSMutableArray new];
	video = [[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject] retain];
	if (video) {
		XLTrack *t = [XLTrack new];
		t->movie = self;
		t->kind = 'vide';
		[tracks addObject:t];
		[t release];
		CGSize n = CGSizeApplyAffineTransform([video naturalSize], [video preferredTransform]);
		width = (int)lround(fabs(n.width));
		height = (int)lround(fabs(n.height));
		timescale = [video naturalTimeScale] > 0 ? [video naturalTimeScale] : 600;
		CMTime d = [video timeRange].duration;
		duration = (int32_t)CMTimeConvertScale(d, timescale, kCMTimeRoundingMethod_RoundTowardZero).value;
		float fps = [video nominalFrameRate] > 0 ? [video nominalFrameRate] : 30;
		frameDur = (int32_t)lround(timescale / fps);
		if (frameDur < 1)
			frameDur = 1;
		sampleCount = (int32_t)lround(CMTimeGetSeconds(d) * fps);
		if (sampleCount < 1)
			sampleCount = 1;
	}
	if ([[asset tracksWithMediaType:AVMediaTypeAudio] count]) {
		XLTrack *t = [XLTrack new];
		t->movie = self;
		t->kind = 'soun';
		[tracks addObject:t];
		[t release];
	}
	if (xl_verbose > 0)
		xl_log("QuickTime movie %s: %dx%d, %d tracks, timescale %d, duration %d, frame %d", [[url lastPathComponent] UTF8String], width,
			height, (int)[tracks count], timescale, duration, frameDur);
	return self;
}

- (void)stopReading
{
	if (cur)
		CFRelease(cur);
	if (next)
		CFRelease(next);
	cur = next = NULL;
	[reader cancelReading];
	[reader release];
	reader = nil;
	[out release];
	out = nil;
}

- (void)dealloc
{
	[self stopReading];
	for (XLTrack *t in tracks)
		qt_forget(xl_h(t));
	qt_forget(xl_h(self));
	[tracks release];
	[video release];
	[asset release];
	[super dealloc];
}

- (int64_t)ptsOf:(CMSampleBufferRef)b
{
	return CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(b), timescale, kCMTimeRoundingMethod_RoundTowardZero).value;
}

- (CMSampleBufferRef)copyNextFrame
{
	for (;;) {
		CMSampleBufferRef b = [out copyNextSampleBuffer];
		if (!b)
			return NULL;
		if (CMSampleBufferGetImageBuffer(b))
			return b;
		CFRelease(b);
	}
}

- (void)restartAt:(int64_t)t
{
	[self stopReading];
	NSError *e = nil;
	reader = [[AVAssetReader alloc] initWithAsset:asset error:&e];
	if (!reader)
		return;
	out = [[AVAssetReaderTrackOutput alloc] initWithTrack:video
		outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
	[out setAlwaysCopiesSampleData:NO];
	[reader addOutput:out];
	CMTime from = CMTimeMake(t, timescale);
	[reader setTimeRange:CMTimeRangeFromTimeToTime(from, [asset duration])];
	if (![reader startReading]) {
		[self stopReading];
		return;
	}
	cur = [self copyNextFrame];
	next = cur ? [self copyNextFrame] : NULL;
	curPTS = cur ? [self ptsOf:cur] : 0;
	nextPTS = next ? [self ptsOf:next] : 0;
}

// the frame shown at media time t (the last one at or before it), as BGRA pixels
// copied into a 32-bit ARGB (A R G B in memory) buffer at its top left corner
- (BOOL)drawFrameAt:(int64_t)t into:(uint8_t *)dst rowBytes:(size_t)rb width:(size_t)w height:(size_t)h
{
	@synchronized(self) {
		if (!video)
			return NO;
		if (!reader || !cur || t < curPTS)
			[self restartAt:t];
		while (cur && next && nextPTS <= t) {
			CFRelease(cur);
			cur = next;
			curPTS = nextPTS;
			next = [self copyNextFrame];
			nextPTS = next ? [self ptsOf:next] : 0;
		}
		CVImageBufferRef ib = cur ? CMSampleBufferGetImageBuffer(cur) : NULL;
		if (!ib)
			return NO;
		CVPixelBufferLockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);
		const uint8_t *src = CVPixelBufferGetBaseAddress(ib);
		size_t srb = CVPixelBufferGetBytesPerRow(ib);
		size_t cw = MIN(w, CVPixelBufferGetWidth(ib)), ch = MIN(h, CVPixelBufferGetHeight(ib));
		for (size_t y = 0; y < ch; y++) {
			const uint8_t *s = src + y * srb;
			uint8_t *d = dst + y * rb;
			for (size_t x = 0; x < cw; x++, s += 4, d += 4) {
				d[0] = 0xff;
				d[1] = s[2];
				d[2] = s[1];
				d[3] = s[0];
			}
		}
		CVPixelBufferUnlockBaseAddress(ib, kCVPixelBufferLock_ReadOnly);
	}
	return YES;
}
@end

id xl_qt_movie_new(NSURL *url)
{
	return [[XLMovie alloc] initWithURL:url];
}

@interface XLSequence : NSObject {
@public
	uint32_t gworld;
}
@end
@implementation XLSequence
@end

static void qt_register(id o, char kind)
{
	uint32_t h = xl_h(o);
	pthread_mutex_lock(&qt_lock);
	xl_map_put(&qt_objects, h, kind);
	pthread_mutex_unlock(&qt_lock);
}

static id qt_obj(uint32_t h, char kind)
{
	if (!h)
		return nil;
	pthread_mutex_lock(&qt_lock);
	uint64_t k = xl_map_get(&qt_objects, h);
	pthread_mutex_unlock(&qt_lock);
	return k == (uint64_t)kind ? (id)xl_p(h) : nil;
}

static void qt_forget(uint32_t h)
{
	pthread_mutex_lock(&qt_lock);
	xl_map_del(&qt_objects, h);
	pthread_mutex_unlock(&qt_lock);
}

uint32_t xl_qt_movie_handle(id movie)
{
	if (!qt_obj(xl_h(movie), 'm'))
		qt_register(movie, 'm');
	for (XLTrack *t in ((XLMovie *)movie)->tracks)
		if (!qt_obj(xl_h(t), 't'))
			qt_register(t, 't');
	return xl_h(movie);
}

static XLTrack *track_of(uint32_t h)
{
	return qt_obj(h, 't');
}

// GetMovieTrackCount(movie)
static void sh_GetMovieTrackCount(XLCPU *c)
{
	XLMovie *m = qt_obj(A(0), 'm');
	xl_ret(c, m ? (uint32_t)[m->tracks count] : 0);
}

// GetMovieIndTrack(movie, index): 1-based
static void sh_GetMovieIndTrack(XLCPU *c)
{
	XLMovie *m = qt_obj(A(0), 'm');
	uint32_t i = A(1);
	if (!m || i < 1 || i > [m->tracks count]) {
		xl_ret(c, 0);
		return;
	}
	XLTrack *t = m->tracks[i - 1];
	if (!track_of(xl_h(t)))
		qt_register(t, 't');
	xl_ret(c, xl_h(t));
}

// GetMovieIndTrackType(movie, index, type, flags): the index-th track of a media type
static void sh_GetMovieIndTrackType(XLCPU *c)
{
	XLMovie *m = qt_obj(A(0), 'm');
	uint32_t want = A(1);
	XLTrack *found = nil;
	if (m && (A(3) & 1)) {   // movieTrackMediaType
		uint32_t n = 0;
		for (XLTrack *t in m->tracks)
			if (t->kind == A(2) && ++n == want) {
				found = t;
				break;
			}
	}
	if (found && !track_of(xl_h(found)))
		qt_register(found, 't');
	xl_ret(c, found ? xl_h(found) : 0);
}

static void sh_GetTrackMedia(XLCPU *c)
{
	xl_ret(c, track_of(A(0)) ? A(0) : 0);   // a Track and its Media are one object
}

static void sh_DisposeMovieTrack(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	if (t)
		[t->movie->tracks removeObject:t];
	xl_ret(c, 0);
}

// GetMediaHandlerDescription(media, index, OSType *mediaType, OSType *creator, OSType *manufacturer)
static void sh_GetMediaHandlerDescription(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	if (t && A(2))
		U32(A(2)) = t->kind;
	xl_ret(c, 0);
}

static void sh_GetMediaTimeScale(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	xl_ret(c, t && t->kind == 'vide' ? (uint32_t)t->movie->timescale : 0);
}

static void sh_GetMediaDuration(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	xl_ret(c, t && t->kind == 'vide' ? (uint32_t)t->movie->duration : 0);
}

static void sh_GetMediaSampleCount(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	xl_ret(c, t && t->kind == 'vide' ? (uint32_t)t->movie->sampleCount : 0);
}

static void sh_LoadMediaIntoRam(XLCPU *c) { xl_ret(c, 0); }

// GetMovieBox(movie, Rect *): top, left, bottom, right
static void sh_GetMovieBox(XLCPU *c)
{
	XLMovie *m = qt_obj(A(0), 'm');
	uint32_t r = A(1);
	if (r) {
		S16(r) = 0;
		S16(r + 2) = 0;
		S16(r + 4) = (int16_t)(m ? m->height : 0);
		S16(r + 6) = (int16_t)(m ? m->width : 0);
	}
	xl_ret(c, 0);
}

// OffsetRect(Rect *, short dh, short dv)
static void sh_OffsetRect(XLCPU *c)
{
	uint32_t r = A(0);
	int16_t dh = (int16_t)A(1), dv = (int16_t)A(2);
	if (r) {
		S16(r) += dv;
		S16(r + 2) += dh;
		S16(r + 4) += dv;
		S16(r + 6) += dh;
	}
	xl_ret(c, 0);
}

// GetMediaSample(media, Handle data, long maxSizeToGrow, long *size, TimeValue time,
// TimeValue *sampleTime, TimeValue *duration, SampleDescriptionHandle, long *descIndex,
// long maxSamples, long *numSamples, short *flags). The sample is a token for the
// frame at that time: the movie's handle and the media time.
static void sh_GetMediaSample(XLCPU *c)
{
	XLTrack *t = track_of(A(0));
	uint32_t h = A(1);
	if (!t || t->kind != 'vide' || !h) {
		xl_ret(c, (uint32_t)-50);
		return;
	}
	XLMovie *m = t->movie;
	if (U32(h + 4) < 16) {
		U32(h) = xl_realloc(U32(h), 16);
		U32(h + 4) = 16;
	}
	int32_t time = (int32_t)A(4);
	if (time < 0)
		time = 0;
	if (time >= m->duration)
		time = m->duration ? m->duration - 1 : 0;
	int32_t start = time - time % m->frameDur;
	uint32_t p = U32(h);
	U32(p) = xl_h(m);
	U32(p + 4) = (uint32_t)time;
	U32(p + 8) = 0;
	U32(p + 12) = 0;
	if (A(3))
		U32(A(3)) = 16;
	if (A(5))
		U32(A(5)) = (uint32_t)start;
	if (A(6))
		U32(A(6)) = (uint32_t)m->frameDur;
	if (A(10))
		U32(A(10)) = 1;
	if (A(11))
		S16(A(11)) = 0;
	uint32_t d = A(7);   // the ImageDescription of the frames
	if (d && U32(d) && U32(d + 4) >= 86) {
		uint32_t q = U32(d);
		*(int32_t *)GP(q) = 86;
		*(uint32_t *)GP(q + 4) = 'avc1';
		S16(q + 0x20) = (int16_t)m->width;
		S16(q + 0x22) = (int16_t)m->height;
		*(int32_t *)GP(q + 0x24) = 72 << 16;
		*(int32_t *)GP(q + 0x28) = 72 << 16;
		S16(q + 0x30) = 1;
		S16(q + 0x52) = 24;
		S16(q + 0x54) = -1;
	}
	xl_ret(c, 0);
}

// DecompressSequenceBeginS(ImageSequence *, desc, Ptr data, long size, CGrafPtr port, ...)
static void sh_DecompressSequenceBeginS(XLCPU *c)
{
	if (!A(0) || !A(4)) {
		xl_ret(c, (uint32_t)(uint16_t)-50);
		return;
	}
	XLSequence *s = [XLSequence new];
	s->gworld = A(4);
	qt_register(s, 's');
	U32(A(0)) = xl_h(s);
	xl_ret(c, 0);
}

// DecompressSequenceFrameWhen(seq, Ptr data, long size, CodecFlags, CodecFlags *outFlags, ...):
// the token's frame into the sequence's GWorld, from its top left corner
static void sh_DecompressSequenceFrameWhen(XLCPU *c)
{
	XLSequence *s = qt_obj(A(0), 's');
	uint32_t p = A(1);
	XLMovie *m = p && s ? qt_obj(U32(p), 'm') : nil;
	XLGWorld *gw = s && s->gworld ? (XLGWorld *)xl_p(s->gworld) : nil;
	if (A(4))
		U32(A(4)) = 0;
	if (!m || !gw) {
		xl_ret(c, (uint32_t)(uint16_t)-50);
		return;
	}
	size_t w = (size_t)(gw->right - gw->left), h = (size_t)(gw->bottom - gw->top);
	if (xl_verbose > 1)
		xl_log("QuickTime frame at %d into %zux%zu", (int)U32(p + 4), w, h);
	BOOL ok = [m drawFrameAt:(int32_t)U32(p + 4) into:GP(gw->buf) rowBytes:gw->rowBytes width:w height:h];
	if (A(4))
		U32(A(4)) = ok ? 3 : 0;   // codecCompletionSource | codecCompletionDest
	xl_ret(c, 0);
}

static void sh_CDSequenceEnd(XLCPU *c)
{
	XLSequence *s = qt_obj(A(0), 's');
	if (s) {
		qt_forget(A(0));
		[s release];
	}
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
	{"_GetMovieTrackCount", sh_GetMovieTrackCount},
	{"_GetMovieIndTrack", sh_GetMovieIndTrack},
	{"_GetMovieIndTrackType", sh_GetMovieIndTrackType},
	{"_GetTrackMedia", sh_GetTrackMedia},
	{"_DisposeMovieTrack", sh_DisposeMovieTrack},
	{"_GetMediaHandlerDescription", sh_GetMediaHandlerDescription},
	{"_GetMediaTimeScale", sh_GetMediaTimeScale},
	{"_GetMediaDuration", sh_GetMediaDuration},
	{"_GetMediaSampleCount", sh_GetMediaSampleCount},
	{"_LoadMediaIntoRam", sh_LoadMediaIntoRam},
	{"_GetMovieBox", sh_GetMovieBox},
	{"_OffsetRect", sh_OffsetRect},
	{"_GetMediaSample", sh_GetMediaSample},
	{"_DecompressSequenceBeginS", sh_DecompressSequenceBeginS},
	{"_DecompressSequenceFrameWhen", sh_DecompressSequenceFrameWhen},
	{"_CDSequenceEnd", sh_CDSequenceEnd},
	{NULL, NULL},
};

XLShim xl_find_qt_shim(const char *name)
{
	for (int i = 0; qt_shims[i].name; i++)
		if (!strcmp(qt_shims[i].name, name))
			return qt_shims[i].fn;
	return NULL;
}
