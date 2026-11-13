// NSMovie and NSMovieView on AVFoundation and AVKit.
//
// The app shows video clips and some sounds (the Media Center's "A CAPPELLA -
// Barbershop music", say) in WBMovieView, an NSMovieView subclass playing an
// NSMovie. Both wrapped QuickTime, which current macOS no longer has: AppKit
// keeps an empty NSMovie and NSMovieView is gone. Here NSMovie keeps its URL
// and NSMovieView plays it in an AVPlayerView with the inline controls.
//
// The app also calls QuickTime functions on the movie (-QTMovie) and its
// controller (-movieController): play hints, volume, clipping. Those are not
// there either, and missing functions return 0 (bridge.m). -QTMovie is 0, as
// the home screen's moving pictures read the movie's frames through QuickTime
// calls: -QTMovie answers with an XLMovie on the file (qtimport.m) that those
// calls are shimmed for. -movieController is a nonzero token.
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Cocoa/Cocoa.h>
#include "rt.h"

static char kURL, kPlayer, kPlayerView, kShowController;

// ---- NSMovie --------------------------------------------------------------------------------
static id movie_initWithURL(id self, SEL _cmd, NSURL *url, BOOL byRef)
{
	(void)_cmd;
	(void)byRef;
	if (![url isKindOfClass:[NSURL class]] || ([url isFileURL] && ![[NSFileManager defaultManager] fileExistsAtPath:[url path]])) {
		[self release];
		return nil;
	}
	// AppKit's remaining -[NSMovie init] fails: the allocated object is used as is
	objc_setAssociatedObject(self, &kURL, url, OBJC_ASSOCIATION_RETAIN);
	return self;
}

static NSURL *movie_URL(id self, SEL _cmd)
{
	(void)_cmd;
	return objc_getAssociatedObject(self, &kURL);
}

static unsigned movie_token(id self, SEL _cmd)
{
	(void)self;
	(void)_cmd;
	return 1;
}

static char kQTMovie;

extern id xl_qt_movie_new(NSURL *url);
extern uint32_t xl_qt_movie_handle(id movie);

// the NSMovie's QuickTime Movie: a handle on an XLMovie kept with it
static void *movie_QTMovie(id self, SEL _cmd)
{
	(void)_cmd;
	id m = objc_getAssociatedObject(self, &kQTMovie);
	if (!m) {
		NSURL *url = objc_getAssociatedObject(self, &kURL);
		if (!url)
			return 0;
		m = [xl_qt_movie_new(url) autorelease];
		if (!m)
			return 0;
		objc_setAssociatedObject(self, &kQTMovie, m, OBJC_ASSOCIATION_RETAIN);
	}
	xl_qt_movie_handle(m);   // registers the movie and its tracks
	return m;   // the bridge turns the pointer into the guest's handle
}

// ---- NSMovieView ----------------------------------------------------------------------------
static AVPlayer *view_player(id self)
{
	return objc_getAssociatedObject(self, &kPlayer);
}

static BOOL view_shows_controller(id self)
{
	NSNumber *n = objc_getAssociatedObject(self, &kShowController);
	return n ? [n boolValue] : YES;
}

