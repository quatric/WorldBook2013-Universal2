// SAPlayer (the app's sound player) on AVAudioPlayer.
//
// The original plays through an AUGraph of its own audio units (a stereo
// panner and a spectrum analyzer) registered with the Component Manager,
// whose 32-bit entry points cannot be registered on the host. The C API that
// SASoundPlayerImpl and SoundPlayerView use is small, so it is replaced as a
// whole (xlate/overrides.txt). Times are in seconds, as AUPlayerBase keeps them.
#import <AVFoundation/AVFoundation.h>
#include "rt.h"

#define A(i) xl_arg(c, i)

static float argf(XLCPU *c, int i)
{
	uint32_t v = A(i);
	float f;
	memcpy(&f, &v, 4);
	return f;
}

static void ret_float(XLCPU *c, double v)
{
	c->top = (c->top - 1) & 7;
	c->st[c->top] = v;
	c->r[ESP] += 4;
}

@interface XLSAPlayer : NSObject <AVAudioPlayerDelegate> {
@public
	AVAudioPlayer *player;
	uint32_t handle;
	uint32_t stop_cb, stop_refcon;
	float volume, pan, scale;
	BOOL looped;
	uint32_t bands[2];
	uint32_t levels[2];   // guest float arrays, one per channel
}
@end

@implementation XLSAPlayer
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok
{
	if (stop_cb) {
		uint32_t args[2] = {handle, stop_refcon};
		xl_guest_call(stop_cb, 2, args);
	}
}

- (void)dealloc
{
	[player stop];
	player.delegate = nil;
	[player release];
	for (int i = 0; i < 2; i++)
		if (levels[i])
			xl_free(levels[i]);
	[super dealloc];
}
@end

static XLSAPlayer *P(XLCPU *c)
{
	return A(0) ? (XLSAPlayer *)xl_p(A(0)) : nil;
}

void xl_sa_create(XLCPU *c)
{
	XLSAPlayer *p = [XLSAPlayer new];
	p->volume = 1;
	p->scale = 1;
	p->bands[0] = p->bands[1] = 1;
	p->handle = xl_h(p);
	xl_ret(c, p->handle);
}

void xl_sa_dispose(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	[p release];
	xl_ret(c, 0);
}

void xl_sa_set_filename(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	NSString *s = A(1) ? (NSString *)xl_p(A(1)) : nil;
	if (p) {
		[p->player stop];
		p->player.delegate = nil;
		[p->player release];
		p->player = nil;
		if ([s length]) {
			NSURL *u = [s hasPrefix:@"file:"] ? [NSURL URLWithString:s] : [NSURL fileURLWithPath:s];
			NSError *e = nil;
			p->player = [[AVAudioPlayer alloc] initWithContentsOfURL:u error:&e];
			if (!p->player)
				xl_log("SAPlayer: cannot play %s: %s", [s UTF8String], [[e description] UTF8String]);
			p->player.delegate = p;
			p->player.volume = p->volume;
			p->player.pan = p->pan;
			p->player.numberOfLoops = p->looped ? -1 : 0;
			p->player.meteringEnabled = YES;
			[p->player prepareToPlay];
		}
	}
	xl_ret(c, 0);
}

void xl_sa_start(XLCPU *c)
{
	[P(c)->player play];
	xl_ret(c, 0);
}

void xl_sa_stop(XLCPU *c)
{
	[P(c)->player pause];
	xl_ret(c, 0);
}

void xl_sa_is_playing(XLCPU *c) { xl_ret(c, [P(c)->player isPlaying] ? 1 : 0); }

void xl_sa_get_volume(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	ret_float(c, p ? p->volume : 0);
}

void xl_sa_set_volume(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p) {
		p->volume = argf(c, 1);
		p->player.volume = p->volume;
	}
	xl_ret(c, 0);
}

void xl_sa_get_pan(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	ret_float(c, p ? p->pan : 0);
}

void xl_sa_set_pan(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p) {
		p->pan = argf(c, 1);
		p->player.pan = p->pan;
	}
	xl_ret(c, 0);
}

void xl_sa_get_duration(XLCPU *c) { ret_float(c, P(c)->player ? P(c)->player.duration : 0); }
void xl_sa_get_time(XLCPU *c) { ret_float(c, P(c)->player ? P(c)->player.currentTime : 0); }

void xl_sa_set_time(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p->player)
		p->player.currentTime = argf(c, 1);
	xl_ret(c, 0);
}

void xl_sa_set_stop_callback(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p) {
		p->stop_cb = A(1);
		p->stop_refcon = A(2);
	}
	xl_ret(c, 0);
}

void xl_sa_get_channels(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	NSUInteger n = p->player ? p->player.numberOfChannels : 2;
	xl_ret(c, (uint32_t)(n > 2 ? 2 : n ? n : 2));
}

void xl_sa_get_bands(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	uint32_t ch = A(1) & 1;
	xl_ret(c, p ? p->bands[ch] : 0);
}

void xl_sa_set_bands(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	uint32_t ch = A(1) & 1, n = A(2);
	if (p && n && n < 4096 && n != p->bands[ch]) {
		p->bands[ch] = n;
		if (p->levels[ch])
			xl_free(p->levels[ch]);
		p->levels[ch] = 0;
	}
	xl_ret(c, 0);
}

// no spectrum: every band follows the channel's level
void xl_sa_get_amplitudes(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	uint32_t ch = A(1) & 1;
	if (!p) {
		xl_ret(c, 0);
		return;
	}
	if (!p->levels[ch])
		p->levels[ch] = xl_calloc(p->bands[ch] * 4);
	float level = 0;
	if ([p->player isPlaying]) {
		[p->player updateMeters];
		NSUInteger k = ch < p->player.numberOfChannels ? ch : 0;
		level = powf(10, [p->player averagePowerForChannel:k] / 20) * p->scale;
	}
	float *f = (float *)GP(p->levels[ch]);
	for (uint32_t i = 0; i < p->bands[ch]; i++)
		f[i] = level;
	xl_ret(c, p->levels[ch]);
}

void xl_sa_set_scale(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p)
		p->scale = argf(c, 1);
	xl_ret(c, 0);
}

void xl_sa_get_scale(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	ret_float(c, p ? p->scale : 1);
}

void xl_sa_set_looped(XLCPU *c)
{
	XLSAPlayer *p = P(c);
	if (p) {
		p->looped = (A(1) & 0xff) != 0;
		p->player.numberOfLoops = p->looped ? -1 : 0;
	}
	xl_ret(c, 0);
}

void xl_sa_get_looped(XLCPU *c) { xl_ret(c, P(c) && P(c)->looped ? 1 : 0); }

// fades are the audio units' work; playback goes on without them
void xl_sa_set_fade(XLCPU *c) { xl_ret(c, 0); }
