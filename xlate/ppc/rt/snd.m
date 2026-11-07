// Sound Manager: SndPlay of 'snd ' resources (sampled sound headers).
#import <AVFoundation/AVFoundation.h>
#include "ppcrt.h"

static NSMutableSet *playing;

static uint32_t be32(const uint8_t *d) { return (uint32_t)d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3]; }
static uint16_t be16(const uint8_t *d) { return (uint16_t)(d[0] << 8 | d[1]); }

// the sound header of a format 1 or 2 'snd ' and its offset
static int find_header(const uint8_t *d, uint32_t n, uint32_t *off)
{
	if (n < 6)
		return 0;
	uint32_t o;
	int fmt = be16(d);
	if (fmt == 1) {
		int ndata = be16(d + 2);
		o = 4 + 6 * ndata;
	} else if (fmt == 2)
		o = 4;
	else
		return 0;
	if (o + 2 > n)
		return 0;
	int ncmd = be16(d + o);
	o += 2;
	for (int i = 0; i < ncmd && o + 8 <= n; i++, o += 8) {
		uint16_t cmd = be16(d + o);
		if (cmd == 0x8051 || cmd == 0x8050) {   // bufferCmd, soundCmd with a data offset
			*off = be32(d + o + 4);
			return *off + 22 <= n;
		}
	}
	return 0;
}

static NSData *wav(const uint8_t *d, uint32_t n)
{
	uint32_t h;
	if (!find_header(d, n, &h))
		return nil;
	const uint8_t *s = d + h;
	uint32_t rate = be32(s + 8) >> 16;
	int enc = s[20];
	int channels = 1, bits = 8;
	uint32_t frames;
	const uint8_t *data;
	if (enc == 0) {
		frames = be32(s + 4);
		data = s + 22;
	} else if (enc == 0xff) {
		if (h + 64 > n)
			return nil;
		channels = (int)be32(s + 4);
		frames = be32(s + 22);
		bits = be16(s + 48);
		data = s + 64;
	} else
		return nil;   // compressed
	if (!rate)
		rate = 22254;
	uint32_t bytes = frames * channels * (bits / 8);
	if (data + bytes > d + n)
		bytes = (uint32_t)(d + n - data);
	NSMutableData *w = [NSMutableData dataWithLength:44 + bytes];
	uint8_t *o = w.mutableBytes;
	memcpy(o, "RIFF", 4);
	OSWriteLittleInt32(o, 4, 36 + bytes);
	memcpy(o + 8, "WAVEfmt ", 8);
	OSWriteLittleInt32(o, 16, 16);
	OSWriteLittleInt16(o, 20, 1);
	OSWriteLittleInt16(o, 22, channels);
	OSWriteLittleInt32(o, 24, rate);
	OSWriteLittleInt32(o, 28, rate * channels * (bits / 8));
	OSWriteLittleInt16(o, 32, channels * (bits / 8));
	OSWriteLittleInt16(o, 34, bits);
	memcpy(o + 36, "data", 4);
	OSWriteLittleInt32(o, 40, bytes);
	if (bits == 16) {
		// big-endian signed samples to little-endian
		for (uint32_t i = 0; i + 1 < bytes; i += 2) {
			o[44 + i] = data[i + 1];
			o[44 + i + 1] = data[i];
		}
	} else
		memcpy(o + 44, data, bytes);   // 8-bit: unsigned in both
	return w;
}

void snd_play_data(const uint8_t *d, uint32_t n)
{
	NSData *w = wav(d, n);
	if (!w)
		return;
	AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:w error:NULL];
	if (!p)
		return;
	if (!playing)
		playing = [NSMutableSet new];
	// drop finished players
	for (AVAudioPlayer *q in [playing allObjects])
		if (!q.playing)
			[playing removeObject:q];
	[playing addObject:p];
	[p release];
	[p play];
}

static void sh_SndNewChannel(PPC *c)
{
	// SndNewChannel(SndChannelPtr *, synth, init, userRoutine)
	if (A(0) && !LD32(A(0)))
		ST32(A(0), gcalloc(64));
	RET(0);
}
static void sh_SndDisposeChannel(PPC *c)
{
	if (A(1) & 0xff)
		for (AVAudioPlayer *q in [playing allObjects])
			[q stop];
	RET(0);
}
static void sh_SndPlay(PPC *c)
{
	// SndPlay(chan, SndListHandle, async)
	uint32_t h = A(1);
	if (h && is_handle(h))
		snd_play_data(G(HP(h)), HSize(h));
	RET(0);
}
static void sh_SndDoImmediate(PPC *c)
{
	if (be16((const uint8_t *)G(A(1))) == 3)   // quietCmd
		for (AVAudioPlayer *q in [playing allObjects])
			[q stop];
	RET(0);
}
static void sh_SndDoCommand(PPC *c) { (void)c; RET(0); }

static const ShimDef sndshims[] = {
	S(SndNewChannel), S(SndDisposeChannel), S(SndPlay), S(SndDoImmediate), S(SndDoCommand),
};
REGISTER(sndshims)