static void view_setMovie(NSView *self, SEL _cmd, id movie)
{
	(void)_cmd;
	AVPlayerView *pv = objc_getAssociatedObject(self, &kPlayerView);
	[view_player(self) pause];
	objc_setAssociatedObject(self, &kURL, movie, OBJC_ASSOCIATION_RETAIN);   // the NSMovie
	NSURL *url = [movie respondsToSelector:@selector(URL)] ? [movie URL] : nil;
	AVPlayer *p = url ? [AVPlayer playerWithURL:url] : nil;
	objc_setAssociatedObject(self, &kPlayer, p, OBJC_ASSOCIATION_RETAIN);
	if (!p) {
		[pv removeFromSuperview];
		objc_setAssociatedObject(self, &kPlayerView, nil, OBJC_ASSOCIATION_RETAIN);
		return;
	}
	if (!pv) {
		pv = [[[AVPlayerView alloc] initWithFrame:[self bounds]] autorelease];
		[pv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[pv setShowsFullScreenToggleButton:NO];
		[pv setShowsSharingServiceButton:NO];
		[self addSubview:pv];
		objc_setAssociatedObject(self, &kPlayerView, pv, OBJC_ASSOCIATION_RETAIN);
	}
	[pv setControlsStyle:view_shows_controller(self) ? AVPlayerViewControlsStyleInline : AVPlayerViewControlsStyleNone];
	[pv setPlayer:p];
}

static id view_movie(id self, SEL _cmd)
{
	(void)_cmd;
	return objc_getAssociatedObject(self, &kURL);
}

static void view_showController(id self, SEL _cmd, BOOL show, BOOL adjust)
{
	(void)_cmd;
	(void)adjust;
	objc_setAssociatedObject(self, &kShowController, @(show), OBJC_ASSOCIATION_RETAIN);
	AVPlayerView *pv = objc_getAssociatedObject(self, &kPlayerView);
	[pv setControlsStyle:show ? AVPlayerViewControlsStyleInline : AVPlayerViewControlsStyleNone];
}

static BOOL view_isControllerVisible(id self, SEL _cmd)
{
	(void)_cmd;
	return view_shows_controller(self);
}

static void view_start(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	AVPlayer *p = view_player(self);
	if (p && CMTIME_IS_NUMERIC([[p currentItem] duration]) && CMTimeCompare([p currentTime], [[p currentItem] duration]) >= 0)
		[p seekToTime:kCMTimeZero];   // QuickTime starts an ended movie over
	[p play];
}

static void view_stop(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	[view_player(self) pause];
}

static BOOL view_isPlaying(id self, SEL _cmd)
{
	(void)_cmd;
	return [view_player(self) rate] != 0;
}

static void view_gotoBeginning(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	[view_player(self) seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

static void view_gotoEnd(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	AVPlayer *p = view_player(self);
	CMTime d = [[p currentItem] duration];
	if (CMTIME_IS_NUMERIC(d))
		[p seekToTime:d toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

static void view_stepForward(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	[[view_player(self) currentItem] stepByCount:1];
}

static void view_stepBack(id self, SEL _cmd, id sender)
{
	(void)_cmd;
	(void)sender;
	[[view_player(self) currentItem] stepByCount:-1];
}

static float view_volume(id self, SEL _cmd)
{
	(void)_cmd;
	AVPlayer *p = view_player(self);
	return p ? [p volume] : 1;
}

static void view_setVolume(id self, SEL _cmd, float v)
{
	(void)_cmd;
	[view_player(self) setVolume:v];
}

static BOOL view_isMuted(id self, SEL _cmd)
{
	(void)_cmd;
	return [view_player(self) isMuted];
}

static void view_setMuted(id self, SEL _cmd, BOOL m)
{
	(void)_cmd;
	[view_player(self) setMuted:m];
}

static void view_noop_bool(id self, SEL _cmd, BOOL b)
{
	(void)self;
	(void)_cmd;
	(void)b;
}

static BOOL view_no(id self, SEL _cmd)
{
	(void)self;
	(void)_cmd;
	return NO;
}

// the movie's size at a magnification, with the controller below it; a sound
// has no picture and gets the controller alone
static NSSize view_sizeForMagnification(id self, SEL _cmd, float mag)
{
	(void)_cmd;
	AVAsset *a = [[view_player(self) currentItem] asset];
	NSSize s = NSZeroSize;
	for (AVAssetTrack *t in [a tracksWithMediaType:AVMediaTypeVideo]) {
		CGSize n = CGSizeApplyAffineTransform([t naturalSize], [t preferredTransform]);
		s = NSMakeSize(fabs(n.width) * mag, fabs(n.height) * mag);
		break;
	}
	if (s.width == 0 && view_shows_controller(self))
		s = NSMakeSize(400, 52);   // the inline controls float over a picture
	return s;
}

static NSRect view_movieRect(NSView *self, SEL _cmd)
{
	(void)_cmd;
	return [self bounds];
}

static void add(Class c, const char *sel, IMP imp, const char *types)
{
	SEL s = sel_registerName(sel);
	if (!class_addMethod(c, s, imp, types))
		class_replaceMethod(c, s, imp, types);
}

Class xl_movie_view_class(const char *name)
{
	Class c = objc_allocateClassPair([NSView class], name, 0);
	if (!c)
		return objc_getClass(name);
	char b[64], v[64];
	snprintf(b, sizeof b, "%s@:", @encode(BOOL));
	add(c, "setMovie:", (IMP)view_setMovie, "v@:@");
	add(c, "movie", (IMP)view_movie, "@@:");
	snprintf(v, sizeof v, "v@:%s%s", @encode(BOOL), @encode(BOOL));
	add(c, "showController:adjustingSize:", (IMP)view_showController, v);
	add(c, "isControllerVisible", (IMP)view_isControllerVisible, b);
	add(c, "start:", (IMP)view_start, "v@:@");
	add(c, "stop:", (IMP)view_stop, "v@:@");
	add(c, "play:", (IMP)view_start, "v@:@");
	add(c, "pause:", (IMP)view_stop, "v@:@");
	add(c, "isPlaying", (IMP)view_isPlaying, b);
	add(c, "gotoBeginning:", (IMP)view_gotoBeginning, "v@:@");
	add(c, "gotoPosterFrame:", (IMP)view_gotoBeginning, "v@:@");
	add(c, "gotoEnd:", (IMP)view_gotoEnd, "v@:@");
	add(c, "stepForward:", (IMP)view_stepForward, "v@:@");
	add(c, "stepBack:", (IMP)view_stepBack, "v@:@");
	add(c, "stepBackward:", (IMP)view_stepBack, "v@:@");
	add(c, "volume", (IMP)view_volume, "f@:");
	add(c, "setVolume:", (IMP)view_setVolume, "v@:f");
	add(c, "isMuted", (IMP)view_isMuted, b);
	snprintf(v, sizeof v, "v@:%s", @encode(BOOL));
	add(c, "setMuted:", (IMP)view_setMuted, v);
	add(c, "setEditable:", (IMP)view_noop_bool, v);
	add(c, "setPlaysSelectionOnly:", (IMP)view_noop_bool, v);
	add(c, "setPlaysEveryFrame:", (IMP)view_noop_bool, v);
	add(c, "isEditable", (IMP)view_no, b);
	add(c, "movieController", (IMP)movie_token, "I@:");
	snprintf(v, sizeof v, "%s@:f", @encode(NSSize));
	add(c, "sizeForMagnification:", (IMP)view_sizeForMagnification, v);
	snprintf(v, sizeof v, "%s@:", @encode(NSRect));
	add(c, "movieRect", (IMP)view_movieRect, v);
	objc_registerClassPair(c);
	return c;
}

void xl_movie_hooks(void)
{
	Class m = objc_getClass("NSMovie");
	if (!m)
		return;
	char t[16];
	snprintf(t, sizeof t, "@@:@%s", @encode(BOOL));
	add(m, "initWithURL:byReference:", (IMP)movie_initWithURL, t);
	add(m, "URL", (IMP)movie_URL, "@@:");
	add(m, "QTMovie", (IMP)movie_QTMovie, "^v@:");
}
